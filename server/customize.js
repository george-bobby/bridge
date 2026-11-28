/**
 * Settings › Customize: the skills and plugins each agent loads, next to the
 * MCP servers (server/mcp.js).
 *
 * Skills are folders with a SKILL.md, in the places each agent reads them:
 *
 *   Claude   ~/.claude/skills, <repo>/.claude/skills
 *   Codex    ~/.codex/skills
 *   Cursor   ~/.cursor/skills, <repo>/.cursor/skills
 *   Devin    ~/.devin/skills, ~/.config/devin/skills, <repo>/.devin/skills
 *   Shared   ~/.agents/skills, <repo>/.agents/skills (several agents read these)
 *
 * Bridge lists them, edits SKILL.md, creates new ones and deletes them. A
 * delete moves the folder to the Trash (a symlinked skill only loses its
 * link), so it can be undone from Finder. Every path the app sends back is
 * checked against these roots: nothing outside a skills folder is touched.
 *
 * Plugins (Settings › Plugins), per agent:
 *   Claude   its CLI (`claude plugin list|install|uninstall|enable|disable`),
 *            with the marketplace catalog for browsing
 *   Codex    [plugins."name@marketplace"] in ~/.codex/config.toml, described by
 *            the manifests in ~/.codex/plugins/cache (`codex plugin list` waits
 *            on remote marketplaces); removed with `codex plugin remove`
 *   Cursor   fetched under ~/.cursor/plugins/cache, managed in Cursor: read-only
 *   Devin    `devin plugins list`; removed with `devin plugins remove`
 *
 * BRIDGE_MCP_HOME points this at a scratch home in tests; the demo seeds one.
 */

const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFile } = require("child_process");
const env = require("./env");

function home() {
  if (!env.demo) return process.env.BRIDGE_MCP_HOME || os.homedir();
  const h = path.join(env.dataDir, "demo-home");
  if (!fs.existsSync(h)) require("./demo").seedSkills(h);
  return h;
}

const AGENTS = ["claude", "codex", "cursor", "devin", "shared"];
const LABEL = { claude: "Claude", codex: "Codex", cursor: "Cursor", devin: "Devin", shared: "Shared" };

/** Where each agent reads skills: [agent, scope, dir]. `repo` adds the project ones. */
function roots(repo = "") {
  const h = home();
  const out = [
    ["claude", "user", path.join(h, ".claude", "skills")],
    ["codex", "user", path.join(h, ".codex", "skills")],
    ["cursor", "user", path.join(h, ".cursor", "skills")],
    ["devin", "user", path.join(h, ".devin", "skills")],
    ["devin", "user", path.join(h, ".config", "devin", "skills")],
    ["shared", "user", path.join(h, ".agents", "skills")],
  ];
  if (repo && fs.existsSync(path.join(repo, ".git"))) {
    out.push(
      ["claude", "project", path.join(repo, ".claude", "skills")],
      ["cursor", "project", path.join(repo, ".cursor", "skills")],
      ["devin", "project", path.join(repo, ".devin", "skills")],
      ["shared", "project", path.join(repo, ".agents", "skills")],
    );
  }
  return out.map(([agent, scope, dir]) => ({ agent, scope, dir }));
}

