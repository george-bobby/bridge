/**
 * The workspace views' server side: board columns, transcript search, the
 * read-only feeds' origin rule, and .worktreeinclude. A real dashboard on a
 * scratch data dir; nothing here calls GitHub or Linear.
 */

const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawn, execFileSync } = require("child_process");

const ROOT = path.join(__dirname, "..");
const tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "sb-workspace-")));
const DATA = path.join(tmp, "data");
const PORT = 48600 + Math.floor(Math.random() * 1000);
const URL_ = `http://127.0.0.1:${PORT}`;
const ENV = {
  ...process.env,
  SB_DATA_DIR: DATA,
  CLAUDE_BIN: path.join(__dirname, "stub-claude.js"),
  BRIDGE_PORT: String(PORT),
  BRIDGE_ENV_FILE: path.join(tmp, "none.env"),
  TARGET_REPO: tmp,
  LINEAR_API_KEY: "",
  CODEX_BIN: path.join(tmp, "fake-codex"),
};

const RUN_ID = "1700000001.000100";
let server;

test.before(async () => {
  // A stand-in Codex: reads the prompt from stdin, prints `codex exec --json` events.
  fs.writeFileSync(
    ENV.CODEX_BIN,
    `#!/bin/sh
cat >> "${tmp}/codex-prompt.txt"
printf '%s\\n' '{"type":"thread.started","thread_id":"th-123"}'
printf '%s\\n' '{"type":"item.started","item":{"id":"i1","type":"command_execution","command":"ls","status":"in_progress"}}'
printf '%s\\n' '{"type":"item.completed","item":{"id":"i1","type":"command_execution","command":"ls","aggregated_output":"a.txt\\n","exit_code":0,"status":"completed"}}'
printf '%s\\n' '{"type":"item.completed","item":{"id":"i2","type":"agent_message","text":"Codex says hi"}}'
printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":7}}'
`,
    { mode: 0o755 },
  );
  fs.mkdirSync(path.join(DATA, "runs"), { recursive: true });
  fs.writeFileSync(
    path.join(DATA, "runs", `${RUN_ID}.json`),
    JSON.stringify({
      runId: RUN_ID,
      createdAt: 1700000000,
      updatedAt: 1700000100,
      who: "Priya",
      text: "CSV export drops the last row",
      action: "pending",
      messages: [{ role: "assistant", text: "The off-by-one is in paginateRows." }],
    }),
  );
  server = spawn(process.execPath, [path.join(ROOT, "index.js")], { env: ENV, stdio: "ignore" });
  const end = Date.now() + 10000;
  while (Date.now() < end) {
    if (await fetch(`${URL_}/api/state`).then((r) => r.ok).catch(() => false)) return;
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error("server did not start");
});

test.after(() => {
  if (server) server.kill("SIGTERM"); // the exact PID this test started
  fs.rmSync(tmp, { recursive: true, force: true });
});

const post = (p, body, headers = {}) =>
  fetch(URL_ + p, { method: "POST", headers: { "Content-Type": "application/json", ...headers }, body: JSON.stringify(body) }).then(async (r) => ({ status: r.status, ...(await r.json()) }));
const get = (p, headers = {}) => fetch(URL_ + p, { headers }).then(async (r) => ({ status: r.status, ...(await r.json()) }));
const summary = async () => (await get("/api/runs")).runs.find((r) => r.runId === RUN_ID);

test("a dragged card keeps its column, doesn't count as activity, and unpins", async () => {
  const before = await summary();
  assert.strictEqual(before.board, "");
  assert.strictEqual((await post(`/api/runs/${RUN_ID}/board`, { column: "review" })).ok, true);
  const after = await summary();
  assert.strictEqual(after.board, "review");
  assert.strictEqual(after.updatedAt, before.updatedAt, "moving a card must not bump updatedAt");
  assert.strictEqual((await post(`/api/runs/${RUN_ID}/board`, { column: "nowhere" })).status, 400);
  await post(`/api/runs/${RUN_ID}/board`, { column: "" });
  assert.strictEqual((await summary()).board, "");
});

test("search finds text inside a transcript, not just the thread", async () => {
  const { hits } = await get("/api/search?q=paginaterows");
  assert.strictEqual(hits.length, 1);
  assert.strictEqual(hits[0].runId, RUN_ID);
  assert.match(hits[0].snippet, /paginateRows/);
  assert.deepStrictEqual((await get("/api/search?q=x")).hits, [], "one letter is not a search");
});

test("private feeds refuse cross-origin reads; Linear without a key says so", async () => {
  const evil = { Origin: "http://evil.example" };
  assert.strictEqual((await get("/api/sources/linear", evil)).status, 403);
  assert.strictEqual((await get("/api/search?q=csv", evil)).status, 403);
  const linear = await get("/api/sources/linear");
  assert.strictEqual(linear.configured, false);
  assert.ok(Array.isArray((await get("/api/sources/ports")).servers));
});

test(".worktreeinclude copies the listed untracked files into a new worktree", async () => {
  process.env.SB_DATA_DIR = DATA;
  const tasks = require("../lib/tasks");
  const repo = path.join(tmp, "inc-repo");
  fs.mkdirSync(repo);
  const g = (...a) => execFileSync("git", a, { cwd: repo, stdio: "ignore" });
  g("init", "-q", "-b", "main");
  fs.writeFileSync(path.join(repo, ".gitignore"), ".env\ncerts/\nbuild/\n");
  g("add", ".");
  g("-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false", "commit", "-qm", "init");
  fs.writeFileSync(path.join(repo, ".env"), "A=1\n");
  fs.mkdirSync(path.join(repo, "certs"));
  fs.writeFileSync(path.join(repo, "certs", "dev.pem"), "pem\n");
  fs.mkdirSync(path.join(repo, "build"));
  fs.writeFileSync(path.join(repo, "build", "out.js"), "big\n");
  fs.writeFileSync(path.join(repo, ".worktreeinclude"), ".env\ncerts/\n");
  const wt = path.join(tmp, "inc-wt");
  g("worktree", "add", "-q", "-b", "t", wt, "main");
  assert.strictEqual(await tasks.copyIncludes(repo, wt), 2);
  assert.strictEqual(fs.readFileSync(path.join(wt, ".env"), "utf8"), "A=1\n");
  assert.ok(fs.existsSync(path.join(wt, "certs", "dev.pem")));
  assert.ok(!fs.existsSync(path.join(wt, "build")), "only what .worktreeinclude lists");

  // A link in the worktree (say a tracked symlink) is never written through.
  const outside = path.join(tmp, "outside");
  fs.mkdirSync(outside);
  fs.rmSync(path.join(wt, ".env"));
  fs.symlinkSync(path.join(outside, "stolen"), path.join(wt, ".env"));
  fs.rmSync(path.join(wt, "certs"), { recursive: true });
  fs.symlinkSync(outside, path.join(wt, "certs"));
  assert.strictEqual(await tasks.copyIncludes(repo, wt), 0);
  assert.deepStrictEqual(fs.readdirSync(outside), []);
});

async function waitFor(fn, ms = 10000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    const v = await fn();
    if (v) return v;
    await new Promise((r) => setTimeout(r, 150));
  }
  throw new Error("timed out");
}

