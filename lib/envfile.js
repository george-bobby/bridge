/**
 * `.env`, read and written for the Settings screen.
 *
 * `.env.example` is the schema: every key it documents is listed, in its
 * order, under its section heading, with its comment as the hint. Keys that
 * are only in `.env` come after, under "Other". Secrets (tokens, keys,
 * passwords) never leave this module: the page learns only whether one is set.
 *
 * Writes edit the file in place, line by line, so your comments, order and
 * untouched values survive. A change takes effect on the next server start.
 */

const fs = require("fs");
const path = require("path");
const env = require("./env");

const ROOT = path.join(__dirname, "..");
const EXAMPLE = path.join(ROOT, ".env.example");
const KEY = /^[A-Za-z_][A-Za-z0-9_]*$/;
const isSecret = (k) => /(TOKEN|SECRET|PASSWORD|API_KEY|_KEY)$/i.test(k);

const LINE = /^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$/;

function unquote(raw) {
  let v = raw.trim();
  if ((v.startsWith('"') && v.endsWith('"') && v.length > 1) || (v.startsWith("'") && v.endsWith("'") && v.length > 1)) return { value: v.slice(1, -1), comment: "" };
  const hash = v.startsWith("#") ? 0 : v.indexOf(" #");
  if (hash >= 0) return { value: v.slice(0, hash).trim(), comment: v.slice(hash).trim().replace(/^#\s*/, "") };
  return { value: v, comment: "" };
}

const read = (f) => {
  try {
    return fs.readFileSync(f, "utf8");
  } catch {
    return "";
  }
};

/** The documented keys, with the current value of each (secrets masked). */
function describe() {
  const current = {};
  for (const line of read(env.ENV_FILE).split("\n")) {
    const m = LINE.exec(line);
    if (m) current[m[1]] = unquote(m[2]).value;
  }
  const out = [];
  let section = "General";
  for (const line of read(EXAMPLE).split("\n")) {
    const heading = /^#\s+([A-Z][^#]{1,40})$/.exec(line.trim());
    if (heading && !LINE.test(line)) {
      section = heading[1].trim();
      continue;
    }
    const m = LINE.exec(line);
    if (!m) continue;
    const { value: example, comment } = unquote(m[2]);
    out.push({ key: m[1], section, hint: comment, example, ...valueOf(m[1], current) });
  }
  for (const key of Object.keys(current)) {
    if (!out.some((e) => e.key === key)) out.push({ key, section: "Other", hint: "", example: "", ...valueOf(key, current) });
  }
  return { file: env.ENV_FILE, entries: out };
}

function valueOf(key, current) {
  const value = current[key] || "";
  return isSecret(key) ? { secret: true, set: !!value, value: "" } : { secret: false, set: !!value, value };
}

function quote(v) {
  if (v === "") return "";
  if (/^[A-Za-z0-9_./:@,+-]*$/.test(v)) return v;
  return v.includes('"') ? `'${v}'` : `"${v}"`;
}

/** Set keys in `.env`. `values` maps KEY to its new value ("" clears it). */
function save(values) {
  const patch = {};
  for (const [k, v] of Object.entries(values || {})) {
    if (!KEY.test(k)) throw new Error(`bad key: ${k}`);
    const s = String(v ?? "");
    if (/[\r\n]/.test(s)) throw new Error(`${k}: one line only`);
    if (s.includes('"') && s.includes("'")) throw new Error(`${k}: use either ' or ", not both`);
    patch[k] = s;
  }
  const lines = read(env.ENV_FILE).split("\n");
  const done = new Set();
  for (let i = 0; i < lines.length; i++) {
    const m = LINE.exec(lines[i]);
    if (!m || !(m[1] in patch)) continue;
    const { comment } = unquote(m[2]);
    lines[i] = `${m[1]}=${quote(patch[m[1]])}${comment ? `   # ${comment}` : ""}`;
    done.add(m[1]);
  }
  const added = Object.keys(patch).filter((k) => !done.has(k));
  if (added.length) {
    if (lines.length && lines[lines.length - 1] !== "") lines.push("");
    for (const k of added) lines.push(`${k}=${quote(patch[k])}`);
  }
  const tmp = `${env.ENV_FILE}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, lines.join("\n").replace(/\n*$/, "\n"), { mode: 0o600 });
  fs.renameSync(tmp, env.ENV_FILE);
  return { changed: Object.keys(patch) };
}

module.exports = { describe, save, isSecret };
