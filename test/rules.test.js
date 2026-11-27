/**
 * Common rules (server/rules.js): the shipped default, an edited copy that
 * wins until reset, and the block every worker and orchestrator prompt ends with.
 */

const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const os = require("os");
const path = require("path");

const tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "bridge-rules-")));
process.env.BRIDGE_DATA_DIR = path.join(tmp, "data");
process.env.BRIDGE_ENV_FILE = path.join(tmp, "none.env");
process.env.SLACK_USER_NAME = "Ada";

const rules = require("../server/rules");
const jobs = require("../server/jobs");
const store = require("../server/store");

test.after(() => fs.rmSync(tmp, { recursive: true, force: true }));

const prompts = () => {
  const config = store.readConfig();
  return [jobs.systemPrompt({ runId: "t-rules", kind: "task" }, config), jobs.systemPrompt({ runId: "orchestrator", kind: "orchestrator" }, config)];
};

test("the default rules ship in every prompt, with the user's name filled in", () => {
  const r = rules.get();
  assert.equal(r.custom, false);
  assert.equal(r.text, fs.readFileSync(rules.DEFAULT, "utf8").trim());
  assert.match(r.text, /origin\/main/);
  for (const p of prompts()) {
    assert.match(p, /## Common rules\n\nThese hold in every repo/);
    assert.match(p, /unless Ada says to use the current one/);
    assert.doesNotMatch(p, /\{\{USER\}\}/);
  }
});

test("an edited copy wins; saving the default or resetting drops it; blank turns the block off", () => {
  rules.save("1. Always rebase from main.\r\n");
  assert.equal(fs.readFileSync(rules.FILE, "utf8"), "1. Always rebase from main.\n");
  assert.deepEqual([rules.get().custom, rules.get().text], [true, "1. Always rebase from main."]);
  for (const p of prompts()) {
    assert.match(p, /## Common rules\n\n1\. Always rebase from main\./);
    assert.doesNotMatch(p, /These hold in every repo/);
  }

  rules.save(rules.get().default);
  assert.equal(fs.existsSync(rules.FILE), false);

  rules.save("   ");
  assert.equal(rules.get().custom, true);
  for (const p of prompts()) assert.doesNotMatch(p, /## Common rules/);

  assert.equal(rules.reset().custom, false);
  assert.throws(() => rules.save("x".repeat(20001)), /limited/);
});
