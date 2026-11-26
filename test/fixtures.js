/**
 * A scratch home holding one chat per agent, in each agent's own on-disk
 * format (test/history.test.js, the import test in test/workspace.test.js).
 */

const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const CLAUDE_ID = "11111111-1111-4111-8111-111111111111";
const CODEX_ID = "22222222-2222-4222-8222-222222222222";
const CURSOR_ID = "33333333-3333-4333-8333-333333333333";
const DEVIN_ID = "quiet-harbor";

/** Run SQL against a new database: node:sqlite when there is one, else the CLI. */
function sqliteExec(db, sql) {
  const emit = process.emitWarning;
  process.emitWarning = () => {};
  let m = null;
  try {
    m = require("node:sqlite");
  } catch {}
  process.emitWarning = emit;
  if (m && m.DatabaseSync) {
    const conn = new m.DatabaseSync(db);
    conn.exec(sql);
    conn.close();
    return true;
  }
  try {
    execFileSync("sqlite3", [db], { input: sql, stdio: ["pipe", "ignore", "ignore"] });
    return true;
  } catch {
    return false;
  }
}

const sqlite = (() => {
  const probe = path.join(require("os").tmpdir(), `bridge-sqlite-probe-${process.pid}.db`);
  const ok = sqliteExec(probe, "create table t (x int);");
  fs.rmSync(probe, { force: true });
  return ok;
})();

const jsonl = (rows) => rows.map((r) => JSON.stringify(r)).join("\n") + "\n";
const q = (s) => `'${String(s).replace(/'/g, "''")}'`;
const hex = (s) => Buffer.from(s).toString("hex");

