// The data layer's file surfaces: memory index edits and retirement,
// proposal files, and the git arguments a new worktree is made with.
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
const memory = require("../server/memory");
const proposals = require("../server/proposals");
const tasks = require("../server/tasks");
test.after(() => fs.rmSync(tmp, { recursive: true, force: true }));

test("an index entry stays one line, whatever the title, hook or section hold", () => {
  const text = memory.addToIndex("# Code\n", { name: "a.md", title: "Two\nlines [x]", hook: "a\n# Injected", section: "Code\n" });
  assert.equal(text, "# Code\n- [Two lines x](a.md) — a # Injected\n");
});

test("retiring a memory never overwrites an earlier retired copy", () => {
  const repo = path.join(tmp, "repo");
  const dir = memory.dirFor(repo);
  fs.mkdirSync(dir, { recursive: true });
  const body = (n) => `---\nname: x\ndescription: "d"\nmetadata:\n  type: project\n---\n${n}\n`;
  memory.create(repo, "x.md", body("first"));
  memory.archive(repo, "x.md");
  memory.create(repo, "x.md", body("second"));
  memory.archive(repo, "x.md");
  const kept = memory.archived(repo).map((n) => fs.readFileSync(path.join(dir, ".archive", n), "utf8"));
  assert.equal(kept.length, 2);
  assert.ok(kept.some((t) => t.includes("first")) && kept.some((t) => t.includes("second")));
});

test("a proposal is written back to its own file, not wherever its runId field points", () => {
  proposals.propose("run-1", { verdict: "create", territory: "t", text: "x" });
  const f = path.join(proposals.DIR, "run-1.json");
  fs.writeFileSync(f, JSON.stringify({ ...JSON.parse(fs.readFileSync(f, "utf8")), runId: "../../escaped" }));
  proposals.setStatus("run-1", "discarded");
  assert.equal(JSON.parse(fs.readFileSync(f, "utf8")).status, "discarded");
  assert.equal(fs.existsSync(path.join(tmp, "data", "escaped.json")), false);
  assert.deepEqual(proposals.all().map((p) => p.runId), ["run-1"]);
});

test("a base branch can't smuggle a flag into git fetch", async () => {
  const repo = path.join(tmp, "git");
  fs.mkdirSync(repo);
  const git = (...a) => execFileSync("git", a, { cwd: repo, stdio: "ignore" });
  git("init", "-q");
  git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "x");
  git("remote", "add", "origin", repo);
  await assert.rejects(tasks.createWorktree({ repo, branch: "b1", from: "origin/--upload-pack=touch" }), /bad base branch/);
});