test("a session can switch agents: Codex runs through the same transcript, and the next agent gets a handoff", async () => {
  await post(`/api/runs/${RUN_ID}/opts`, { opts: { agent: "codex" } });
  await post(`/api/runs/${RUN_ID}/followup`, { text: "List the files." });
  const run = await waitFor(async () => {
    const r = (await get(`/api/runs/${RUN_ID}`)).run;
    const m = r.messages.filter((x) => x.role === "assistant").pop();
    return m && m.state === "done" ? r : null;
  });
  const reply = run.messages.filter((x) => x.role === "assistant").pop();
  assert.strictEqual(reply.agent, "codex");
  assert.strictEqual(reply.text, "Codex says hi");
  const tool = reply.steps.find((x) => x.kind === "tool");
  assert.deepStrictEqual([tool.name, tool.ok, tool.result.trim()], ["Bash", true, "a.txt"]);
  assert.strictEqual(reply.usage.output, 7);
  assert.strictEqual(run.agentSessions.codex, "th-123", "the agent's session id is kept for the next turn");
  assert.match(fs.readFileSync(path.join(tmp, "codex-prompt.txt"), "utf8"), /List the files\./);

  // Back to Claude (the stub): it gets a briefing of what Codex did.
  await post(`/api/runs/${RUN_ID}/opts`, { opts: { agent: "claude" } });
  await post(`/api/runs/${RUN_ID}/followup`, { text: "Now summarise." });
  const after = await waitFor(async () => {
    const r = (await get(`/api/runs/${RUN_ID}`)).run;
    const m = r.messages.filter((x) => x.role === "assistant").pop();
    return m && m.agent === "claude" && m.state !== "running" ? r : null;
  });
  assert.ok(after.messages.some((m) => m.role === "event" && m.phase === "handoff" && /Claude/.test(m.text)));
});

test("a handoff briefs only what happened since the agent last worked, ignoring turns that failed", () => {
  const { handoff } = require("../lib/agents");
  const run = {
    kind: "task", who: "Fix CSV", text: "CSV drops a row", prUrl: "https://github.com/acme/x/pull/1",
    messages: [
      { role: "user", text: "fix it" },
      { role: "assistant", agent: "claude", state: "done", text: "Found paginateRows()" },
      { role: "user", text: "codex, take over" },
      { role: "assistant", agent: "codex", state: "done", text: "Fixed and pushed", steps: [{ kind: "tool", name: "Bash", detail: "npm test" }] },
      { role: "user", text: "claude again" },
      { role: "assistant", agent: "claude", state: "error", text: "" },
    ],
  };
  const brief = handoff(run, "claude", { meta: { branch: "alex/csv", worktree: "/w" } });
  assert.match(brief, /taking over this session from Codex/);
  assert.match(brief, /Codex \(used: Bash npm test\): Fixed and pushed/);
  assert.doesNotMatch(brief, /Found paginateRows/, "only what's new since Claude last worked");
  assert.match(brief, /Branch: alex\/csv/);
  assert.strictEqual(handoff({ ...run, messages: run.messages.slice(0, 4) }, "codex"), "", "no handoff to the agent that spoke last");
});
