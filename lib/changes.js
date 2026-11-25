/**
 * A session's changes: what its working folder has that the branch doesn't
 * (uncommitted) and what the branch has that the remote doesn't (unpushed),
 * with per-file diffs, and the three actions you take on them from the app:
 * commit, push, open a PR. Each action runs only on your click.
 */

const fs = require("fs");
const path = require("path");
const { execFile } = require("child_process");
const env = require("./env");

function git(args, cwd, timeout = 60000) {
  return new Promise((resolve, reject) =>
    execFile("git", args, { cwd, timeout, maxBuffer: 32e6 }, (err, out, errOut) => (err ? reject(new Error(String(errOut || err.message).trim().split("\n").slice(-2).join(" "))) : resolve(String(out)))),
  );
}

const gh = (args, cwd) =>
  new Promise((resolve, reject) =>
    execFile("gh", args, { cwd, timeout: 60000, env: { ...process.env, PATH: `${env.extraPath}:${process.env.PATH || ""}` } }, (err, out, errOut) =>
      err ? reject(new Error(String(errOut || err.message).trim().split("\n").slice(-2).join(" "))) : resolve(String(out).trim()),
    ),
  );

async function status(dir) {
  if (!dir || !fs.existsSync(path.join(dir, ".git"))) return { repo: false, files: [] };
  const [porcelain, branch, upstream] = await Promise.all([
    git(["status", "--porcelain=v1", "-uall"], dir),
    git(["rev-parse", "--abbrev-ref", "HEAD"], dir).catch(() => ""),
    git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], dir).catch(() => ""),
  ]);
  const numstat = await git(["diff", "HEAD", "--numstat"], dir).catch(() => "");
  const counts = new Map(numstat.trim().split("\n").filter(Boolean).map((l) => {
    const [a, d, f] = l.split("\t");
    return [f, { additions: Number(a) || 0, deletions: Number(d) || 0 }];
  }));
  const files = porcelain.split("\n").filter(Boolean).slice(0, 500).map((l) => {
    const code = l.slice(0, 2);
    const file = l.slice(3).replace(/^.* -> /, "");
    const kind = code.includes("?") ? "added" : code.includes("D") ? "deleted" : code.includes("A") ? "added" : code.includes("R") ? "renamed" : "modified";
    return { path: file, kind, staged: code[0] !== " " && code[0] !== "?", ...(counts.get(file) || { additions: 0, deletions: 0 }) };
  });
  let unpushed = 0;
  try {
    unpushed = Number((await git(["rev-list", "--count", upstream ? "@{u}..HEAD" : "HEAD", ...(upstream ? [] : ["--not", "--remotes"])], dir)).trim()) || 0;
  } catch {}
  const log = await git(["log", "-5", "--format=%h\t%s\t%cr"], dir).catch(() => "");
  return {
    repo: true,
    dir,
    branch: branch.trim(),
    upstream: upstream.trim(),
    unpushed,
    files,
    commits: log.trim().split("\n").filter(Boolean).map((l) => {
      const [sha, subject, when] = l.split("\t");
      return { sha, subject, when };
    }),
  };
}

/** One file's diff against HEAD; an untracked file shows as all added. */
async function diff(dir, file) {
  const rel = path.normalize(String(file || ""));
  const abs = path.resolve(dir, rel);
  if (!abs.startsWith(path.resolve(dir) + path.sep)) throw new Error("outside the working folder");
  const out = await git(["diff", "HEAD", "--", rel], dir).catch(() => "");
  if (out.trim()) return out.slice(0, 400_000);
  try {
    const text = fs.readFileSync(abs, "utf8").split("\n").slice(0, 2000);
    return `--- /dev/null\n+++ b/${rel}\n@@ -0,0 +1,${text.length} @@\n${text.map((l) => `+${l}`).join("\n")}`;
  } catch {
    return "";
  }
}

async function commit(dir, message) {
  const msg = String(message || "").trim();
  if (!msg) throw new Error("a commit needs a message");
  await git(["add", "-A"], dir);
  await git(["commit", "-m", msg], dir);
  return status(dir);
}

async function push(dir) {
  const branch = (await git(["rev-parse", "--abbrev-ref", "HEAD"], dir)).trim();
  if (!branch || branch === "HEAD") throw new Error("not on a branch");
  await git(["push", "-u", "origin", branch], dir, 120000);
  return status(dir);
}

/** `gh pr create` for the folder's branch; returns the PR URL. */
async function openPr(dir, { title, body, draft }) {
  const args = ["pr", "create", "--fill"];
  if (title) args.push("--title", String(title));
  if (body) args.push("--body", String(body));
  if (draft) args.push("--draft");
  const out = await gh(args, dir);
  const url = (out.match(/https:\/\/github\.com\/\S+\/pull\/\d+/) || [])[0];
  if (!url) throw new Error(out || "gh didn't return a PR link");
  return url;
}

module.exports = { status, diff, commit, push, openPr };
