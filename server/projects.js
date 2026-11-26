/**
 * Projects: the repos you work in, side by side in the sidebar.
 *
 * A project is a name and a git checkout. Every session belongs to one: the
 * one you dragged it to, else the one whose checkout (or worktree folder) it
 * runs in, else the default project. Each project has its own orchestrator
 * chat, so a worker's outcome is relayed to the orchestrator of the repo it
 * worked in.
 *
 * Stored in data/projects.json, in sidebar order. The first project is seeded
 * from TARGET_REPO (or the job default workdir). The default is the one marked
 * `default`, else the first, so reordering never moves the default.
 */

const fs = require("fs");
const path = require("path");
const env = require("./env");

const FILE = path.join(env.dataDir, "projects.json");

const slug = (s) =>
  String(s || "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 40) || "project";

function read() {
  try {
    const all = JSON.parse(fs.readFileSync(FILE, "utf8"));
    return Array.isArray(all) ? all.filter((p) => p && p.id && p.path) : [];
  } catch {
    return [];
  }
}

function write(all) {
  fs.mkdirSync(path.dirname(FILE), { recursive: true });
  const tmp = `${FILE}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, JSON.stringify(all, null, 2));
  fs.renameSync(tmp, FILE);
}

/** Every project, in sidebar order. Seeds the default on first use. */
function list(fallbackRepo = "") {
  let all = read();
  if (!all.length) {
    const repo = env.targetRepo || fallbackRepo;
    if (repo) {
      all = [{ id: slug(path.basename(repo)), name: path.basename(repo), path: path.resolve(repo), createdAt: Date.now() }];
      write(all);
    }
  }
  return all;
}

const defaultOf = (all) => (all.find((p) => p.default) || all[0] || {}).id || "";
const defaultId = () => defaultOf(list());

function get(id) {
  return list().find((p) => p.id === id) || null;
}

function add({ path: repo, name }) {
  const dir = path.resolve(String(repo || ""));
  if (!path.isAbsolute(dir) || !fs.existsSync(path.join(dir, ".git"))) throw new Error(`not a git checkout: ${dir}`);
  const all = list();
  const existing = all.find((p) => p.path === dir);
  if (existing) return existing;
  let id = slug(name || path.basename(dir));
  while (all.some((p) => p.id === id)) id = `${id}-2`;
  const p = { id, name: String(name || path.basename(dir)).slice(0, 60), path: dir, createdAt: Date.now() };
  write([...all, p]);
  return p;
}

function update(id, patch) {
  const all = list();
  const p = all.find((x) => x.id === id);
  if (!p) throw new Error(`no such project: ${id}`);
  if (patch.name) p.name = String(patch.name).slice(0, 60);
  if (patch.makeDefault) {
    for (const x of all) delete x.default;
    p.default = true;
  }
  if (patch.index !== undefined) {
    // Pin the default by flag before the order changes, so its orchestrator stays put.
    const def = defaultOf(all);
    for (const x of all) delete x.default;
    all.find((x) => x.id === def).default = true;
    const to = Math.max(0, Math.min(all.length - 1, Math.floor(Number(patch.index)) || 0));
    all.splice(all.indexOf(p), 1);
    all.splice(to, 0, p);
  }
  write(all);
  return p;
}

function remove(id) {
  const all = list();
  if (all.length <= 1) throw new Error("keep at least one project");
  write(all.filter((p) => p.id !== id));
}

/** Worktrees of `repo` live here (same rule as server/tasks.js). */
function worktreeRoot(repo) {
  if (env.worktreeRoot && env.targetRepo && path.resolve(env.targetRepo) === repo) return path.resolve(env.worktreeRoot);
  return `${repo}-worktrees`;
}

const inside = (dir, root) => !!dir && (dir === root || dir.startsWith(root + path.sep));

/** The project a run belongs to. `meta` is its task meta, when it has one. */
function of(run, meta = {}) {
  const all = list();
  if (run.project && all.some((p) => p.id === run.project)) return run.project;
  const dirs = [meta.repo, meta.worktree, run.opts && run.opts.workdir, ...(run.messages || []).filter((m) => m.workdir).slice(0, 1).map((m) => m.workdir)].filter(Boolean);
  for (const dir of dirs) {
    const hit = all.find((p) => inside(path.resolve(dir), p.path) || inside(path.resolve(dir), worktreeRoot(p.path)));
    if (hit) return hit.id;
  }
  return defaultOf(all);
}

/** Run id of a project's orchestrator chat. The default project keeps the
 *  original id, so an existing orchestrator chat stays where it was. */
const orchestratorId = (projectId) => (!projectId || projectId === defaultId() ? "orchestrator" : `orchestrator-${projectId}`);
const isOrchestrator = (runId) => runId === "orchestrator" || String(runId || "").startsWith("orchestrator-");

module.exports = { list, get, add, update, remove, of, defaultId, orchestratorId, isOrchestrator, FILE };
