/**
 * The files in a session's folder, for the composer's `@` picker.
 *
 * A git checkout answers with `git ls-files` (tracked, plus untracked files
 * that aren't ignored), which is fast and already skips node_modules and
 * build output. Anything else gets a bounded walk that skips the usual heavy
 * folders. Folders are derived from the file paths, so the picker can offer
 * `src/api/` as well as `src/api/export.js`.
 *
 * Cached per folder for a short while: the picker asks on every `@`.
 */

const fs = require("fs");
const path = require("path");
const { execFile } = require("child_process");

const TTL = 20_000;
const MAX = 20_000;
const SKIP = new Set([".git", "node_modules", ".build", "build", "dist", ".next", ".venv", "venv", "__pycache__", ".cache", "target", "Pods", "DerivedData", ".turbo", ".idea"]);
const cache = new Map();

const git = (dir, args) =>
  new Promise((resolve) => execFile("git", args, { cwd: dir, timeout: 8000, maxBuffer: 64e6 }, (err, out) => resolve(err ? null : String(out))));

function walk(dir) {
  const out = [];
  const queue = [""];
  while (queue.length && out.length < MAX) {
    const rel = queue.shift();
    let entries = [];
    try {
      entries = fs.readdirSync(path.join(dir, rel), { withFileTypes: true });
    } catch {
      continue;
    }
    for (const e of entries) {
      if (e.name.startsWith(".") && e.name !== ".github" && e.name !== ".claude") continue;
      const p = rel ? `${rel}/${e.name}` : e.name;
      if (e.isDirectory()) {
        if (!SKIP.has(e.name)) queue.push(p);
      } else if (e.isFile()) out.push(p);
      if (out.length >= MAX) break;
    }
  }
  return out;
}

/** `{ root, files: [...], dirs: [...], git }`, files relative to root. */
async function list(dir) {
  if (!dir || !path.isAbsolute(dir) || !fs.existsSync(dir)) throw new Error("folder not found");
  const hit = cache.get(dir);
  if (hit && Date.now() - hit.at < TTL) return hit.data;
  let files = null;
  const tracked = await git(dir, ["ls-files", "-z", "--cached", "--others", "--exclude-standard"]);
  if (tracked != null) files = [...new Set(tracked.split("\0").filter(Boolean))];
  const isGit = files != null;
  if (!files) files = walk(dir);
  files = files.slice(0, MAX);
  const dirs = new Set();
  for (const f of files) {
    let i = f.lastIndexOf("/");
    while (i > 0) {
      const d = f.slice(0, i);
      if (dirs.has(d)) break;
      dirs.add(d);
      i = d.lastIndexOf("/");
    }
  }
  const data = { root: dir, git: isGit, files, dirs: [...dirs].sort(), truncated: files.length >= MAX };
  cache.set(dir, { at: Date.now(), data });
  return data;
}

module.exports = { list };
