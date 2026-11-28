/**
 * One memory per project, shared by Claude Code, Codex, Cursor and Devin.
 *
 * It lives in `data/memory/<project id>/`: a `MEMORY.md` index (one line per
 * memory) and one topic file per fact, with frontmatter `name`, `description`
 * and `metadata.type` (user | feedback | project | reference). Every session
 * Bridge starts gets the index (`block()`); agents started anywhere else find
 * it through the pointers `connect()` writes into each agent's own global
 * instructions.
 *
 * Agents never edit it. They write a proposal, a whole topic file, into the
 * folder's `.proposed/`, which nothing loads; you approve or discard it on the
 * Memory page. Approving writes the file and its index line together, so the
 * index and the folder can't drift.
 */

const fs = require("fs");
const os = require("os");
const path = require("path");
const env = require("./env");
const projects = require("./projects");

const ROOT = path.join(env.dataDir, "memory");
const REPO = path.join(__dirname, "..");
const PROPOSED = ".proposed";
const TYPES = ["user", "feedback", "project", "reference"];
const INDEX_CAP = 25000;

/** A project's memory folder, or throw for an unknown project. */
function dirOf(projectId) {
  const p = projects.get(String(projectId || ""));
  if (!p) throw new Error(`no such project: ${projectId}`);
  return path.join(ROOT, p.id);
}

