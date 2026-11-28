const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");

// A fake gh, run under this node (a #! line can land on a version-manager shim).
const tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "bridge-accounts-")));
const GH = path.join(tmp, "gh");
fs.writeFileSync(GH, `#!/bin/sh\nexec "${process.execPath}" "${path.join(__dirname, "gh.js")}" "$@"\n`, { mode: 0o755 });
process.env.BRIDGE_GH = GH;
process.env.BRIDGE_DATA_DIR = path.join(tmp, "data");
process.env.BRIDGE_ENV_FILE = path.join(tmp, "none.env");

const accounts = require("../server/accounts");

test.after(() => fs.rmSync(tmp, { recursive: true, force: true }));

test("lists gh's accounts and builds a commit identity (noreply when the email is private)", async () => {
  assert.deepEqual(await accounts.list({ refresh: true }), [
    { host: "github.com", login: "alex", active: true },
    { host: "github.com", login: "alex-work", active: false },
  ]);
  assert.deepEqual(await accounts.profile("alex"), { login: "alex", host: "github.com", name: "Alex Rivera", email: "alex@example.com" });
  assert.deepEqual(await accounts.profile("alex-work"), { login: "alex-work", host: "github.com", name: "alex-work", email: "42+alex-work@users.noreply.github.com" });
  await assert.rejects(accounts.profile("stranger"), /isn't logged in to stranger/);
  assert.equal(accounts.token("alex-work"), "tok-work");
  assert.equal(accounts.token("stranger"), "");
});

test("a session's env commits as the account and hands git its token, without the active account", async () => {
  const e = accounts.sessionEnv(await accounts.profile("alex-work"));
  assert.equal(e.GH_TOKEN, "tok-work");
  assert.deepEqual(accounts.sessionEnv(null), {});

  const repo = path.join(tmp, "repo");
  fs.mkdirSync(repo);
  const git = (args, extra = {}) => execFileSync("git", args, { cwd: repo, encoding: "utf8", env: { ...process.env, ...extra } }).trim();
  git(["init", "-q"]);
  git(["config", "user.name", "Global Me"]);
  git(["config", "user.email", "me@example.com"]);
  git(["config", "credential.https://github.com.helper", "store --file=/nonexistent"]);
  git(["commit", "-q", "--allow-empty", "--no-gpg-sign", "-m", "x"], e);
  assert.equal(git(["log", "-1", "--format=%an <%ae> / %cn <%ce>"]), "alex-work <42+alex-work@users.noreply.github.com> / alex-work <42+alex-work@users.noreply.github.com>");

  // git asks the fake gh (not the repo's own helper), which answers with GH_TOKEN's account.
  const cred = execFileSync("git", ["credential", "fill"], { cwd: repo, input: "protocol=https\nhost=github.com\n\n", encoding: "utf8", env: { ...process.env, ...e, GIT_TERMINAL_PROMPT: "0" } });
  assert.match(cred, /username=alex-work/);
  assert.match(cred, /password=tok-work/);
});
