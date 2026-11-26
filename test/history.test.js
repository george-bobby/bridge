/**
 * server/history.js: each agent's own chat history (Claude Code, Codex,
 * Cursor, Devin) listed and turned into Bridge transcripts. Fixtures live in
 * a scratch home; nothing reads the real ~/.claude and friends.
 */

const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const os = require("os");
const path = require("path");

const home = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "bridge-history-")));
process.env.BRIDGE_HISTORY_HOME = home;
const history = require("../server/history");
const { writeFixtures, sqlite } = require("./fixtures");

test.before(() => writeFixtures(home));
test.after(() => fs.rmSync(home, { recursive: true, force: true }));

test("lists every agent's chats newest first, with what you asked and where", () => {
  const { chats, counts } = history.list({});
  assert.strictEqual(counts.claude, 1, "the sidechain-only file and the empty one aren't chats");
  assert.strictEqual(counts.codex, 1);
  const claude = chats.find((c) => c.agent === "claude");
  assert.strictEqual(claude.title, "Fix the CSV export", "a custom title wins over the first prompt");
  assert.strictEqual(claude.prompt, "/fetch the CSV export drops its last row", "slash commands read as you typed them");
  assert.strictEqual(claude.cwd, path.join(home, "repo"));
  const codex = chats.find((c) => c.agent === "codex");
  assert.strictEqual(codex.prompt, "Why is the export slow?", "injected context isn't the prompt");
  if (sqlite) {
    assert.strictEqual(counts.cursor, 1);
    assert.strictEqual(counts.devin, 1);
    assert.strictEqual(chats.find((c) => c.agent === "cursor").title, "Run the tests");
    assert.strictEqual(chats.find((c) => c.agent === "devin").title, "Upgrade the SDK");
  }
  for (let i = 1; i < chats.length; i++) assert.ok(chats[i - 1].updatedAt >= chats[i].updatedAt, "newest first");
  assert.strictEqual(history.list({ q: "csv export" }).chats.length, 1, "search matches every word");
});

test("Claude Code: turns, thinking, tools with their results; reminders and sidechains left out", () => {
  const t = history.read("claude", "11111111-1111-4111-8111-111111111111");
  assert.strictEqual(t.cwd, path.join(home, "repo"));
  assert.deepStrictEqual(t.messages.map((m) => m.role), ["user", "assistant", "user", "assistant"]);
  const [, a1] = t.messages;
  assert.deepStrictEqual(a1.steps.map((s) => s.kind), ["thinking", "tool", "text"]);
  assert.strictEqual(a1.steps[1].name, "Bash");
  assert.strictEqual(a1.steps[1].detail, "wc -l export.csv");
  assert.strictEqual(a1.steps[1].result, "41 export.csv");
  assert.strictEqual(a1.steps[1].resultLines, 1);
  assert.strictEqual(a1.agent, "claude");
  assert.strictEqual(a1.model, "claude-opus-5-5");
  assert.strictEqual(a1.state, "done");
  assert.ok(!JSON.stringify(t.messages).includes("system-reminder"));
  assert.ok(!JSON.stringify(t.messages).includes("subagent says"));
});

test("Codex: messages, function calls and their output", () => {
  const t = history.read("codex", "22222222-2222-4222-8222-222222222222");
  assert.deepStrictEqual(t.messages.map((m) => m.role), ["user", "assistant"]);
  const tool = t.messages[1].steps.find((s) => s.kind === "tool");
  assert.strictEqual(tool.name, "shell");
  assert.strictEqual(tool.detail, "ls src");
  assert.strictEqual(tool.result, "export.js");
  assert.strictEqual(t.messages[1].steps.at(-1).text, "The export reads the file twice.");
  assert.strictEqual(t.model, "gpt-6");
});

test("Cursor and Devin: read out of their SQLite stores", { skip: !sqlite && "no node:sqlite or sqlite3 here" }, () => {
  const c = history.read("cursor", "33333333-3333-4333-8333-333333333333");
  assert.deepStrictEqual(c.messages.map((m) => m.role), ["user", "assistant"]);
  assert.strictEqual(c.messages[0].text, "Run the tests", "the <user_query> wrapper comes off");
  const tool = c.messages[1].steps.find((s) => s.kind === "tool");
  assert.deepStrictEqual([tool.name, tool.detail, tool.result], ["Shell", "npm test", "12 passing"]);
  const d = history.read("devin", "quiet-harbor");
  assert.deepStrictEqual(d.messages.map((m) => m.role), ["user", "assistant"]);
  assert.strictEqual(d.messages[0].text, "Upgrade the SDK");
  const dt = d.messages[1].steps.find((s) => s.kind === "tool");
  assert.deepStrictEqual([dt.name, dt.result, dt.ok], ["exec", "added 1 package", true]);
  assert.ok(!JSON.stringify(d.messages).includes("dead branch"), "only the session's main chain");
});

test("a chat Bridge already has is marked with its run", () => {
  const runs = [{ runId: "t-1", sessionId: "11111111-1111-4111-8111-111111111111", agentSessions: { codex: "22222222-2222-4222-8222-222222222222" } }];
  const { chats } = history.list({ runs });
  assert.strictEqual(chats.find((c) => c.agent === "claude").runId, "t-1");
  assert.strictEqual(chats.find((c) => c.agent === "codex").runId, "t-1");
});

test("cleanPrompt and isNoise", () => {
  assert.strictEqual(history.cleanPrompt("<timestamp>x</timestamp>\n<user_query>\nhi\n</user_query>"), "hi");
  assert.ok(history.isNoise("<environment_context>cwd</environment_context>"));
  assert.ok(!history.isNoise("fix the bug"));
});
