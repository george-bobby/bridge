/**
 * What Bridge can work out instead of asking: who you are on GitHub, Slack and
 * Linear, which repo the Slack pipeline works in and its GitHub owner/name, and
 * your login shell's PATH (launchd starts the server with almost none).
 *
 *   GitHub   `gh api user` (the gh CLI's own login)
 *   Slack    auth.test + users.info on SLACK_USER_TOKEN
 *   Linear   viewer, organization and teams on LINEAR_API_KEY
 *   Repo     the project picked in Settings › Integrations › Slack
 *            (config.harness.pipelineProject), its `origin` remote
 *   PATH     `$SHELL -ilc 'echo $PATH'`
 *
 * Resolved in the background on start and after Settings saves, and cached in
 * data/identity.json so `server/render.js` (a separate process, run before the
 * server) can fill the pipeline skill from it. `apply(env)` merges the facts
 * into env wherever .env didn't set the key itself: an explicit .env value is
 * always an override, never overwritten.
 */

const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFile } = require("child_process");
const env = require("./env");

const FILE = path.join(env.dataDir, "identity.json");
const DEFAULT_EXTRA = `${process.env.HOME || "~"}/.local/bin:/opt/homebrew/bin`;

function cached() {
  try {
    return JSON.parse(fs.readFileSync(FILE, "utf8")) || {};
  } catch {
    return {};
  }
}

function sh(cmd, args, { cwd, timeout = 10000, extraPath = env.extraPath } = {}) {
  return new Promise((resolve) =>
    execFile(cmd, args, { cwd: cwd || os.homedir(), timeout, env: { ...process.env, PATH: `${extraPath}:${process.env.PATH || "/usr/bin:/bin"}` } }, (err, out) =>
      resolve(err ? "" : String(out || "").trim()),
    ),
  );
}

/** owner/name from a GitHub remote URL (https or ssh), else "". */
function slugOf(remote) {
  const m = String(remote || "").match(/github\.com[:/]([^/\s]+)\/([^/\s]+?)(?:\.git)?\/?$/);
  return m ? `${m[1]}/${m[2]}` : "";
}

/** The Slack pipeline's repo: the picked project, else TARGET_REPO. */
function pipelineRepo(config) {
  const id = config && config.harness && config.harness.pipelineProject;
  if (id) {
    const p = require("./projects").get(id);
    if (p && !p.root && p.path) return { path: p.path, project: p.id, name: p.name };
  }
  if (env.raw.targetRepo) return { path: env.raw.targetRepo, project: "", name: path.basename(env.raw.targetRepo) };
  // Nothing picked and no TARGET_REPO: the first project.
  const first = require("./projects").list().find((p) => p.path);
  return first ? { path: first.path, project: first.id, name: first.name } : { path: "", project: "", name: "" };
}

async function github() {
  if (env.demo) return { login: "alex-rivera" };
  const login = await sh("gh", ["api", "user", "--jq", ".login"]);
  return login ? { login } : {};
}

async function slack() {
  if (env.demo) return { userId: "U0DEMO", name: "Alex Rivera", team: "Acme" };
  if (!env.slackUserToken) return {};
  try {
    const s = require("./slack");
    const me = await s.status();
    const u = me.userId ? await fetch(`https://slack.com/api/users.info?user=${encodeURIComponent(me.userId)}`, { headers: { Authorization: `Bearer ${env.slackUserToken}` }, signal: AbortSignal.timeout(10000) }).then((r) => r.json()) : {};
    const p = (u.user && u.user.profile) || {};
    return { userId: me.userId || "", name: p.real_name || p.display_name || me.user || "", team: me.team || "" };
  } catch {
    return {};
  }
}

async function linear() {
  if (env.demo) return { name: "Alex Rivera", workspace: "acme", teams: [{ key: "WEB", name: "Web" }, { key: "MOB", name: "Mobile" }] };
  if (!env.linearApiKey) return {};
  try {
    const res = await fetch("https://api.linear.app/graphql", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: env.linearApiKey },
      body: JSON.stringify({ query: "{ viewer { name organization { urlKey name } teams(first: 50) { nodes { key name } } } }" }),
      signal: AbortSignal.timeout(15000),
    });
    const v = ((await res.json()).data || {}).viewer;
    if (!v) return {};
    return { name: v.name, workspace: v.organization.urlKey, org: v.organization.name, teams: v.teams.nodes.map((t) => ({ key: t.key, name: t.name })) };
  } catch {
    return {};
  }
}

async function shellPath() {
  if (env.demo) return "";
  const shell = process.env.SHELL || "/bin/zsh";
  const out = await sh(shell, ["-ilc", 'printf "__P__%s__P__" "$PATH"'], { timeout: 8000, extraPath: DEFAULT_EXTRA });
  return (out.match(/__P__(.*)__P__/) || [])[1] || "";
}

