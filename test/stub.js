#!/usr/bin/env node
/**
 * A fake `claude` for the harness tests. Speaks enough of the stream-json
 * protocol for server/jobs.js and does what the brief tells it to, via
 * `stub:` directives, so every watcher outcome can be forced for free:
 *
 *   stub:report=<status>      write report.md with that status, then end the turn
 *   stub:question=<text>      (with report) add an open question ("\n" for its next line)
 *   stub:you=<text>           (with report) add a "For you" item
 *   stub:action=<text>        (with report) add an action request
 *   stub:noreport             end the turn without a report
 *   stub:report-on-nudge      write a ready-for-review report when nudged
 *   stub:edit                 leave an uncommitted file in the worktree (real work to report)
 *   stub:stall=<seconds>      open a Bash call, go silent, then end
 *   stub:limit                end with a usage-limit error
 *   stub:exit                 die without a result
 *   stub:ask                  ask a permission question and wait for the answer
 *   stub:stream=<n>           stream a reply as partial messages: n text deltas,
 *                             a tool call and its result, a second call's text
 *   stub:tasks                run a subagent (its own tool call) and a background
 *                             command, with the task_* events Claude sends
 *   stub:orphan=<seconds>     leave a `sleep` holding stdout open that long
 *                             after the stub itself exits
 *
 * A message written mid-turn steers it, like Claude: during a stall it is read
 * at the stall's end (echoed back with --replay-user-messages, then "Steered:
 * <text>"); otherwise it runs as a further turn once this one's result is out.
 *
 * `/compact` compacts (a compact_boundary event); the initialize handshake
 * answers with a small command and model list; `mcp_status` lists one
 * connected stdio server and one claude.ai connector; `mcp_toggle` and
 * `stop_task` succeed.
 *
 * Follow-up turns: an "[harness] <name> answered" message writes a
 * ready-for-review report; anything else repeats the brief's directives.
 * Every argv and every prompt is appended to $STUB_LOG, so tests can check
 * the flags and what each turn was told.
 */

const fs = require("fs");

if (process.env.STUB_LOG) fs.appendFileSync(process.env.STUB_LOG, JSON.stringify({ argv: process.argv.slice(2), env: { BRIDGE_ROLE: process.env.BRIDGE_ROLE, BRIDGE_TASK_ID: process.env.BRIDGE_TASK_ID, BRIDGE_GUARD: process.env.BRIDGE_GUARD } }) + "\n");

if (process.argv.includes("--version")) {
  process.stdout.write("0.0.0 (stub)\n");
  process.exit(0);
}

const out = (o) => process.stdout.write(JSON.stringify(o) + "\n");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let waitingAnswer = null;
const replay = process.argv.includes("--replay-user-messages");
let steerBox = null; // messages steered into the stall in progress
const echo = (content) => replay && out({ type: "user", isReplay: true, message: { role: "user", content } });

function directives(text) {
  const d = {};
  for (const m of String(text).matchAll(/stub:([a-z-]+)(?:=([^\n]*))?/g)) {
    const v = m[2] === undefined ? true : m[2].trim();
    if (d[m[1]] === undefined) d[m[1]] = v;
    // A brief inlined into the prompt repeats its directives: count each once.
    else if (![].concat(d[m[1]]).includes(v)) d[m[1]] = [].concat(d[m[1]], v);
  }
  return d;
}

function briefText(prompt) {
  const m = /Read (\S+brief\.md)/.exec(prompt);
  if (m) {
    try {
      return fs.readFileSync(m[1], "utf8");
    } catch {}
  }
  const report = process.env.BRIDGE_REPORT;
  if (report) {
    try {
      return fs.readFileSync(report.replace(/report\.md$/, "brief.md"), "utf8");
    } catch {}
  }
  return "";
}

function writeReport(status, d = {}) {
  // A literal "\n" in a question starts its next line (context, options).
  const q = [].concat(d.question || []).filter((x) => x !== true).map((x) => x.replace(/\\n/g, "\n  "));
  const a = [].concat(d.action || []).filter((x) => x !== true);
  const y = [].concat(d.you || []).filter((x) => x !== true);
  const text = `---
status: ${status}
branch: stub-branch
---
## TL;DR
Stub worker finished with ${status}.

## Summary
Did the stub thing.

## Changes
- none

## Verification
- ran nothing (stub)

## Open questions
${q.length ? q.map((x) => `- ${x}`).join("\n") : "None"}

## Action requests
${a.length ? a.map((x) => `- ${x}`).join("\n") : "None"}

## For you
${y.length ? y.map((x) => `- ${x}`).join("\n") : "None"}

## Proposed commit/PR text
stub
`;
  fs.writeFileSync(process.env.BRIDGE_REPORT, text);
}

const say = (text) => out({ type: "assistant", message: { role: "assistant", content: [{ type: "text", text }] } });
const done = (text, extra = {}) => out({ type: "result", subtype: "success", result: text, total_cost_usd: 0, duration_ms: 5, num_turns: 1, usage: {}, ...extra });

