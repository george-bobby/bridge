/**
 * Common rules: house rules appended to every session's system prompt,
 * worker and orchestrator alike. The default ships in prompts/rules.md;
 * Settings › Agents › Common rules saves an edited copy to data/rules.md,
 * which wins (empty turns them off) until it is reset.
 */

const fs = require("fs");
const path = require("path");

const env = require("./env");

const DEFAULT = path.join(__dirname, "..", "prompts", "rules.md");
const FILE = path.join(env.dataDir, "rules.md");
const MAX = 20000;

const read = (file) => {
  try {
    return fs.readFileSync(file, "utf8");
  } catch {
    return null;
  }
};

const defaults = () => (read(DEFAULT) || "").trim();

/** { text, default, custom } for the Settings editor. */
function get() {
  const own = read(FILE);
  return { text: own == null ? defaults() : own.trim(), default: defaults(), custom: own != null };
}

function save(text) {
  const t = String(text == null ? "" : text).replace(/\r\n/g, "\n").trim();
  if (t.length > MAX) throw new Error(`rules are limited to ${MAX} characters`);
  if (t === defaults()) return reset();
  fs.mkdirSync(path.dirname(FILE), { recursive: true });
  const tmp = `${FILE}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, t + "\n");
  fs.renameSync(tmp, FILE);
  return get();
}

function reset() {
  fs.rmSync(FILE, { force: true });
  return get();
}

/** The prompt section, or "" when the rules are blank. */
function block() {
  const { text } = get();
  return text ? `## Common rules\n\n${text}\n\n` : "";
}

module.exports = { get, save, reset, block, FILE, DEFAULT };
