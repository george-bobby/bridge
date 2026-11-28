// The shared memory: proposals, approval, the index kept in step, and the
// pointers written into each agent's home (a scratch one here).
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");

const tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "bridge-memory-")));
const HOME = path.join(tmp, "home");
process.env.BRIDGE_MCP_HOME = HOME;
process.env.BRIDGE_DATA_DIR = path.join(tmp, "data");
process.env.BRIDGE_ENV_FILE = path.join(tmp, "none.env");
const repo = path.join(tmp, "repo");
fs.mkdirSync(repo, { recursive: true });
execFileSync("git", ["init", "-q"], { cwd: repo });
const projects = require("../server/projects");
const memory = require("../server/memory");
const id = projects.add({ path: repo, name: "repo" }).id;
test.after(() => fs.rmSync(tmp, { recursive: true, force: true }));

const topic = (name, desc, body) => `---\nname: ${name}\ndescription: "${desc}"\nmetadata:\n  type: feedback\n---\n${body}\n`;
const propose = (name, text) => {
  const dir = path.join(memory.dirOf(id), ".proposed");
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, name), text);
};

test("an index entry stays one line, whatever the title, hook or section hold", () => {
  const text = memory.addToIndex("# Code\n", { name: "a.md", title: "Two\nlines [x]", hook: "a\n# Injected", section: "Code\n" });
  assert.equal(text, "# Code\n- [Two lines x](a.md) — a # Injected\n");
});

test("a proposal is used only once approved, and approving lists it in the index", () => {
  propose("feedback-tabs.md", topic("feedback-tabs", "Indent with tabs", "Tabs, always."));
  let l = memory.list(id);
  assert.deepEqual(l.files.map((f) => f.name), []);
  assert.deepEqual(l.proposals.map((p) => [p.name, p.updates]), [["feedback-tabs.md", false]]);
  assert.doesNotMatch(memory.block(id), /Indent with tabs/);

  memory.approve(id, "feedback-tabs.md", topic("feedback-tabs", "Indent with tabs", "Tabs, edited."));
  l = memory.list(id);
  assert.deepEqual(l.files.map((f) => f.name), ["MEMORY.md", "feedback-tabs.md"]);
  assert.equal(l.proposals.length, 0);
  assert.match(memory.read(id, "feedback-tabs.md").text, /Tabs, edited/);
  assert.match(memory.block(id), /\[feedback-tabs\]\(feedback-tabs\.md\) — Indent with tabs/);
  assert.match(memory.block(id), /\.proposed/);
});

test("a proposal with an existing name amends that memory without a second index line", () => {
  propose("feedback-tabs.md", topic("feedback-tabs", "Indent with tabs", "Tabs, except YAML."));
  assert.equal(memory.list(id).proposals[0].updates, true);
  memory.approve(id, "feedback-tabs.md");
  assert.match(memory.read(id, "feedback-tabs.md").text, /except YAML/);
  assert.equal(memory.read(id, "MEMORY.md").text.match(/feedback-tabs\.md/g).length, 1);
});

test("a proposal without frontmatter is refused; discarding drops it", () => {
  propose("loose.md", "just a thought\n");
  assert.throws(() => memory.approve(id, "loose.md"), /description/);
  memory.discard(id, "loose.md");
  assert.equal(memory.list(id).proposals.length, 0);
});

test("deleting a memory removes its index line; names can't leave the folder", () => {
  memory.remove(id, "feedback-tabs.md");
  assert.deepEqual(memory.list(id).files.map((f) => f.name), ["MEMORY.md"]);
  assert.doesNotMatch(memory.read(id, "MEMORY.md").text, /feedback-tabs/);
  assert.throws(() => memory.read(id, "../../x.md"), /named like/);
  assert.throws(() => memory.list("nope"), /no such project/);
});

test("connect points every agent at the shared memory and keeps what was already there", () => {
  fs.mkdirSync(path.join(HOME, ".codex"), { recursive: true });
  fs.writeFileSync(path.join(HOME, ".codex", "AGENTS.md"), "# Mine\n\nKeep this.\n");
  fs.mkdirSync(path.join(HOME, ".claude"), { recursive: true });
  fs.writeFileSync(path.join(HOME, ".claude", "settings.json"), JSON.stringify({ theme: "dark" }));
  memory.connect();
  memory.connect();
  const codex = fs.readFileSync(path.join(HOME, ".codex", "AGENTS.md"), "utf8");
  assert.match(codex, /^# Mine\n\nKeep this\.\n\n<!-- bridge:memory -->/);
  assert.equal(codex.match(/bridge:memory -->/g).length, 2, "one block, however often it runs");
  assert.ok(codex.includes(path.join(memory.ROOT, id, "MEMORY.md")));
  assert.match(fs.readFileSync(path.join(HOME, ".claude", "CLAUDE.md"), "utf8"), /Shared memory/);
  assert.match(fs.readFileSync(path.join(HOME, ".cursor", "rules", "bridge-memory.mdc"), "utf8"), /alwaysApply: true/);
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(HOME, ".claude", "settings.json"), "utf8")), { theme: "dark", autoMemoryEnabled: false });
});

test("a server on a scratch data dir never writes the pointers into your real home", () => {
  const home = path.join(tmp, "real-home");
  fs.mkdirSync(home, { recursive: true });
  const env = { ...process.env, HOME: home, BRIDGE_DATA_DIR: path.join(tmp, "blank-data") };
  for (const k of ["BRIDGE_MCP_HOME", "CLAUDE_CONFIG_DIR", "CODEX_HOME"]) delete env[k];
  const run = (extra) => execFileSync(process.execPath, ["-e", `require(${JSON.stringify(path.join(__dirname, "..", "server", "memory"))}).connect()`], { env: { ...env, ...extra } });
  run({});
  run({ BRIDGE_DEMO: "1" });
  assert.deepEqual(fs.readdirSync(home), []);
});