async function turn(prompt) {
  out({ type: "system", subtype: "init", session_id: "stub" });
  echo(prompt);
  if (/^\/compact\b/.test(prompt)) {
    out({ type: "system", subtype: "status", status: "compacting" });
    out({ type: "system", subtype: "compact_boundary", compact_metadata: { trigger: "manual", pre_tokens: 42000, post_tokens: 6000 } });
    return done("", { num_turns: 0 });
  }
  if (/^\[harness\] (\S+ answered|\S+ approved|You were interrupted)/.test(prompt)) {
    writeReport("ready-for-review");
    say("Applied the answer.");
    return done("ok");
  }
  const d = directives(/^\[harness\] You changed code/.test(prompt) ? "" : briefText(prompt) + "\n" + prompt);
  if (/^\[harness\] You changed code/.test(prompt)) {
    const b = directives(briefText(prompt));
    if (b["report-on-nudge"]) writeReport("ready-for-review");
    say("Nudged.");
    return done("ok");
  }
  if (d.exit) process.exit(1);
  if (d.orphan) require("child_process").spawn("sleep", [String([].concat(d.orphan)[0])], { stdio: ["ignore", "inherit", "ignore"], detached: true }).unref();
  if (d.limit) {
    say("You've hit your usage limit. Resets at 5pm.");
    return done("You've hit your usage limit", { subtype: "error_during_execution" });
  }
  if (d.stall) {
    out({ type: "stream_event", event: { type: "message_start" } });
    out({ type: "stream_event", event: { type: "content_block_start", index: 0, content_block: { type: "tool_use", id: "tu1", name: "Bash" } } });
    steerBox = [];
    await sleep(Number([].concat(d.stall)[0]) * 1000);
    const steered = steerBox;
    steerBox = null;
    out({ type: "user", message: { role: "user", content: [{ type: "tool_result", tool_use_id: "tu1", content: "ok" }] } });
    for (const t of steered) {
      echo(t);
      say(`Steered: ${t}`);
    }
  }
  if (d.ask) {
    out({ type: "control_request", request_id: "rq1", request: { subtype: "can_use_tool", tool_name: "Bash", input: { command: "git push --force" }, tool_use_id: "tu-ask" } });
    const answer = await new Promise((r) => (waitingAnswer = r));
    say(`answer: ${answer.behavior}`);
  }
  if (d.tasks) await tasks();
  if (d.stream) await stream(Number(d.stream) || 20);
  if (d.edit) fs.writeFileSync("stub-edit.txt", "edited\n");
  if (d.report) writeReport(d.report, d);
  say("Stub turn done.");
  return done("stub done");
}

async function stream(n) {
  const ev = (event) => out({ type: "stream_event", event });
  const text = async (index) => {
    ev({ type: "content_block_start", index, content_block: { type: "text", text: "" } });
    for (let i = 0; i < n; i++) {
      ev({ type: "content_block_delta", index, delta: { type: "text_delta", text: `tok${i} ` } });
      await sleep(10);
    }
    ev({ type: "content_block_stop", index });
  };
  ev({ type: "message_start" });
  await text(0);
  ev({ type: "content_block_start", index: 1, content_block: { type: "tool_use", id: "tu-stream", name: "Bash" } });
  ev({ type: "content_block_delta", index: 1, delta: { type: "input_json_delta", partial_json: '{"command":' } });
  ev({ type: "content_block_delta", index: 1, delta: { type: "input_json_delta", partial_json: '"ls"}' } });
  ev({ type: "content_block_stop", index: 1 });
  ev({ type: "message_delta", usage: { output_tokens: 40, input_tokens: 10, cache_read_input_tokens: 9000, cache_creation_input_tokens: 500 } });
  out({ type: "assistant", message: { role: "assistant", content: [{ type: "tool_use", id: "tu-stream", name: "Bash", input: { command: "ls" } }] } });
  await sleep(30);
  out({ type: "user", message: { role: "user", content: [{ type: "tool_result", tool_use_id: "tu-stream", content: "a.txt\nb.txt" }] } });
  // The delta leaves out cache_creation: message_start's value still counts.
  ev({ type: "message_start", message: { usage: { input_tokens: 5, cache_read_input_tokens: 9500, cache_creation_input_tokens: 200 } } });
  await text(0);
  ev({ type: "message_delta", usage: { output_tokens: 30, input_tokens: 5, cache_read_input_tokens: 9500 } });
}