function writeFixtures(home) {
  const repo = path.join(home, "repo");
  fs.mkdirSync(repo, { recursive: true });

  // Claude Code: a session with a slash command, a reminder, a sidechain
  // (a subagent's line) and a custom title; plus a file with no prompt at all.
  const cdir = path.join(home, ".claude", "projects", repo.replace(/[/.]/g, "-"));
  fs.mkdirSync(cdir, { recursive: true });
  const ts = (min) => new Date(Date.UTC(2026, 10, 20, 10, min)).toISOString();
  fs.writeFileSync(
    path.join(cdir, `${CLAUDE_ID}.jsonl`),
    jsonl([
      { type: "session-owner", sessionId: CLAUDE_ID },
      { type: "user", cwd: repo, gitBranch: "main", timestamp: ts(0), message: { role: "user", content: "<command-message>fetch</command-message>\n<command-name>/fetch</command-name>\n<command-args>the CSV export drops its last row</command-args>" } },
      { type: "user", isMeta: true, cwd: repo, timestamp: ts(0), message: { role: "user", content: [{ type: "text", text: "Base directory for this skill: /x" }] } },
      { type: "assistant", cwd: repo, timestamp: ts(1), message: { model: "claude-opus-5-5", role: "assistant", content: [{ type: "thinking", thinking: "Count the rows first." }] } },
      { type: "assistant", cwd: repo, timestamp: ts(1), message: { model: "claude-opus-5-5", role: "assistant", content: [{ type: "tool_use", id: "tu1", name: "Bash", input: { command: "wc -l export.csv" } }] } },
      { type: "user", cwd: repo, timestamp: ts(2), message: { role: "user", content: [{ type: "tool_result", tool_use_id: "tu1", content: "41 export.csv" }] } },
      { type: "assistant", isSidechain: true, cwd: repo, timestamp: ts(2), message: { role: "assistant", content: [{ type: "text", text: "subagent says hi" }] } },
      { type: "assistant", cwd: repo, timestamp: ts(3), message: { model: "claude-opus-5-5", role: "assistant", content: [{ type: "text", text: "The last page is dropped by an off-by-one." }] } },
      { type: "user", cwd: repo, timestamp: ts(4), message: { role: "user", content: [{ type: "text", text: "<system-reminder>ignore me</system-reminder>" }] } },
      { type: "user", cwd: repo, timestamp: ts(5), message: { role: "user", content: "Fix it" } },
      { type: "assistant", cwd: repo, timestamp: ts(6), message: { model: "claude-opus-5-5", role: "assistant", content: [{ type: "text", text: "Fixed in paginate.js." }] } },
      { type: "custom-title", customTitle: "Fix the CSV export", sessionId: CLAUDE_ID },
    ]),
  );
  fs.writeFileSync(path.join(cdir, "44444444-4444-4444-8444-444444444444.jsonl"), jsonl([{ type: "summary", summary: "nothing" }]));
  fs.utimesSync(path.join(cdir, `${CLAUDE_ID}.jsonl`), new Date("2026-11-20T10:06:00Z"), new Date("2026-11-20T10:06:00Z"));

  // Codex: a rollout with injected context, a function call and its output.
  const xdir = path.join(home, ".codex", "sessions", "2026", "11", "19");
  fs.mkdirSync(xdir, { recursive: true });
  const xf = path.join(xdir, `rollout-2026-11-19T09-00-00-${CODEX_ID}.jsonl`);
  fs.writeFileSync(
    xf,
    jsonl([
      { timestamp: "2026-11-19T09:00:00Z", type: "session_meta", payload: { id: CODEX_ID, cwd: repo, timestamp: "2026-11-19T09:00:00Z" } },
      { timestamp: "2026-11-19T09:00:00Z", type: "turn_context", payload: { model: "gpt-6", cwd: repo } },
      { timestamp: "2026-11-19T09:00:01Z", type: "response_item", payload: { type: "message", role: "user", content: [{ type: "input_text", text: "<environment_context>cwd</environment_context>" }] } },
      { timestamp: "2026-11-19T09:00:02Z", type: "response_item", payload: { type: "message", role: "user", content: [{ type: "input_text", text: "Why is the export slow?" }] } },
      { timestamp: "2026-11-19T09:00:03Z", type: "response_item", payload: { type: "function_call", name: "shell", call_id: "c1", arguments: JSON.stringify({ command: ["ls", "src"] }) } },
      { timestamp: "2026-11-19T09:00:04Z", type: "response_item", payload: { type: "function_call_output", call_id: "c1", output: "export.js" } },
      { timestamp: "2026-11-19T09:00:05Z", type: "response_item", payload: { type: "message", role: "assistant", content: [{ type: "output_text", text: "The export reads the file twice." }] } },
    ]),
  );
  fs.utimesSync(xf, new Date("2026-11-19T09:00:05Z"), new Date("2026-11-19T09:00:05Z"));

  if (!sqlite) return { repo };

  // Cursor: a store.db of blobs whose root lists the messages in order.
  const kdir = path.join(home, ".cursor", "chats", "0123456789abcdef0123456789abcdef", CURSOR_ID);
  fs.mkdirSync(kdir, { recursive: true });
  fs.writeFileSync(path.join(kdir, "meta.json"), JSON.stringify({ schemaVersion: 1, createdAtMs: Date.parse("2026-11-18T08:00:00Z"), updatedAtMs: Date.parse("2026-11-18T08:05:00Z"), hasConversation: true, cwd: repo }));
  const msgs = [
    { role: "system", content: "You are an AI" },
    { role: "user", content: [{ type: "text", text: "<timestamp>Tuesday</timestamp>\n<user_query>\nRun the tests\n</user_query>" }] },
    { role: "assistant", content: [{ type: "text", text: "Running them." }, { type: "tool-call", toolCallId: "k1", toolName: "Shell", args: { command: "npm test" } }] },
    { role: "tool", content: [{ type: "tool-result", toolCallId: "k1", result: "12 passing" }] },
  ];
  const ids = msgs.map((_, i) => String(i + 1).repeat(64).slice(0, 64));
  const rootId = "f".repeat(64);
  const root = Buffer.concat(ids.map((id) => Buffer.concat([Buffer.from([0x0a, 0x20]), Buffer.from(id, "hex")])));
  const meta = { agentId: CURSOR_ID, latestRootBlobId: rootId, name: "New Agent", createdAt: Date.parse("2026-11-18T08:00:00Z") };
  sqliteExec(
    path.join(kdir, "store.db"),
    [
      "create table blobs (id text primary key, data blob);",
      "create table meta (key text primary key, value text);",
      `insert into meta values ('0', ${q(hex(JSON.stringify(meta)))});`,
      `insert into blobs values (${q(rootId)}, x'${root.toString("hex")}');`,
      ...msgs.map((m, i) => `insert into blobs values (${q(ids[i])}, x'${hex(JSON.stringify(m))}');`),
    ].join("\n"),
  );

  // Devin: sessions.db with a forked tree; only the main chain counts.
  const ddir = path.join(home, ".local", "share", "devin", "cli");
  fs.mkdirSync(ddir, { recursive: true });
  const node = (id, parent, m) => `insert into message_nodes (session_id, node_id, parent_node_id, chat_message, created_at) values (${q(DEVIN_ID)}, ${id}, ${parent == null ? "null" : parent}, ${q(JSON.stringify(m))}, 1795400000);`;
  sqliteExec(
    path.join(ddir, "sessions.db"),
    [
      "create table sessions (id text primary key, working_directory text, backend_type text, model text, agent_mode text, created_at integer, last_activity_at integer, title text, main_chain_id integer, hidden integer default 0);",
      "create table prompt_history (id integer primary key autoincrement, content text, timestamp integer, session_id text, is_shell integer default 0);",
      "create table message_nodes (row_id integer primary key autoincrement, session_id text, node_id integer, parent_node_id integer, chat_message text, created_at integer);",
      `insert into sessions values (${q(DEVIN_ID)}, ${q(repo)}, 'local', 'opus', 'code', 1795300000, 1795400000, 'Upgrade the SDK', 4, 0);`,
      `insert into prompt_history (content, timestamp, session_id) values ('Upgrade the SDK', 1795300000, ${q(DEVIN_ID)});`,
      node(0, null, { role: "system", content: "You are Devin" }),
      node(1, 0, { role: "user", content: "Upgrade the SDK", metadata: { is_user_input: true } }),
      node(2, 1, { role: "assistant", content: "", tool_calls: [{ id: "d1", name: "exec", arguments: { command: "npm i sdk@5" } }] }),
      node(3, 1, { role: "assistant", content: "a dead branch" }),
      node(4, 5, { role: "assistant", content: "Upgraded; the tests pass." }),
      node(5, 2, { role: "tool", content: "added 1 package", tool_call_id: "d1" }),
    ].join("\n"),
  );
  return { repo };
}

module.exports = { writeFixtures, sqlite, CLAUDE_ID, CODEX_ID, CURSOR_ID, DEVIN_ID };
