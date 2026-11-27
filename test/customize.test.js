// Settings › Customize: skills are listed from every agent's folders, edited,
// created and deleted (to the Trash), and nothing outside a skills folder can
// be read or written through it.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");

const tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "bridge-customize-")));
const HOME = path.join(tmp, "home");
process.env.BRIDGE_MCP_HOME = HOME;
process.env.BRIDGE_DATA_DIR = path.join(tmp, "data");
process.env.BRIDGE_ENV_FILE = path.join(tmp, "none.env");
const c = require("../server/customize");

const skill = (dir, name, desc) => {
  fs.mkdirSync(path.join(dir, name), { recursive: true });
  fs.writeFileSync(path.join(dir, name, "SKILL.md"), `---\nname: ${name}\ndescription: ${desc}\n---\n\nBody of ${name}.\n`);
};

const REPO = path.join(tmp, "repo");
fs.mkdirSync(REPO);
execFileSync("git", ["init", "-q", REPO]);
skill(path.join(HOME, ".claude", "skills"), "fetch", "Fetch a ticket");
skill(path.join(HOME, ".agents", "skills"), "shared-one", "Read by several agents");
skill(path.join(HOME, ".codex", "skills"), "triage", "Sort bugs");
skill(path.join(REPO, ".claude", "skills"), "repo-rules", "This repo's rules");
// A skill linked in from elsewhere: deleting it only removes the link.
skill(path.join(tmp, "elsewhere"), "linked", "Lives outside");
fs.symlinkSync(path.join(tmp, "elsewhere", "linked"), path.join(HOME, ".claude", "skills", "linked"));

test("lists every agent's skills; project ones only with a repo", () => {
  const user = c.listSkills().skills;
  assert.deepEqual(user.map((s) => `${s.agent}/${s.scope}/${s.name}`).sort(), ["claude/user/fetch", "claude/user/linked", "codex/user/triage", "shared/user/shared-one"]);
  assert.equal(user.find((s) => s.name === "fetch").description, "Fetch a ticket");
  assert.match(user.find((s) => s.name === "linked").link, /elsewhere\/linked$/);
  const withRepo = c.listSkills(REPO).skills;
  assert.ok(withRepo.some((s) => s.scope === "project" && s.name === "repo-rules"));
});

test("edit, create and delete, all inside the skills folders", () => {
  const fetch = c.listSkills().skills.find((s) => s.name === "fetch");
  assert.match(c.readSkill(fetch.file).text, /Body of fetch/);
  c.writeSkill(fetch.file, "---\nname: fetch\ndescription: Changed\n---\n");
  assert.equal(c.listSkills().skills.find((s) => s.name === "fetch").description, "Changed");

  const made = c.createSkill({ agent: "cursor", scope: "user", name: "Figma to Code", description: "Frames to components" });
  assert.equal(made.dir, path.join(HOME, ".cursor", "skills", "figma-to-code"));
  assert.match(fs.readFileSync(made.file, "utf8"), /^---\nname: figma-to-code\ndescription: Frames to components\n---/);
  assert.throws(() => c.createSkill({ agent: "cursor", scope: "user", name: "figma to code" }), /already exists/);
  assert.throws(() => c.createSkill({ agent: "claude", scope: "project", name: "x" }), /project/);

  const out = c.deleteSkill(made.dir);
  assert.ok(!fs.existsSync(made.dir) && fs.existsSync(out.trashed), "moved to the Trash, recoverable");
  const linked = c.listSkills().skills.find((s) => s.name === "linked");
  assert.equal(c.deleteSkill(linked.dir).link, true);
  assert.ok(fs.existsSync(path.join(tmp, "elsewhere", "linked", "SKILL.md")), "the linked skill itself stays");
});

test("refuses anything outside a skills folder", () => {
  fs.writeFileSync(path.join(tmp, "secret.md"), "x");
  assert.throws(() => c.readSkill(path.join(tmp, "secret.md")), /SKILL\.md/);
  assert.throws(() => c.readSkill(path.join(tmp, "elsewhere", "linked", "SKILL.md")), /not a skill folder/);
  assert.throws(() => c.writeSkill(path.join(HOME, ".claude", "skills", "..", "..", "x", "SKILL.md"), "hi"), /not a skill folder/);
  assert.throws(() => c.deleteSkill(path.join(HOME, ".claude", "skills")), /not a skill folder/);
  assert.throws(() => c.deleteSkill(HOME), /not a skill folder/);
});

test("a plugin id can't pass for a flag", async () => {
  await assert.rejects(c.claudePlugin("install", "--plugin-dir=/tmp"), /bad plugin id/);
});

test("Codex plugins come from config.toml, described by the cached manifest", () => {
  const codex = path.join(HOME, ".codex");
  const cached = path.join(codex, "plugins", "cache", "openai-bundled", "browser", "1.0.0", ".codex-plugin");
  fs.mkdirSync(cached, { recursive: true });
  fs.writeFileSync(path.join(cached, "plugin.json"), JSON.stringify({ name: "browser", version: "1.0.0", interface: { displayName: "Browser", shortDescription: "Drive a browser" } }));
  fs.writeFileSync(
    path.join(codex, "config.toml"),
    ['model = "gpt-5"', "", '[plugins."browser@openai-bundled"]', "enabled = true", "", '[plugins."pdf@openai-primary-runtime"]', "enabled = false", "", "[mcp_servers.x]", 'command = "x"', ""].join("\n"),
  );
  const prev = process.env.CODEX_HOME;
  delete process.env.CODEX_HOME;
  try {
    const out = c.codexPlugins().plugins;
    assert.deepEqual(out.map((p) => [p.id, p.name, p.enabled, p.version]), [
      ["browser@openai-bundled", "Browser", true, "1.0.0"],
      ["pdf@openai-primary-runtime", "pdf", false, ""],
    ]);
    assert.equal(out[0].description, "Drive a browser");
  } finally {
    if (prev != null) process.env.CODEX_HOME = prev;
  }
});

test("Devin's plugin list parses, same-named installs kept apart", () => {
  const out = c.parseDevinPlugins("Installed plugins\n\n  • slack v1.1.0\n  • linear (claude-plugins-official#external_plugins/linear) unversioned\n  • linear (devin-marketplace#plugins/linear) unversioned\n  • old v0.1.0 (blocked)\n");
  assert.deepEqual(out.map((p) => [p.id, p.name, p.version, p.blocked]), [
    ["slack", "slack", "1.1.0", false],
    ["linear@claude-plugins-official#external_plugins/linear", "linear", "", false],
    ["linear@devin-marketplace#plugins/linear", "linear", "", false],
    ["old", "old", "0.1.0", true],
  ]);
});

test("Codex and Devin plugins only take remove, and no flags", async () => {
  await assert.rejects(c.agentPlugin("codex", "remove", "--force"), /bad plugin id/);
  await assert.rejects(c.agentPlugin("devin", "install", "acme/x"), /unknown action/);
  await assert.rejects(c.agentPlugin("cursor", "remove", "x"), /can't be changed/);
});

test.after(() => fs.rmSync(tmp, { recursive: true, force: true }));