function frontmatter(text) {
  const m = /^---\n([\s\S]*?)\n---/.exec(text);
  const out = {};
  if (!m) return out;
  for (const line of m[1].split("\n")) {
    const kv = /^([A-Za-z_-]+):\s*(.*)$/.exec(line);
    if (kv) out[kv[1]] = kv[2].replace(/^["']|["']$/g, "").trim();
  }
  return out;
}

const tilde = (p) => (p.startsWith(home()) ? `~${p.slice(home().length)}` : p);

/** Every skill in every root, with where it lives and whether it's a link. */
function listSkills(repo = "") {
  const skills = [];
  const all = roots(repo);
  for (const r of all) {
    let names = [];
    try {
      names = fs.readdirSync(r.dir);
    } catch {
      continue;
    }
    for (const n of names.sort()) {
      if (n.startsWith(".")) continue;
      const dir = path.join(r.dir, n);
      const file = path.join(dir, "SKILL.md");
      let text = "";
      try {
        text = fs.readFileSync(file, "utf8");
      } catch {
        continue;
      }
      const f = frontmatter(text);
      const link = fs.lstatSync(dir).isSymbolicLink();
      let real = dir;
      try {
        real = fs.realpathSync(dir);
      } catch {}
      skills.push({
        id: `${r.agent}:${r.scope}:${n}`,
        name: f.name || n,
        folder: n,
        description: f.description || text.replace(/^---[\s\S]*?---/, "").trim().split("\n")[0] || "",
        agent: r.agent,
        agentLabel: LABEL[r.agent],
        scope: r.scope,
        dir,
        file,
        shown: tilde(dir),
        link: link ? tilde(real) : "",
        size: text.length,
        updatedAt: Math.floor(fs.statSync(file).mtimeMs),
      });
    }
  }
  return { skills, roots: all.map((r) => ({ ...r, shown: tilde(r.dir), exists: fs.existsSync(r.dir) })) };
}

/** `p` must be a skill folder (or its SKILL.md) directly inside one of the roots. */
function checkPath(p, repo, { file = false } = {}) {
  const abs = path.resolve(String(p || ""));
  const dir = file ? path.dirname(abs) : abs;
  if (file && path.basename(abs) !== "SKILL.md") throw new Error("only SKILL.md can be edited here");
  const root = roots(repo).find((r) => path.dirname(dir) === r.dir);
  if (!root || path.basename(dir).startsWith(".")) throw new Error(`not a skill folder Bridge manages: ${p}`);
  return { abs, dir, root };
}

function readSkill(p, repo) {
  const { abs } = checkPath(p, repo, { file: true });
  return { path: abs, text: fs.readFileSync(abs, "utf8") };
}

function writeSkill(p, text, repo) {
  const { abs } = checkPath(p, repo, { file: true });
  if (typeof text !== "string" || text.length > 400_000) throw new Error("a SKILL.md needs text (under 400 KB)");
  // Through the link, if it is one: the skill's own file is what agents read.
  const real = fs.existsSync(abs) ? fs.realpathSync(abs) : abs;
  const tmp = `${real}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, text);
  fs.renameSync(tmp, real);
  return { path: abs, size: text.length };
}

const slug = (s) =>
  String(s || "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 60);

function createSkill({ agent = "claude", scope = "user", name, description = "", repo = "" }) {
  const folder = slug(name);
  if (!folder) throw new Error("a skill needs a name");
  const root = roots(repo).find((r) => r.agent === agent && r.scope === scope);
  if (!root) throw new Error(scope === "project" ? "pick a project with a git checkout for a project skill" : `no ${agent} skills folder`);
  const dir = path.join(root.dir, folder);
  if (fs.existsSync(dir)) throw new Error(`${tilde(dir)} already exists`);
  fs.mkdirSync(dir, { recursive: true });
  const desc = String(description || "").replace(/\s+/g, " ").trim() || `What ${folder} does, and when to use it.`;
  const text = `---\nname: ${folder}\ndescription: ${desc}\n---\n\n# ${String(name).trim()}\n\nInstructions for the agent go here.\n`;
  fs.writeFileSync(path.join(dir, "SKILL.md"), text);
  return { dir, file: path.join(dir, "SKILL.md") };
}

/** To the Trash (recoverable), or just the link for a symlinked skill. */
function deleteSkill(p, repo) {
  const { dir } = checkPath(p, repo);
  if (fs.lstatSync(dir).isSymbolicLink()) {
    fs.unlinkSync(dir);
    return { removed: dir, trashed: "", link: true };
  }
  const trash = path.join(home(), ".Trash");
  fs.mkdirSync(trash, { recursive: true });
  let to = path.join(trash, path.basename(dir));
  if (fs.existsSync(to)) to = `${to} ${new Date().toISOString().replace(/[:.]/g, "-")}`;
  fs.renameSync(dir, to);
  return { removed: dir, trashed: to, link: false };
}

/* -------------------------------------------------------------- plugins */

const cliEnv = () => {
  const e = { ...process.env, PATH: `${env.extraPath}:${process.env.PATH || "/usr/bin:/bin"}` };
  delete e.ACP_BACKEND;
  return e;
};
const sh = (cmd, args, timeout = 60000) =>
  new Promise((resolve) =>
    execFile(cmd, args, { cwd: home(), timeout, maxBuffer: 64e6, env: cliEnv() }, (err, out, errOut) =>
      resolve({ ok: !err, out: String(out || ""), err: String(errOut || (err && err.message) || "").trim() }),
    ),
  );

let catalog = null; // { at, data }: the marketplace list is big and slow, and changes rarely
const CATALOG_TTL = 10 * 60_000;

function shapeInstalled(p) {
  const id = p.pluginId || p.id || p.name || "";
  return {
    id,
    name: p.name || id.split("@")[0],
    marketplace: p.marketplaceName || p.marketplace || id.split("@")[1] || "",
    version: p.version || "",
    description: p.description || "",
    enabled: p.enabled !== false,
    scope: p.scope || "user",
    dir: p.installPath || p.path || "",
  };
}

async function claudePlugins({ refresh = false } = {}) {
  if (env.demo) return require("./demo").plugins().claude;
  if (!refresh && catalog && Date.now() - catalog.at < CATALOG_TTL) return catalog.data;
  const r = await sh(env.claudeBin, ["plugin", "list", "--available", "--json"]);
  if (!r.ok) return { ok: false, error: r.err.split("\n")[0] || "claude plugin list failed", installed: [], available: [] };
  let j = {};
  try {
    j = JSON.parse(r.out);
  } catch {
    return { ok: false, error: "couldn't read `claude plugin list --json`", installed: [], available: [] };
  }
  const installed = (Array.isArray(j) ? j : j.installed || []).map(shapeInstalled);
  const have = new Set(installed.map((p) => p.id));
  const available = (j.available || [])
    .filter((p) => !have.has(p.pluginId))
    .sort((a, b) => (b.installCount || 0) - (a.installCount || 0))
    .map((p) => ({ id: p.pluginId, name: p.name, marketplace: p.marketplaceName || "", description: String(p.description || "").slice(0, 400), installs: p.installCount || 0 }));
  const data = { ok: true, installed, available };
  catalog = { at: Date.now(), data };
  return data;
}

/** Install, uninstall, enable or disable one of Claude Code's plugins. */
async function claudePlugin(action, id) {
  if (!["install", "uninstall", "enable", "disable"].includes(action)) throw new Error(`unknown action: ${action}`);
  if (!/^[A-Za-z0-9][A-Za-z0-9._@/-]*$/.test(String(id || ""))) throw new Error("bad plugin id");
  if (env.demo) return { ok: true, demo: true };
  const args = ["plugin", action, id];
  if (action === "install") args.push("--scope", "user");
  const r = await sh(env.claudeBin, args, 180000);
  catalog = null;
  if (!r.ok) throw new Error(r.err.split("\n").filter(Boolean).slice(-1)[0] || `claude plugin ${action} failed`);
  return { ok: true, output: r.out.trim().slice(-2000) };
}

/** Cursor's fetched plugins: newest copy of each, from its manifest. Read-only. */
function cursorPlugins() {
  if (env.demo) return require("./demo").plugins().cursor;
  const base = path.join(home(), ".cursor", "plugins", "cache");
  const out = [];
  let markets = [];
  try {
    markets = fs.readdirSync(base);
  } catch {
    return { ok: true, plugins: [] };
  }
  for (const m of markets) {
    let names = [];
    try {
      names = fs.readdirSync(path.join(base, m));
    } catch {
      continue;
    }
    for (const n of names) {
      const pdir = path.join(base, m, n);
      let versions = [];
      try {
        versions = fs.readdirSync(pdir).map((v) => path.join(pdir, v)).filter((v) => fs.statSync(v).isDirectory());
      } catch {
        continue;
      }
      const dir = versions.sort((a, b) => fs.statSync(b).mtimeMs - fs.statSync(a).mtimeMs)[0];
      if (!dir) continue;
      let man = {};
      for (const f of [".cursor-plugin/plugin.json", ".claude-plugin/plugin.json", "plugin.json"]) {
        try {
          man = JSON.parse(fs.readFileSync(path.join(dir, f), "utf8"));
          break;
        } catch {}
      }
      let skills = 0;
      try {
        skills = fs.readdirSync(path.join(dir, "skills")).filter((s) => fs.existsSync(path.join(dir, "skills", s, "SKILL.md"))).length;
      } catch {}
      out.push({
        id: `${n}@${m}`,
        name: man.name || n,
        marketplace: m === "__DEFAULT__" ? "team" : m,
        version: man.version || "",
        description: String(man.description || "").slice(0, 400),
        homepage: man.homepage || man.repository || "",
        mcp: fs.existsSync(path.join(dir, ".mcp.json")),
        skills,
        dir,
      });
    }
  }
  return { ok: true, plugins: out.sort((a, b) => a.name.localeCompare(b.name)) };
}

/** A plugin manifest under `dir`, whichever agent wrote it. */
function manifest(dir) {
  for (const f of [".codex-plugin/plugin.json", ".cursor-plugin/plugin.json", ".claude-plugin/plugin.json", "plugin.json"]) {
    try {
      return JSON.parse(fs.readFileSync(path.join(dir, f), "utf8"));
    } catch {}
  }
  return {};
}

/** Codex's installed plugins: config.toml's [plugins."id"] tables, newest cached copy for the details. */
function codexPlugins() {
  if (env.demo) return require("./demo").plugins().codex;
  const codexHome = process.env.CODEX_HOME || path.join(home(), ".codex");
  let text = "";
  try {
    text = fs.readFileSync(path.join(codexHome, "config.toml"), "utf8");
  } catch {
    return { ok: true, plugins: [] };
  }
  const out = [];
  let cur = null;
  for (const line of text.split("\n")) {
    const head = /^\s*\[(.+)\]\s*(?:#.*)?$/.exec(line);
    if (head) {
      const m = /^plugins\."([^"]+)"$/.exec(head[1].trim());
      cur = m ? { id: m[1], enabled: true } : null;
      if (cur) out.push(cur);
      continue;
    }
    const en = cur && /^\s*enabled\s*=\s*(true|false)\b/.exec(line);
    if (en) cur.enabled = en[1] === "true";
  }
  return {
    ok: true,
    plugins: out
      .map(({ id, enabled }) => {
        const [name, market = ""] = id.split("@");
        const pdir = path.join(codexHome, "plugins", "cache", market, name);
        let dir = "";
        try {
          dir = fs.readdirSync(pdir).map((v) => path.join(pdir, v)).filter((v) => fs.statSync(v).isDirectory()).sort((a, b) => fs.statSync(b).mtimeMs - fs.statSync(a).mtimeMs)[0] || "";
        } catch {}
        const man = dir ? manifest(dir) : {};
        const ui = man.interface || {};
        return { id, name: ui.displayName || man.name || name, marketplace: market, version: man.version || "", description: String(ui.shortDescription || man.description || "").slice(0, 400), enabled, dir };
      })
      .sort((a, b) => a.name.localeCompare(b.name)),
  };
}

/** Devin's installed plugins, from `devin plugins list` ("• name (source) v1.2.0"). */
async function devinPlugins() {
  if (env.demo) return require("./demo").plugins().devin;
  const r = await sh("devin", ["plugins", "list", "--process-model", "in-process"], 30000);
  if (!r.ok) return { ok: false, error: /ENOENT/.test(r.err) ? "Devin isn't installed" : r.err.split("\n")[0] || "devin plugins list failed", plugins: [] };
  return { ok: true, plugins: parseDevinPlugins(r.out) };
}

function parseDevinPlugins(text) {
  const out = [];
  for (const line of String(text).split("\n")) {
    const m = /^\s*[•*-]\s+(\S+)(?:\s+\(([^)]*)\))?\s+(?:v(\S+)|unversioned)(.*)$/.exec(line);
    if (!m) continue;
    const source = m[2] || "";
    // Two installs can share a name: the source tells them apart (and is what `remove` takes then).
    out.push({ id: source ? `${m[1]}@${source}` : m[1], name: m[1], marketplace: source.split("#")[0], version: m[3] || "", blocked: /blocked/i.test(m[4]), remove: m[1] });
  }
  return out;
}

/** Remove one of Codex's or Devin's plugins through its own CLI. */
async function agentPlugin(agent, action, id) {
  if (agent === "claude") return claudePlugin(action, id);
  if (!/^[A-Za-z0-9][A-Za-z0-9._@/#:-]*$/.test(String(id || ""))) throw new Error("bad plugin id");
  if (action !== "remove") throw new Error(`unknown action: ${action}`);
  if (env.demo) return { ok: true, demo: true };
  const args = { codex: ["codex", ["plugin", "remove", id]], devin: ["devin", ["plugins", "remove", id, "--yes", "--process-model", "in-process"]] }[agent];
  if (!args) throw new Error(`${agent} plugins can't be changed from Bridge`);
  const r = await sh(args[0], args[1], 120000);
  if (!r.ok) throw new Error(r.err.split("\n").filter(Boolean).slice(-1)[0] || `${agent} plugin remove failed`);
  return { ok: true, output: r.out.trim().slice(-2000) };
}

module.exports = { roots, listSkills, readSkill, writeSkill, createSkill, deleteSkill, claudePlugins, claudePlugin, cursorPlugins, codexPlugins, devinPlugins, parseDevinPlugins, agentPlugin, home, AGENTS, LABEL };
