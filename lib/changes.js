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
  // NUL-separated (-z): paths with spaces, quotes or non-ASCII come back
  // verbatim instead of C-quoted, so they match what `git diff -- <path>` takes.
  const [porcelain, branch, upstream] = await Promise.all([
    git(["status", "--porcelain=v1", "-z", "-uall"], dir),
    git(["rev-parse", "--abbrev-ref", "HEAD"], dir).catch(() => ""),
    git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], dir).catch(() => ""),
  ]);
  const numstat = await git(["diff", "HEAD", "--numstat", "-z"], dir).catch(() => "");
  const counts = new Map();
  const ns = numstat.split("\0");
  for (let i = 0; i < ns.length; i++) {
    if (!ns[i]) continue;
    const [a, d, f] = ns[i].split("\t");
    // A rename is "a\td\t" then the old and the new path as their own fields.
    const file = f === "" ? ns[(i += 2)] : f;
    if (file) counts.set(file, { additions: Number(a) || 0, deletions: Number(d) || 0 });
  }
  const files = [];
  const st = porcelain.split("\0");
  for (let i = 0; i < st.length && files.length < 500; i++) {
    const l = st[i];
    if (l.length < 4) continue;
    const code = l.slice(0, 2);
    const file = l.slice(3);
    if (code[0] === "R" || code[0] === "C") i++; // the next field is the old path
    const kind = code.includes("?") ? "added" : code.includes("D") ? "deleted" : code.includes("A") ? "added" : code.includes("R") ? "renamed" : "modified";
    files.push({ path: file, kind, staged: code[0] !== " " && code[0] !== "?", ...(counts.get(file) || { additions: 0, deletions: 0 }) });
  }
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
  // Non-interactive gh needs a title and a body; --fill supplies whichever is missing.
  const args = ["pr", "create"];
  if (!title || !body) args.push("--fill");
  if (title) args.push("--title", String(title));
  if (body) args.push("--body", String(body));
  if (draft) args.push("--draft");
  const out = await gh(args, dir);
  const url = (out.match(/https:\/\/github\.com\/\S+\/pull\/\d+/) || [])[0];
  if (!url) throw new Error(out || "gh didn't return a PR link");
  return url;
}

/* ------------------------------------------------------ PR activity */

// What the details panel shows about a session's PR: review state, checks,
// the conversation and inline review comments. Read-only, through `gh`, and
// cached briefly so switching chats doesn't re-ask GitHub every time.
const ACTIVITY_TTL = 45_000;
const activityCache = new Map();

const PR_JSON = "number,title,url,state,isDraft,reviewDecision,mergeable,additions,deletions,headRefName,baseRefName,comments,reviews,statusCheckRollup,updatedAt";

function checkOf(c) {
  // CheckRun: status + conclusion; StatusContext: state.
  const raw = String(c.conclusion || c.state || c.status || "").toUpperCase();
  const pending = c.__typename === "CheckRun" ? c.status !== "COMPLETED" : ["PENDING", "EXPECTED"].includes(raw);
  const state = pending ? "pending" : ["SUCCESS", "NEUTRAL", "SKIPPED"].includes(raw) ? "pass" : "fail";
  return { name: c.name || c.context || "check", workflow: c.workflowName || "", state, url: c.detailsUrl || c.targetUrl || "" };
}

function shapeActivity(pr, inline) {
  const login = (a) => (a && (a.login || a.name)) || "";
  const checks = (pr.statusCheckRollup || []).map(checkOf);
  const reviews = (pr.reviews || [])
    .filter((r) => r.state !== "PENDING")
    .map((r) => ({ author: login(r.author), state: r.state, body: String(r.body || "").trim(), at: r.submittedAt || "" }));
  // Latest verdict per reviewer, for the header row; comments-only reviews
  // with a body still show up in the conversation.
  const verdicts = new Map();
  for (const r of reviews) if (r.state !== "COMMENTED" || !verdicts.has(r.author)) verdicts.set(r.author, r.state);
  const conversation = [
    ...(pr.comments || []).map((c) => ({ kind: "comment", author: login(c.author), body: String(c.body || "").trim(), at: c.createdAt || "", url: c.url || "" })),
    ...reviews.filter((r) => r.body).map((r) => ({ kind: "review", state: r.state, author: r.author, body: r.body, at: r.at, url: "" })),
    ...inline.map((c) => ({ kind: "inline", author: login(c.user), body: String(c.body || "").trim(), at: c.created_at || "", url: c.html_url || "", path: c.path || "", line: c.line || c.original_line || 0 })),
  ].sort((a, b) => String(a.at).localeCompare(String(b.at)));
  return {
    url: pr.url,
    number: pr.number,
    title: pr.title,
    state: pr.state,
    draft: !!pr.isDraft,
    review: pr.reviewDecision || "",
    mergeable: pr.mergeable || "",
    additions: pr.additions || 0,
    deletions: pr.deletions || 0,
    branch: pr.headRefName || "",
    base: pr.baseRefName || "",
    updatedAt: pr.updatedAt || "",
    checks,
    checkCounts: { pass: checks.filter((c) => c.state === "pass").length, fail: checks.filter((c) => c.state === "fail").length, pending: checks.filter((c) => c.state === "pending").length },
    reviewers: [...verdicts].map(([author, state]) => ({ author, state })),
    conversation: conversation.slice(-40),
  };
}

/** A PR's review state, checks and comments, by URL. */
async function activity(prUrl, { refresh = false } = {}) {
  const m = String(prUrl || "").match(/^https:\/\/github\.com\/([^/\s]+)\/([^/\s]+)\/pull\/(\d+)/);
  if (!m) return { pr: null };
  if (env.demo) return { pr: require("./demo").prActivity(prUrl) };
  const key = m[0];
  const hit = activityCache.get(key);
  if (!refresh && hit && Date.now() - hit.at < ACTIVITY_TTL) return hit.data;
  const [view, inline] = await Promise.all([
    gh(["pr", "view", key, "--json", PR_JSON]),
    gh(["api", `repos/${m[1]}/${m[2]}/pulls/${m[3]}/comments?per_page=100`]).then((o) => JSON.parse(o || "[]")).catch(() => []),
  ]);
  const data = { pr: shapeActivity(JSON.parse(view), Array.isArray(inline) ? inline : []) };
  activityCache.set(key, { at: Date.now(), data });
  return data;
}

module.exports = { status, diff, commit, push, openPr, activity, shapeActivity };
