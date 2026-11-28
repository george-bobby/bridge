/**
 * The GitHub accounts `gh` is logged in to, so a project can commit and push
 * as one of them (Settings › Projects). Tokens are only ever read into a
 * session's environment (GH_TOKEN); they are never returned or logged, and
 * gh's active account is never switched.
 *
 * `BRIDGE_GH` points at another gh binary (the tests' fake).
 */

const { execFile, execFileSync } = require("child_process");
const os = require("os");

const env = require("./env");

const gh = () => process.env.BRIDGE_GH || "gh";
const shellEnv = (extra = {}) => ({ ...process.env, PATH: `${env.extraPath}:${process.env.PATH || "/usr/bin:/bin"}`, ...extra });

function run(args, extra) {
  return new Promise((resolve) =>
    execFile(gh(), args, { cwd: os.homedir(), timeout: 15000, env: shellEnv(extra) }, (err, out) => resolve(err ? null : String(out || ""))),
  );
}

const DEMO = [
  { host: "github.com", login: "alex-rivera", active: true },
  { host: "github.com", login: "alex-acme", active: false },
];

let memo = { at: 0, list: [] };

/** [{host, login, active}] from `gh auth status --json hosts`, cached a minute. */
async function list({ refresh = false } = {}) {
  if (env.demo) return DEMO;
  if (!refresh && Date.now() - memo.at < 60000) return memo.list;
  const out = await run(["auth", "status", "--json", "hosts"]);
  let hosts = {};
  try {
    hosts = (JSON.parse(out || "{}") || {}).hosts || {};
  } catch {}
  const all = [];
  for (const [host, accounts] of Object.entries(hosts)) {
    for (const a of accounts || []) if (a && a.login && a.state !== "error") all.push({ host, login: a.login, active: !!a.active });
  }
  memo = { at: Date.now(), list: all };
  return all;
}

/** The token gh holds for one account, or "" (sync: read at session spawn, from the keychain). */
function token(login, host = "github.com") {
  if (!login || env.demo) return "";
  try {
    return execFileSync(gh(), ["auth", "token", "--user", login, "--hostname", host], { timeout: 5000, env: shellEnv(), stdio: ["ignore", "pipe", "ignore"] })
      .toString()
      .trim();
  } catch {
    return "";
  }
}

/**
 * What a project stores for an account: login, host and the commit identity
 * (profile name, else the login; public email, else the noreply address).
 * Throws when gh isn't logged in to that account.
 */
async function profile(login, host = "github.com") {
  const known = (await list({ refresh: true })).find((a) => a.login === login && a.host === host);
  if (!known) throw new Error(`gh isn't logged in to ${login} on ${host} (gh auth login)`);
  if (env.demo) return { login, host, name: login, email: `${login}@users.noreply.github.com` };
  const t = token(login, host);
  const out = t ? await run(["api", "user", "--hostname", host], { GH_TOKEN: t, GH_HOST: host }) : null;
  let u = {};
  try {
    u = JSON.parse(out || "{}") || {};
  } catch {}
  const noreply = u.id ? `${u.id}+${login}@users.noreply.${host}` : `${login}@users.noreply.${host}`;
  return { login, host, name: u.name || login, email: u.email || noreply };
}

/**
 * Environment for a session in a project with an account: commits authored
 * and committed as it, gh and https git pushes on its token (git asks gh for
 * credentials, and gh prefers GH_TOKEN). An ssh remote still uses your keys.
 */
function sessionEnv(account) {
  if (!account || !account.login) return {};
  const out = {
    GIT_AUTHOR_NAME: account.name || account.login,
    GIT_AUTHOR_EMAIL: account.email || "",
    GIT_COMMITTER_NAME: account.name || account.login,
    GIT_COMMITTER_EMAIL: account.email || "",
  };
  const t = token(account.login, account.host || "github.com");
  if (t) {
    const host = account.host || "github.com";
    Object.assign(out, {
      GH_TOKEN: t,
      GH_HOST: host,
      GIT_CONFIG_COUNT: "2",
      GIT_CONFIG_KEY_0: `credential.https://${host}.helper`,
      GIT_CONFIG_VALUE_0: "",
      GIT_CONFIG_KEY_1: `credential.https://${host}.helper`,
      GIT_CONFIG_VALUE_1: `!${gh()} auth git-credential`,
    });
  }
  return out;
}

module.exports = { list, token, profile, sessionEnv };