/** `name`, `description` and `metadata.type` from a topic file's frontmatter. */
function describe(text, file) {
  const fm = text.startsWith("---\n") ? text.slice(4, text.indexOf("\n---", 4) + 1) : "";
  // Quoted YAML scalars: the quotes and their escapes are syntax, not content.
  const field = (k) => {
    const raw = (fm.match(new RegExp(`^\\s*${k}:\\s*(.+)$`, "m")) || [, ""])[1].trim();
    const m = raw.match(/^(['"])([\s\S]*)\1$/);
    if (!m) return raw;
    return m[1] === '"' ? m[2].replace(/\\(["\\])/g, "$1") : m[2].replace(/''/g, "'");
  };
  const heading = (text.match(/^#\s+(.+)$/m) || [, ""])[1].trim();
  return { title: field("name") || heading || file.replace(/\.md$/, ""), desc: field("description"), type: field("type") };
}

function files(dir) {
  let names;
  try {
    names = fs.readdirSync(dir);
  } catch {
    return [];
  }
  const out = [];
  for (const name of names) {
    if (!name.endsWith(".md")) continue;
    try {
      const file = path.join(dir, name);
      const stat = fs.statSync(file);
      if (!stat.isFile()) continue;
      out.push({ name, size: stat.size, mtime: Math.floor(stat.mtimeMs / 1000), ...describe(fs.readFileSync(file, "utf8"), name) });
    } catch {}
  }
  return out.sort((a, b) => (a.name === "MEMORY.md" ? -1 : b.name === "MEMORY.md" ? 1 : a.name.localeCompare(b.name)));
}

/** The index first, then every memory; pending proposals beside them. */
function list(projectId) {
  const dir = dirOf(projectId);
  const live = files(dir);
  const names = new Set(live.map((f) => f.name));
  const idx = live.find((f) => f.name === "MEMORY.md");
  return {
    dir,
    project: projectId,
    files: live,
    proposals: files(path.join(dir, PROPOSED)).map((f) => ({ ...f, updates: names.has(f.name) })),
    indexBytes: idx ? idx.size : 0,
  };
}

/** A bare `*.md` name inside the folder (or its `.proposed/`), or throw. */
function resolve(projectId, name, proposed = false) {
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]*\.md$/.test(String(name || ""))) throw new Error("memory files are named like feedback-thing.md");
  const dir = proposed ? path.join(dirOf(projectId), PROPOSED) : dirOf(projectId);
  const file = path.resolve(dir, name);
  if (path.dirname(file) !== path.resolve(dir)) throw new Error("outside the memory folder");
  return file;
}

function read(projectId, name, proposed = false) {
  return { name, text: fs.readFileSync(resolve(projectId, name, proposed), "utf8") };
}

function save(file, text) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, text.endsWith("\n") ? text : text + "\n");
  fs.renameSync(tmp, file);
}

function checkText(text) {
  if (typeof text !== "string" || !text.trim()) throw new Error("a memory needs text");
  if (text.length > 500_000) throw new Error("that is too long to be a memory");
}

/** Edit a memory, or the index, that already exists. */
function write(projectId, name, text) {
  const file = resolve(projectId, name);
  if (!fs.existsSync(file)) throw new Error(`no such memory: ${name}`);
  checkText(text);
  save(file, text);
  return { name, savedAt: Math.floor(Date.now() / 1000) };
}

/* ------------------------------------------------------------------ index */

// `MEMORY.md` entries are `- [Title](file.md) — hook` under `#` headings;
// anything else in the file is carried through untouched.
const ENTRY = /^\s*-\s*\[[^\]]*\]\(([^)]+)\)/;

function readIndex(dir) {
  try {
    return fs.readFileSync(path.join(dir, "MEMORY.md"), "utf8");
  } catch {
    return "";
  }
}

/** Add one entry under `section` (a new trailing section if it's missing);
 *  never a second line for a file already listed. */
function addToIndex(text, { name, title, hook, section }) {
  const lines = text.split("\n");
  if (lines.some((l) => (l.match(ENTRY) || [, ""])[1] === name)) return text;
  const one = (s) => String(s || "").replace(/\s+/g, " ").trim();
  const entry = `- [${one(title).replace(/[[\]]/g, "")}](${name})${one(hook) ? ` — ${one(hook)}` : ""}`;
  const heading = one(section);
  const at = heading ? lines.findIndex((l) => /^#{1,6}\s/.test(l) && l.replace(/^#{1,6}\s*/, "").trim() === heading) : -1;
  if (at === -1) {
    const body = text.replace(/\s*$/, "");
    return `${body ? `${body}\n\n` : ""}${heading ? `# ${heading}\n\n` : ""}${entry}\n`;
  }
  let end = at + 1;
  for (let i = at + 1; i < lines.length; i++) {
    if (/^#{1,6}\s/.test(lines[i])) break;
    if (lines[i].trim()) end = i + 1;
  }
  lines.splice(end, 0, entry);
  return lines.join("\n");
}

/** Drop a file's entry, and its heading if that leaves the section empty. */
function removeFromIndex(text, name) {
  const lines = text.split("\n").filter((l) => (l.match(ENTRY) || [, ""])[1] !== name);
  const out = [];
  for (let i = 0; i < lines.length; i++) {
    if (/^#{1,6}\s/.test(lines[i])) {
      let hasBody = false;
      for (let j = i + 1; j < lines.length && !/^#{1,6}\s/.test(lines[j]); j++) if (lines[j].trim()) hasBody = true;
      if (!hasBody) {
        while (i + 1 < lines.length && !lines[i + 1].trim()) i++;
        continue;
      }
    }
    out.push(lines[i]);
  }
  return out.join("\n").replace(/\n{3,}/g, "\n\n").replace(/\s*$/, "\n");
}

/* --------------------------------------------------- approve and discard */

/**
 * A proposal becomes a memory: written into the folder (replacing the memory
 * of the same name, if it amends one) and listed in the index. `text` is the
 * proposal as you last edited it.
 */
function approve(projectId, name, text) {
  if (name === "MEMORY.md") throw new Error("MEMORY.md is the index, not a memory");
  const from = resolve(projectId, name, true);
  if (!fs.existsSync(from)) throw new Error(`no such proposal: ${name}`);
  const body = typeof text === "string" ? text : fs.readFileSync(from, "utf8");
  checkText(body);
  const meta = describe(body, name);
  if (!meta.desc) throw new Error("frontmatter needs a description: it is what the index line says");
  if (!TYPES.includes(meta.type)) throw new Error(`frontmatter needs metadata.type of ${TYPES.join(" | ")}`);
  const dir = dirOf(projectId);
  save(resolve(projectId, name), body);
  save(path.join(dir, "MEMORY.md"), addToIndex(readIndex(dir), { name, title: meta.title, hook: meta.desc }));
  fs.rmSync(from, { force: true });
  return { name, approvedAt: Math.floor(Date.now() / 1000) };
}

function discard(projectId, name) {
  fs.rmSync(resolve(projectId, name, true), { force: true });
  return { name };
}

/** Delete a memory and its index line. */
function remove(projectId, name) {
  if (name === "MEMORY.md") throw new Error("MEMORY.md is the index, not a memory");
  const file = resolve(projectId, name);
  if (!fs.existsSync(file)) throw new Error(`no such memory: ${name}`);
  fs.rmSync(file);
  const dir = dirOf(projectId);
  save(path.join(dir, "MEMORY.md"), removeFromIndex(readIndex(dir), name));
  return { name };
}

/* ------------------------------------------------------------- sessions */

const HOW_TO_PROPOSE = (dir) =>
  `To remember something durable (it generalises beyond this task, isn't in the repo, and was non-obvious), don't edit these files: write the whole topic file, frontmatter \`name\`, \`description\` (one sentence) and \`metadata.type\` (user | feedback | project | reference), to \`${path.join(dir, PROPOSED)}/<kebab-name>.md\`. Reuse an existing file's name to amend it. It is used once approved in Bridge.`;

/** What a session is told: the index, capped, and how to propose. */
function block(projectId) {
  let dir;
  try {
    dir = dirOf(projectId);
  } catch {
    return "";
  }
  let index = readIndex(dir).trim();
  if (index.length > INDEX_CAP) index = `${index.slice(0, INDEX_CAP)}\n(index cut short)`;
  const head = `## This project's memory\nShared by every agent. Topic files are in ${dir}: open one when its line below bears on the task.`;
  return `${head}\n\n${index || "(empty so far)"}\n\n${HOW_TO_PROPOSE(dir)}\n`;
}

/* -------------------------------------------- agents started elsewhere */

// The agents' own homes. BRIDGE_MCP_HOME is the scratch home tests use, and
// wins over the agents' own overrides so a test can never reach the real ones.
const scratch = () => process.env.BRIDGE_MCP_HOME;
const home = () => scratch() || os.homedir();
const claudeDir = () => (!scratch() && process.env.CLAUDE_CONFIG_DIR) || path.join(home(), ".claude");
const codexDir = () => (!scratch() && process.env.CODEX_HOME) || path.join(home(), ".codex");
const BEGIN = "<!-- bridge:memory -->";

// Only the main checkout's own data/ speaks for your home: a scratch data dir
// (BRIDGE_DATA_DIR=/tmp/..., a worktree's server, tests) would point every
// agent at its own throwaway memory. A scratch home is always fair game.
function ownsHome() {
  if (scratch()) return true;
  if (env.demo || env.dataDir !== path.join(REPO, "data")) return false;
  try {
    return fs.statSync(path.join(REPO, ".git")).isDirectory(); // a worktree's .git is a file
  } catch {
    return false;
  }
}
const END = "<!-- /bridge:memory -->";

function pointer() {
  const rows = projects.withRoot().filter((p) => !p.root || fs.existsSync(path.join(ROOT, p.id, "MEMORY.md")));
  const lines = rows.map((p) => `- ${p.path}${p.root ? "" : ` (and its worktrees in ${p.path}-worktrees/)`}: ${path.join(ROOT, p.id, "MEMORY.md")}`);
  return [
    "## Shared memory",
    "",
    "Claude Code, Codex, Cursor and Devin share one memory per project, kept by Bridge. When you work in one of these folders, read its MEMORY.md index first and open the topic files beside it whose line bears on the task:",
    "",
    ...lines,
    "",
    "To remember something, write a proposal into that folder's `.proposed/` (the whole topic file with frontmatter `name`, `description`, `metadata.type`); it is used once approved in Bridge. Never edit the memory files directly.",
  ].join("\n");
}

/** Replace Bridge's marked block in a Markdown file, keeping the rest. */
function upsertBlock(file, body) {
  let text = "";
  try {
    text = fs.readFileSync(file, "utf8");
  } catch {}
  const block = `${BEGIN}\n${body}\n${END}`;
  const at = text.indexOf(BEGIN);
  const end = text.indexOf(END);
  const next = at >= 0 && end > at ? text.slice(0, at) + block + text.slice(end + END.length) : `${text.replace(/\s*$/, "")}${text.trim() ? "\n\n" : ""}${block}\n`;
  if (next !== text) save(file, next);
}

/**
 * Point every agent at the shared memory, wherever it is started:
 * Claude Code (and Devin, which reads it too) through ~/.claude/CLAUDE.md,
 * Codex through ~/.codex/AGENTS.md, Cursor through a user rule. Claude's own
 * auto memory is turned off, so it proposes like the rest instead of writing
 * a second memory under ~/.claude/projects. Idempotent; run at startup and
 * whenever projects change. Only the real server touches your home (`ownsHome`).
 */
function connect() {
  if (!ownsHome()) return;
  const body = pointer();
  upsertBlock(path.join(claudeDir(), "CLAUDE.md"), body);
  upsertBlock(path.join(codexDir(), "AGENTS.md"), body);
  const rule = `---\ndescription: Shared memory for every project Bridge knows\nalwaysApply: true\n---\n\n${body}\n`;
  const ruleFile = path.join(home(), ".cursor", "rules", "bridge-memory.mdc");
  let old = "";
  try {
    old = fs.readFileSync(ruleFile, "utf8");
  } catch {}
  if (old !== rule) save(ruleFile, rule);

  const settings = path.join(claudeDir(), "settings.json");
  let json = {};
  try {
    json = JSON.parse(fs.readFileSync(settings, "utf8"));
  } catch (e) {
    if (e.code !== "ENOENT") return; // never rewrite a settings file we couldn't parse
  }
  if (json.autoMemoryEnabled !== false) save(settings, JSON.stringify({ ...json, autoMemoryEnabled: false }, null, 2));
}

module.exports = { ROOT, dirOf, list, read, write, approve, discard, remove, block, connect, addToIndex, removeFromIndex };
