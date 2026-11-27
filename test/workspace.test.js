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
const tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "bridge-workspace-")));
const DATA = path.join(tmp, "data");
const PORT = 48600 + Math.floor(Math.random() * 1000);
const URL_ = `http://127.0.0.1:${PORT}`;
const ENV = {
  ...process.env,
  BRIDGE_DATA_DIR: DATA,
  CLAUDE_BIN: path.join(__dirname, "stub.js"),
  BRIDGE_PORT: String(PORT),
  BRIDGE_ENV_FILE: path.join(tmp, "none.env"),
  TARGET_REPO: tmp,
  LINEAR_API_KEY: "",
  CODEX_BIN: path.join(tmp, "fake-codex"),
  CLAUDE_CONFIG_DIR: path.join(tmp, "claude-home"),
  BRIDGE_HISTORY_HOME: path.join(tmp, "home"),
  BRIDGE_MCP_HOME: path.join(tmp, "home"),
  STUB_LOG: path.join(tmp, "stub.log"),
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
      messages: [{ role: "assistant", agent: "claude", text: "The off-by-one is in paginateRows." }],
    }),
  );
  server = spawn(process.execPath, [path.join(ROOT, "server")], { env: ENV, stdio: "ignore" });
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
  process.env.BRIDGE_DATA_DIR = DATA;
  const tasks = require("../server/tasks");
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

/** No job in the chat, the harness's automatic nudge included. */
const idle = () => waitFor(async () => !(await get("/api/state")).jobs.running.includes(RUN_ID));

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

  // Back to Claude (the stub): it gets a briefing of what Codex did. Codex
  // ended without a report, so the harness may be nudging it right now:
  // queue behind that turn rather than racing it.
  await post(`/api/runs/${RUN_ID}/opts`, { opts: { agent: "claude" } });
  const next = await post(`/api/runs/${RUN_ID}/followup`, { text: "Now summarise.", queue: true });
  assert.strictEqual(next.ok, true, next.error);
  const after = await waitFor(async () => {
    const r = (await get(`/api/runs/${RUN_ID}`)).run;
    const m = r.messages.filter((x) => x.role === "assistant").pop();
    return m && m.agent === "claude" && m.state !== "running" ? r : null;
  });
  assert.ok(after.messages.some((m) => m.role === "event" && m.phase === "handoff" && /Claude/.test(m.text)));
});

