/**
 * Projects: the repos you work in, side by side in the sidebar.
 *
 * A project is a name and a git checkout. Every session belongs to one: the
 * one you dragged it to, else the one whose checkout (or worktree folder) it
 * runs in. Anything else is "Default": not a repo, just a folder (DEFAULT_DIR,
 * else your home) for general questions and one-off work. Default is listed
 * first, can't be renamed, moved or removed, and its orchestrator keeps the
 * original `orchestrator` id; every real project gets `orchestrator-<id>`.
 *
 * Stored in data/projects.json, in sidebar order (Default isn't stored). The
 * first project is seeded from TARGET_REPO on first use.
 */

const fs = require("fs");
const path = require("path");
const env = require("./env");

const os = require("os");

const FILE = path.join(env.dataDir, "projects.json");
const DEFAULT = "default";

/** The folder Default sessions and its orchestrator work in. */
function rootDir() {
  const d = env.defaultDir ? path.resolve(env.defaultDir.replace(/^~(?=$|\/)/, os.homedir())) : os.homedir();
  return fs.existsSync(d) ? d : os.homedir();
}
const rootProject = () => ({ id: DEFAULT, name: "Default", path: rootDir(), root: true });

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

/** Real projects (git checkouts), in sidebar order. Seeds one on first use. */
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

/** Default first, then every project: what the sidebar and pickers show. */
const withRoot = (fallbackRepo = "") => [rootProject(), ...list(fallbackRepo).map(({ default: _, ...p }) => p)];

function get(id) {
  if (id === DEFAULT) return rootProject();
  return list().find((p) => p.id === id) || null;
}

function add({ path: repo, name }) {
  const dir = path.resolve(String(repo || ""));
  if (!path.isAbsolute(dir) || !fs.existsSync(path.join(dir, ".git"))) throw new Error(`not a git checkout: ${dir}`);
  const all = list();
  const existing = all.find((p) => p.path === dir);
  if (existing) return existing;
  let id = slug(name || path.basename(dir));
  while (id === DEFAULT || all.some((p) => p.id === id)) id = `${id}-2`;
  const p = { id, name: String(name || path.basename(dir)).slice(0, 60), path: dir, createdAt: Date.now() };
  write([...all, p]);
  return p;
}

function update(id, patch) {
  if (id === DEFAULT) throw new Error("Default can't be renamed or moved");
  const all = list();
  const p = all.find((x) => x.id === id);
  if (!p) throw new Error(`no such project: ${id}`);
  if (patch.name) p.name = String(patch.name).slice(0, 60);
  if (patch.index !== undefined) {
    // An index among the real projects (Default is always first, outside them).
    const to = Math.max(0, Math.min(all.length - 1, Math.floor(Number(patch.index)) || 0));
    all.splice(all.indexOf(p), 1);
    all.splice(to, 0, p);
  }
  write(all);
  return p;
}

function remove(id) {
  if (id === DEFAULT) throw new Error("Default can't be removed");
  write(list().filter((p) => p.id !== id));
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
  if (run.project === DEFAULT || (run.project && all.some((p) => p.id === run.project))) return run.project;
  const dirs = [meta.repo, meta.worktree, run.opts && run.opts.workdir, ...(run.messages || []).filter((m) => m.workdir).slice(0, 1).map((m) => m.workdir)].filter(Boolean);
  for (const dir of dirs) {
    const hit = all.find((p) => inside(path.resolve(dir), p.path) || inside(path.resolve(dir), worktreeRoot(p.path)));
    if (hit) return hit.id;
  }
  return DEFAULT;
}

/** Run id of a project's orchestrator chat: Default keeps the original id. */
const orchestratorId = (projectId) => (!projectId || projectId === DEFAULT ? "orchestrator" : `orchestrator-${projectId}`);
const isOrchestrator = (runId) => runId === "orchestrator" || String(runId || "").startsWith("orchestrator-");

module.exports = { list, withRoot, get, add, update, remove, of, rootDir, DEFAULT, orchestratorId, isOrchestrator, FILE };
