/**
 * Projects: the repos you work in, side by side in the sidebar.
 *
 * A project is a name and a git checkout. Every session belongs to one: the
 * one you dragged it to, else the one whose checkout (or worktree folder) it
 * runs in. Anything else is "Default": not a repo, just a folder (set in the
 * app, else DEFAULT_DIR, else your home) for general questions and one-off
 * work. Default is listed first; it can be renamed and pointed at another
 * folder but not moved or removed, and its orchestrator keeps the original
 * `orchestrator` id; every real project gets `orchestrator-<id>`.
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

// Default's name and folder, as you set them in the app (data/default.json);
// the folder falls back to DEFAULT_DIR in .env, then your home folder.
const ROOT_FILE = path.join(env.dataDir, "default.json");
function rootPrefs() {
  try {
    return JSON.parse(fs.readFileSync(ROOT_FILE, "utf8")) || {};
  } catch {
    return {};
  }
}

const expand = (d) => path.resolve(String(d).replace(/^~(?=$|\/)/, os.homedir()));

/** The folder Default sessions and its orchestrator work in. */
function rootDir() {
  for (const d of [rootPrefs().path, env.defaultDir]) {
    if (d && fs.existsSync(expand(d))) return expand(d);
  }
  return os.homedir();
}
const rootProject = () => {
  const r = rootPrefs();
  return { id: DEFAULT, name: r.name || "Default", path: rootDir(), root: true, auto: automation(r.auto), ...(r.github ? { github: r.github } : {}), ...(r.linear ? { linear: r.linear } : {}) };
};

/**
 * A project's GitHub account ({login, host, name, email}: the route checks it
 * with gh and fills the commit identity) and Linear team key ("RLS"). Empty
 * clears either. Applied in place to the stored object.
 */
function applyIdentity(target, patch) {
  if (patch.github !== undefined) {
    const g = patch.github;
    if (g && g.login) target.github = { login: String(g.login), host: String(g.host || "github.com"), name: String(g.name || g.login), email: String(g.email || "") };
    else delete target.github;
  }
  if (patch.linear !== undefined) {
    const key = String(patch.linear || "").trim().toUpperCase();
    if (key && !/^[A-Z][A-Z0-9]{0,9}$/.test(key)) throw new Error(`not a Linear team key: ${patch.linear}`);
    if (key) target.linear = key;
    else delete target.linear;
  }
}

/**
 * How autonomous workers are in a project (Settings › Agents › Automation). Only
 * "rebase" is on by default: it is already a house rule. Hard limits (no
 * Slack, Linear or new threads; no admin merge) hold whatever these say.
 */
const AUTO = { merge: false, review: false, resolve: false, rebase: true, decide: false };
function automation(raw) {
  const out = { ...AUTO };
  for (const k of Object.keys(AUTO)) if (raw && typeof raw[k] === "boolean") out[k] = raw[k];
  return out;
}
/** Stored form: only what differs from the defaults (undefined when nothing does). */
function packAuto(prev, patch) {
  const next = automation({ ...automation(prev), ...(patch || {}) });
  const diff = Object.fromEntries(Object.keys(AUTO).filter((k) => next[k] !== AUTO[k]).map((k) => [k, next[k]]));
  return Object.keys(diff).length ? diff : undefined;
}

/** Rename Default or point it at another folder (any folder: it needn't be a repo). */
function updateRoot(patch) {
  if (patch.index !== undefined) throw new Error("Default stays first");
  const next = { ...rootPrefs() };
  if (patch.name !== undefined) next.name = String(patch.name).trim().slice(0, 60) || undefined;
  if (patch.auto !== undefined) next.auto = packAuto(next.auto, patch.auto);
  applyIdentity(next, patch);
  if (patch.path !== undefined) {
    const dir = expand(patch.path);
    if (!fs.existsSync(dir) || !fs.statSync(dir).isDirectory()) throw new Error(`not a folder: ${dir}`);
    next.path = dir;
  }
  fs.mkdirSync(path.dirname(ROOT_FILE), { recursive: true });
  fs.writeFileSync(ROOT_FILE, JSON.stringify(next, null, 2));
  return rootProject();
}

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

const withAuto = (p) => ({ ...p, auto: automation(p.auto) });

/** Default first, then every project: what the sidebar and pickers show. */
const withRoot = (fallbackRepo = "") => [rootProject(), ...list(fallbackRepo).map(withAuto)];

function get(id) {
  if (id === DEFAULT) return rootProject();
  const p = list().find((x) => x.id === id);
  return p ? withAuto(p) : null;
}

function add({ path: repo, name }) {
  const dir = path.resolve(String(repo || ""));
  if (!path.isAbsolute(dir) || !fs.existsSync(path.join(dir, ".git"))) throw new Error(`not a git checkout: ${dir}`);
  const all = list();
  const existing = all.find((p) => p.path === dir);
  if (existing) return withAuto(existing);
  let id = slug(name || path.basename(dir));
  while (id === DEFAULT || all.some((p) => p.id === id)) id = `${id}-2`;
  const p = { id, name: String(name || path.basename(dir)).slice(0, 60), path: dir, createdAt: Date.now() };
  write([...all, p]);
  return withAuto(p);
}

function update(id, patch) {
  if (id === DEFAULT) return updateRoot(patch);
  const all = list();
  const p = all.find((x) => x.id === id);
  if (!p) throw new Error(`no such project: ${id}`);
  if (patch.name) p.name = String(patch.name).slice(0, 60);
  applyIdentity(p, patch);
  if (patch.auto !== undefined) {
    const packed = packAuto(p.auto, patch.auto);
    if (packed) p.auto = packed;
    else delete p.auto;
  }
  if (patch.index !== undefined) {
    // An index among the real projects (Default is always first, outside them).
    const to = Math.max(0, Math.min(all.length - 1, Math.floor(Number(patch.index)) || 0));
    all.splice(all.indexOf(p), 1);
    all.splice(to, 0, p);
  }
  write(all);
  return withAuto(p);
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

module.exports = { list, withRoot, get, add, update, remove, of, rootDir, automation, AUTO, DEFAULT, orchestratorId, isOrchestrator, FILE };