async function tasks() {
  const asst = (content, parent) => out({ type: "assistant", parent_tool_use_id: parent || null, message: { role: "assistant", content } });
  const res = (id, content, parent) => out({ type: "user", parent_tool_use_id: parent || null, message: { role: "user", content: [{ type: "tool_result", tool_use_id: id, content }] } });
  asst([{ type: "tool_use", id: "tu-agent", name: "Agent", input: { description: "Survey the repo", subagent_type: "Explore", prompt: "List the files." } }]);
  out({ type: "system", subtype: "task_started", task_id: "a1", tool_use_id: "tu-agent", description: "Survey the repo", subagent_type: "Explore", is_backgrounded: false, task_type: "local_agent", prompt: "List the files." });
  asst([{ type: "tool_use", id: "tu-sub", name: "Bash", input: { command: "ls" } }], "tu-agent");
  res("tu-sub", "a.txt\nb.txt", "tu-agent");
  asst([{ type: "text", text: "Two files." }], "tu-agent");
  out({ type: "system", subtype: "task_progress", task_id: "a1", tool_use_id: "tu-agent", description: "Running ls", usage: { total_tokens: 1200, tool_uses: 1, duration_ms: 40 }, last_tool_name: "Bash" });
  out({ type: "system", subtype: "task_notification", task_id: "a1", tool_use_id: "tu-agent", status: "completed", summary: "Two files: a.txt, b.txt", usage: { total_tokens: 1500, tool_uses: 1, duration_ms: 60 } });
  res("tu-agent", "Two files: a.txt, b.txt");
  const dir = require("path").join(require("os").tmpdir(), `stub-${process.pid}`, "tasks");
  fs.mkdirSync(dir, { recursive: true });
  const file = require("path").join(dir, "bg1.output");
  fs.writeFileSync(file, "building...\ndone\n");
  asst([{ type: "tool_use", id: "tu-bg", name: "Bash", input: { command: "npm run build", run_in_background: true } }]);
  out({ type: "system", subtype: "task_started", task_id: "bg1", tool_use_id: "tu-bg", description: "Build", is_backgrounded: true, task_type: "local_bash" });
  res("tu-bg", `Command running in background with ID: bg1. Output is being written to: ${file}`);
  out({ type: "system", subtype: "task_updated", task_id: "bg1", patch: { status: "completed", end_time: Date.now() } });
  out({ type: "system", subtype: "task_notification", task_id: "bg1", tool_use_id: "tu-bg", status: "completed", output_file: file, summary: "Background command \"Build\" completed (exit code 0)" });
}

const MCP_STATUS = [
  { name: "stub-tools", status: "connected", config: { type: "stdio", command: "stub-mcp", args: [] }, scope: "user", tools: [{ name: "echo", annotations: { readOnly: true } }] },
  { name: "claude.ai Docs", status: "connected", config: { type: "claudeai-proxy", url: "https://docs.example/mcp", id: "x" }, scope: "claudeai", tools: [{ name: "search", annotations: {} }] },
];

let buf = "";
let busy = Promise.resolve();
process.stdin.setEncoding("utf8");
process.stdin.on("data", (c) => {
  buf += c;
  let i;
  while ((i = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, i);
    buf = buf.slice(i + 1);
    let m;
    try {
      m = JSON.parse(line);
    } catch {
      continue;
    }
    if (m.type === "control_request" && m.request && m.request.subtype === "initialize") {
      out({ type: "control_response", response: { subtype: "success", request_id: m.request_id, response: { commands: [{ name: "stub-skill", description: "A skill the stub reports (user)", argumentHint: "" }, { name: "compact", description: "Clear conversation history but keep a summary in context", argumentHint: "" }], models: [{ value: "default", displayName: "Default" }, { value: "opus", resolvedModel: "claude-opus-stub", displayName: "Opus", description: "Stub opus", supportedEffortLevels: ["low", "high"] }] } } });
    } else if (m.type === "control_request" && m.request && m.request.subtype === "mcp_status") {
      out({ type: "control_response", response: { subtype: "success", request_id: m.request_id, response: { mcpServers: MCP_STATUS } } });
    } else if (m.type === "control_request" && m.request && (m.request.subtype === "mcp_toggle" || m.request.subtype === "stop_task")) {
      if (process.env.STUB_LOG) fs.appendFileSync(process.env.STUB_LOG, JSON.stringify({ control: m.request }) + "\n");
      out({ type: "control_response", response: { subtype: "success", request_id: m.request_id, response: {} } });
    } else if (m.type === "control_response" && waitingAnswer) {
      const r = waitingAnswer;
      waitingAnswer = null;
      r(m.response.response);
    } else if (m.type === "user") {
      const content = typeof m.message.content === "string" ? m.message.content : JSON.stringify(m.message.content);
      if (process.env.STUB_LOG) fs.appendFileSync(process.env.STUB_LOG, JSON.stringify({ prompt: content, env: { BRIDGE_ROLE: process.env.BRIDGE_ROLE, BRIDGE_TASK_ID: process.env.BRIDGE_TASK_ID } }) + "\n");
      if (steerBox) steerBox.push(content);
      else busy = busy.then(() => turn(content));
    }
  }
});
process.stdin.on("end", () => busy.then(() => process.exit(0)));