test("a handoff briefs only what happened since the agent last worked, ignoring turns that failed", () => {
  const { handoff } = require("../server/agents");
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

test("changes: list, diff and commit a session's working folder; slash commands are discoverable", async () => {
  const repo = path.join(tmp, "changes-repo");
  fs.mkdirSync(repo);
  const g = (...a) => execFileSync("git", a, { cwd: repo, stdio: "ignore" });
  g("init", "-q", "-b", "main");
  fs.writeFileSync(path.join(repo, "a.txt"), "one\n");
  g("add", ".");
  g("-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false", "commit", "-qm", "init");
  g("config", "user.email", "t@t");
  g("config", "user.name", "t");
  g("config", "commit.gpgsign", "false");
  fs.writeFileSync(path.join(repo, "a.txt"), "one\ntwo\n");
  fs.writeFileSync(path.join(repo, "new.txt"), "fresh\n");
  await post(`/api/runs/${RUN_ID}/opts`, { opts: { workdir: repo } });
  const st = await get(`/api/runs/${RUN_ID}/changes`);
  assert.deepStrictEqual(st.files.map((f) => `${f.kind}:${f.path}`).sort(), ["added:new.txt", "modified:a.txt"]);
  assert.match((await get(`/api/runs/${RUN_ID}/diff?file=a.txt`)).diff, /^\+two$/m);
  assert.match((await get(`/api/runs/${RUN_ID}/diff?file=new.txt`)).diff, /^\+fresh$/m);
  assert.strictEqual((await get(`/api/runs/${RUN_ID}/diff?file=${encodeURIComponent("../../etc/passwd")}`)).status, 400);
  const after = await post(`/api/runs/${RUN_ID}/commit`, { message: "two lines" });
  assert.deepStrictEqual(after.files, []);
  assert.strictEqual(after.commits[0].subject, "two lines");
  const { commands } = await get(`/api/commands?runId=${RUN_ID}`);
  assert.ok(commands.some((c) => c.name === "compact"));
});

test("compact: /compact for Claude, a self-handoff for the other agents; files and session references for the composer", async () => {
  const last = async () => (await get(`/api/runs/${RUN_ID}`)).run;
  const settled = () =>
    waitFor(async () => {
      const r = await last();
      return r.messages.some((m) => m.role === "assistant" && m.state === "running") ? null : r;
    });
  await settled();
  await idle();
  await post(`/api/runs/${RUN_ID}/opts`, { opts: { agent: "claude" } });
  const out = await post(`/api/runs/${RUN_ID}/compact`, {});
  assert.strictEqual(out.ok, true, out.error);
  assert.strictEqual(out.native, true);
  const run = await waitFor(async () => {
    const r = await last();
    const m = r.messages.filter((x) => x.role === "assistant").pop();
    return m && m.kind === "compact" && m.state === "done" ? r : null;
  });
  const m = run.messages.filter((x) => x.role === "assistant").pop();
  assert.deepStrictEqual(m.compact, { pre: 42000, post: 6000 });
  assert.strictEqual(m.usage.input, 6000, "the context meter reads what's left");
  assert.match(m.text, /42k → 6k/);

  // Codex has no headless /compact: its session is dropped and its next turn is briefed.
  await idle();
  await post(`/api/runs/${RUN_ID}/opts`, { opts: { agent: "codex" } });
  const typed = await post(`/api/runs/${RUN_ID}/followup`, { text: "/compact keep the CSV bits" });
  assert.strictEqual(typed.compacted, true);
  assert.strictEqual(typed.native, false);
  const after = await last();
  assert.strictEqual(after.agentSessions.codex, "");
  assert.strictEqual(after.compactBrief.agent, "codex");
  assert.match(after.compactBrief.text, /Focus: keep the CSV bits/);
  fs.writeFileSync(path.join(tmp, "codex-prompt.txt"), "");
  await post(`/api/runs/${RUN_ID}/followup`, { text: "Carry on." });
  await waitFor(async () => {
    const r = await last();
    const x = r.messages.filter((y) => y.role === "assistant").pop();
    return x && x.agent === "codex" && x.state === "done" ? r : null;
  });
  const prompt = fs.readFileSync(path.join(tmp, "codex-prompt.txt"), "utf8");
  assert.match(prompt, /Compacted session/);
  assert.match(prompt, /Carry on\./);
  assert.strictEqual((await last()).compactBrief, undefined, "the summary is used once");
  await post(`/api/runs/${RUN_ID}/opts`, { opts: { agent: "claude" } });

  const repo = path.join(tmp, "changes-repo");
  fs.mkdirSync(path.join(repo, "src", "api"), { recursive: true });
  fs.writeFileSync(path.join(repo, "src", "api", "export.js"), "x\n");
  fs.writeFileSync(path.join(repo, ".gitignore"), "ignored.log\n");
  fs.writeFileSync(path.join(repo, "ignored.log"), "x\n");
  const files = await get(`/api/runs/${RUN_ID}/files`);
  assert.strictEqual(files.git, true);
  assert.ok(files.files.includes("src/api/export.js"), "untracked but not ignored files are listed");
  assert.ok(!files.files.includes("ignored.log"));
  assert.ok(files.dirs.includes("src/api"));

  const ref = await get(`/api/runs/${RUN_ID}/reference`);
  assert.strictEqual(ref.ok, true);
  const brief = fs.readFileSync(ref.path, "utf8");
  assert.match(brief, /Referenced session/);
  assert.match(brief, new RegExp(RUN_ID.replace(/\./g, "\\.")));

  const { commands } = await get(`/api/commands?runId=${RUN_ID}`);
  const stub = commands.find((c) => c.name === "stub-skill");
  assert.ok(stub, "Claude's own command list comes from its initialize handshake");
  assert.strictEqual(stub.description, "A skill the stub reports");
  assert.strictEqual(stub.scope, "user");
});

test("an orchestrator works in its project's checkout; clearing a chat that started elsewhere moves it there", async () => {
  const p = (await get("/api/projects")).projects[0];
  const orch = await post(`/api/projects/${p.id}/orchestrator`);
  let run = (await get(`/api/runs/${orch.runId}`)).run;
  assert.strictEqual(run.opts.workdir, p.path, "this repo means the project, not Bridge's own folder");
  // An older chat minted in Bridge's folder keeps it while it has a session…
  const file = path.join(DATA, "runs", `${orch.runId}.json`);
  fs.writeFileSync(file, JSON.stringify({ ...run, sessionId: "s-1", opts: { ...run.opts, workdir: ROOT } }));
  await post(`/api/projects/${p.id}/orchestrator`);
  assert.strictEqual((await get(`/api/runs/${orch.runId}`)).run.opts.workdir, ROOT);
  // …and moves once it's cleared.
  await post(`/api/runs/${orch.runId}/clear`);
  run = (await get(`/api/runs/${orch.runId}`)).run;
  assert.strictEqual(run.opts.workdir, p.path);
});

test("import a chat from an agent's own history: a worker in its folder that resumes the same session", async () => {
  const fx = require("./fixtures");
  const { repo } = fx.writeFixtures(ENV.BRIDGE_HISTORY_HOME);
  const list = await get("/api/history");
  const chat = list.chats.find((c) => c.agent === "claude");
  assert.ok(chat && !chat.runId, "listed, not imported yet");
  const preview = await get(`/api/history/claude/${chat.id}`);
  assert.strictEqual(preview.cwd, repo);
  assert.ok(preview.messages.length >= 2);

  const out = await post("/api/history/import", { agent: "claude", id: chat.id });
  assert.strictEqual(out.existing, false);
  const run = (await get(`/api/runs/${out.taskId}`)).run;
  assert.strictEqual(run.kind, "task");
  assert.strictEqual(run.sessionId, fx.CLAUDE_ID, "Claude resumes its own session");
  assert.strictEqual(run.opts.workdir, repo, "in the folder it ran in");
  assert.deepStrictEqual(run.imported.agent, "claude");
  assert.ok(run.messages.some((m) => m.role === "assistant" && m.steps.some((s) => s.name === "Bash")));
  const summary = (await get("/api/runs")).runs.find((r) => r.runId === out.taskId);
  assert.strictEqual(summary.task.status, "imported");
  assert.strictEqual((await post("/api/history/import", { agent: "claude", id: chat.id })).taskId, out.taskId, "importing again opens the first import");
  assert.strictEqual((await get("/api/history")).chats.find((c) => c.id === chat.id).runId, out.taskId);

  fs.writeFileSync(ENV.STUB_LOG, "");
  await post(`/api/runs/${out.taskId}/followup`, { text: "Carry on." });
  await waitFor(async () => fs.readFileSync(ENV.STUB_LOG, "utf8").includes(fx.CLAUDE_ID));
  const argv = fs.readFileSync(ENV.STUB_LOG, "utf8").trim().split("\n").map((l) => JSON.parse(l).argv).find((a) => a.includes(fx.CLAUDE_ID));
  assert.strictEqual(argv[argv.indexOf(fx.CLAUDE_ID) - 1], "--resume");
  await waitFor(async () => !(await get("/api/state")).jobs.running.includes(out.taskId));
  await new Promise((r) => setTimeout(r, 600));
  const after = (await get(`/api/runs/${out.taskId}`)).run;
  assert.ok(!after.messages.some((m) => m.label === "nudge"), "an imported chat isn't nudged for a report");
  const prompts = () => fs.readFileSync(ENV.STUB_LOG, "utf8").trim().split("\n").map((l) => JSON.parse(l)).filter((x) => x.prompt).map((x) => JSON.stringify(x.prompt));
  assert.ok(prompts()[0].includes("<instructions>"), "the first turn here brings Bridge's rules: a resumed session keeps its old system prompt");
  await post(`/api/runs/${out.taskId}/followup`, { text: "And again." });
  await waitFor(async () => prompts().length >= 2);
  assert.ok(!prompts()[1].includes("<instructions>"), "only once");

  // Imported into a chosen project: it still runs in its own folder.
  const target = (await get("/api/projects")).projects.find((p) => !p.root);
  const codex = await post("/api/history/import", { agent: "codex", id: fx.CODEX_ID, project: target.id });
  const crun = (await get(`/api/runs/${codex.taskId}`)).run;
  assert.strictEqual((await get("/api/runs")).runs.find((r) => r.runId === codex.taskId).project, target.id);
  assert.strictEqual(crun.opts.workdir, repo);
  assert.deepStrictEqual([crun.opts.agent, crun.agentSessions.codex], ["codex", fx.CODEX_ID]);
  assert.strictEqual((await post("/api/history/import", { agent: "nope", id: "x" })).status, 400);
  // A chat whose folder is gone is listed as such and can't be carried on elsewhere.
  fs.renameSync(repo, `${repo}-moved`);
  assert.strictEqual((await get("/api/history")).chats.find((c) => c.agent === "codex").gone, true);
  const devinOrCursor = (await get("/api/history")).chats.find((c) => c.agent === "cursor" || c.agent === "devin");
  if (devinOrCursor) assert.match((await post("/api/history/import", { agent: devinOrCursor.agent, id: devinOrCursor.id })).error, /folder this chat ran in is gone/);
  fs.renameSync(`${repo}-moved`, repo);
});

test("Default's folder is the fallback everywhere, not the first project; only Slack pipeline runs default to its repo", async () => {
  const root = path.join(tmp, "default-root");
  fs.mkdirSync(root, { recursive: true });
  await post("/api/projects/default", { path: root });
  const all = (await get("/api/projects")).projects;
  assert.ok(all[1] && all[1].path !== root, "a real project comes first after Default");
  // The global default (the app's terminal and pickers read meta.workdir).
  assert.strictEqual((await get("/api/state")).meta.workdir, root);
  // A global workdir is no longer a setting.
  const saved = await post("/api/config", { followup: { workdir: all[1].path } });
  assert.strictEqual(saved.config.followup.workdir, undefined);
  assert.strictEqual((await get("/api/state")).meta.workdir, root);
  // A task with no repo works in Default's folder.
  const t = await post("/api/tasks", { title: "no repo", brief: "anything", start: false });
  assert.strictEqual(t.worktree, root);
  // A Slack chat with no project still runs in the pipeline's repo (TARGET_REPO).
  const slack = "1700000002.000200";
  fs.writeFileSync(path.join(DATA, "runs", `${slack}.json`), JSON.stringify({ runId: slack, createdAt: 1700000000, updatedAt: 1700000000, who: "Sam", text: "a thread", action: "pending", messages: [] }));
  assert.strictEqual((await get(`/api/runs/${slack}/terminal`)).workdir, tmp);
});
