// The data layer's file surfaces: the git arguments a new worktree is made with.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");

const tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "bridge-store-")));
process.env.HOME = path.join(tmp, "home");
process.env.BRIDGE_DATA_DIR = path.join(tmp, "data");
process.env.BRIDGE_ENV_FILE = path.join(tmp, "none.env");
const tasks = require("../server/tasks");
test.after(() => fs.rmSync(tmp, { recursive: true, force: true }));

test("a base branch can't smuggle a flag into git fetch", async () => {
  const repo = path.join(tmp, "git");
  fs.mkdirSync(repo);
  const git = (...a) => execFileSync("git", a, { cwd: repo, stdio: "ignore" });
  git("init", "-q");
  git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "x");
  git("remote", "add", "origin", repo);
  await assert.rejects(tasks.createWorktree({ repo, branch: "b1", from: "origin/--upload-pack=touch" }), /bad base branch/);
});
