/**
 * The pipeline every new worker opens with: its first message is the task
 * (the Linear issue / Slack thread link, else the brief), then the pipeline,
 * then Bridge's per-run lines. Same text for every agent, so nothing depends
 * on a skill being installed. The default ships in prompts/pipeline.md;
 * Settings › Pipeline saves an edited copy to data/pipeline.md, which wins
 * (empty turns it off: workers just read their brief) until it is reset.
 */

const fs = require("fs");
const path = require("path");

const env = require("./env");

const DEFAULT = path.join(__dirname, "..", "prompts", "pipeline.md");
const FILE = path.join(env.dataDir, "pipeline.md");
const MAX = 40000;

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
  if (t.length > MAX) throw new Error(`the pipeline is limited to ${MAX} characters`);
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

const LINEAR = /https:\/\/linear\.app\/[^\s)>\]"'`]+\/issue\/[^\s)>\]"'`]+/;
const SLACK = /https:\/\/[\w.-]*slack\.com\/archives\/[^\s)>\]"'`]+/;

/** The Linear issue or Slack thread a brief is about, Linear first. */
function sourceUrl(text) {
  const s = String(text || "");
  return (LINEAR.exec(s) || SLACK.exec(s) || [""])[0].replace(/[.,;:]+$/, "");
}

const fill = (text, values) => text.replace(/\{\{([A-Z_]+)\}\}/g, (w, k) => (values[k] != null ? String(values[k]) : w));

/**
 * The opening message, or null when the pipeline is blank (off).
 * task: what to work on (a link, the brief, or where the brief is);
 * values: {{URL}}, {{BRIEF}}, {{USER}}, {{BRIDGE}}; rules: Bridge's lines.
 */
function prompt({ task, values = {}, rules = "" }) {
  const { text } = get();
  if (!text) return null;
  return [`# Task\n\n${String(task || "").trim()}`, fill(text, values), rules].filter(Boolean).join("\n\n");
}

module.exports = { get, save, reset, prompt, sourceUrl, FILE, DEFAULT };