async function repoFacts(config) {
  const r = pipelineRepo(config);
  if (!r.path || !fs.existsSync(r.path)) return { ...r, github: "" };
  const remote = env.demo ? "git@github.com:acme/storefront.git" : await sh("git", ["-C", r.path, "remote", "get-url", "origin"]);
  return { ...r, github: slugOf(remote) };
}

let inflight = null;

/** Work everything out again and cache it. Never throws: a missing piece is just left out. */
function resolve() {
  if (inflight) return inflight;
  const config = require("./store").readConfig();
  inflight = Promise.all([github(), slack(), linear(), shellPath(), repoFacts(config)])
    .then(([gh, sl, li, p, repo]) => {
      const prev = cached();
      const next = {
        github: gh.login ? gh : prev.github || {},
        slack: sl.userId ? sl : env.slackUserToken ? prev.slack || {} : {},
        linear: li.workspace ? li : env.linearApiKey ? prev.linear || {} : {},
        path: p || prev.path || "",
        repo,
        at: Date.now(),
      };
      fs.mkdirSync(path.dirname(FILE), { recursive: true });
      fs.writeFileSync(FILE, JSON.stringify(next, null, 2));
      apply(env, next, config);
      return next;
    })
    .finally(() => {
      inflight = null;
    });
  return inflight;
}

/**
 * Fill env from the facts wherever .env left the key empty. `env.raw` keeps
 * what .env said, so this can run again after a new resolve.
 */
function apply(e = env, facts = cached(), config = safeConfig()) {
  const raw = e.raw;
  const set = (k, v) => {
    if (v) e[k] = v;
  };
  set("githubLogin", raw.githubLogin || (facts.github || {}).login);
  set("branchPrefix", raw.branchPrefix || e.githubLogin || "task");
  set("slackUserId", raw.slackUserId || (facts.slack || {}).userId);
  set("slackUserName", raw.slackUserName || (facts.slack || {}).name || "the user");
  const li = facts.linear || {};
  set("linearWorkspace", raw.linearWorkspace || li.workspace);
  const pick = (config.harness || {}).linearTeam;
  const team = (li.teams || []).find((t) => t.key === pick) || (raw.linearTeam ? null : (li.teams || [])[0]);
  set("linearTeam", raw.linearTeam || (team && team.name));
  set("linearIssuePrefix", raw.linearIssuePrefix || (team && team.key) || "ISSUE");
  const repo = pipelineRepo(config);
  set("targetRepo", repo.path);
  set("githubRepo", raw.githubRepo || ((facts.repo || {}).path === repo.path ? (facts.repo || {}).github : ""));
  set("productName", raw.productName || repo.name || "the product");
  const model = (config.harness || {}).pipelineModel;
  set("pipelineModel", model || raw.pipelineModel || "opus");
  // launchd's PATH plus your shell's: where claude, gh, uvx and friends live.
  if (!raw.extraPath) {
    const dirs = [...DEFAULT_EXTRA.split(":"), ...String(facts.path || "").split(":")].filter((d) => d && d !== "." && path.isAbsolute(d));
    set("extraPath", [...new Set(dirs)].join(":"));
  }
  return e;
}

function safeConfig() {
  try {
    return require("./store").readConfig();
  } catch {
    return {};
  }
}

/** For Settings: the facts, and what each overridable key resolves to right now. */
function summary() {
  const f = cached();
  return {
    github: f.github || {},
    slack: f.slack || {},
    linear: f.linear || {},
    repo: f.repo || {},
    at: f.at || 0,
    derived: {
      GITHUB_LOGIN: env.githubLogin,
      GITHUB_REPO: env.githubRepo,
      BRANCH_PREFIX: env.branchPrefix,
      SLACK_USER_ID: env.slackUserId,
      SLACK_USER_NAME: env.slackUserName,
      LINEAR_WORKSPACE: env.linearWorkspace,
      LINEAR_TEAM: env.linearTeam,
      LINEAR_ISSUE_PREFIX: env.linearIssuePrefix,
      TARGET_REPO: env.targetRepo,
      WORKTREE_ROOT: env.worktreeRoot || (env.targetRepo ? `${env.targetRepo}-worktrees` : ""),
      PRODUCT_NAME: env.productName,
      PIPELINE_MODEL: env.pipelineModel,
      EXTRA_PATH: env.extraPath,
      DEFAULT_DIR: require("./projects").rootDir(),
    },
  };
}

module.exports = { resolve, apply, cached, summary, slugOf, FILE };
