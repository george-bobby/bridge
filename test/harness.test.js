/**
 * End-to-end harness tests against a real dashboard process, a real scratch
 * repo with a bare origin, and the stub agent (test/stub.js). Nothing
 * here touches the real data/, the real repos or costs usage.
 *
 *   node --test test/
 */

const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawn, execFileSync, spawnSync } = require("child_process");

const ROOT = path.join(__dirname, "..");
const STUB = path.join(__dirname, "stub.js");
const tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "bridge-harness-")));
const DATA = path.join(tmp, "data");
const REPO = path.join(tmp, "repo");
const ORIGIN = path.join(tmp, "origin.git");
const PORT = 47000 + Math.floor(Math.random() * 1500);
const URL_ = `http://127.0.0.1:${PORT}`;

const git = (args, cwd = REPO) => execFileSync("git", args, { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();

function makeRepo() {
  fs.mkdirSync(REPO, { recursive: true });
  git(["init", "-q", "-b", "main"]);
  git(["config", "user.email", "t@example.com"]);
  git(["config", "user.name", "t"]);
  git(["config", "commit.gpgsign", "false"]);
  fs.writeFileSync(path.join(REPO, "README.md"), "scratch\n");
  git(["add", "."]);
  git(["commit", "-q", "-m", "init"]);
  execFileSync("git", ["init", "-q", "--bare", ORIGIN]);
  git(["remote", "add", "origin", ORIGIN]);
  git(["push", "-q", "-u", "origin", "main"]);
  git(["remote", "set-head", "origin", "main"]);
}

const ENV = {
  ...process.env,
  BRIDGE_DATA_DIR: DATA,
  CLAUDE_BIN: STUB,
  BRIDGE_PORT: String(PORT),
  BRIDGE_ENV_FILE: path.join(tmp, "none.env"),
  TARGET_REPO: REPO,
  WORKTREE_ROOT: path.join(tmp, "wt"),
  SLACK_USER_NAME: "Alex",
  BRANCH_PREFIX: "test",
  BRIDGE_TICK_MS: "300",
  BRIDGE_STALL_SEC: "2",
  STUB_LOG: path.join(tmp, "stub.log"),
  // A scratch ~/.claude: no user skills or settings leak into the tests.
  CLAUDE_CONFIG_DIR: path.join(tmp, "claude-home"),
  BRIDGE_MCP_HOME: path.join(tmp, "home"),
  BRIDGE_URL: URL_,
  BRIDGE_TASK_ID: "",
  BRIDGE_GH: path.join(tmp, "gh"),
};

let server = null;
function startServer() {
  server = spawn(process.execPath, [path.join(ROOT, "server")], { env: ENV, stdio: ["ignore", "pipe", "pipe"] });
  server.stderr.on("data", (d) => process.env.BRIDGE_TEST_VERBOSE && process.stderr.write(d));
  return waitFor(async () => (await fetch(`${URL_}/api/state`).then((r) => r.ok).catch(() => false)), 10000, "server up");
}
function stopServer() {
  if (!server) return Promise.resolve();
  const s = server;
  server = null;
  return new Promise((r) => {
    s.on("exit", r);
    s.kill("SIGTERM"); // the exact PID this test started
  });
}

async function api(method, p, body) {
  const r = await fetch(URL_ + p, { method, headers: body ? { "Content-Type": "application/json" } : {}, body: body ? JSON.stringify(body) : undefined });
  const j = await r.json().catch(() => ({}));
  return { status: r.status, ...j };
}

function cli(...args) {
  const r = spawnSync(process.execPath, [path.join(ROOT, "bin", "bridge"), ...args], { env: ENV, encoding: "utf8" });
  return { code: r.status, out: r.stdout, err: r.stderr };
}

async function waitFor(fn, ms = 15000, what = "condition") {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    last = await fn();
    if (last) return last;
    await new Promise((r) => setTimeout(r, 150));
  }
  throw new Error(`timed out waiting for ${what}`);
}

const meta = (id) => JSON.parse(fs.readFileSync(path.join(DATA, "tasks", id, "meta.json"), "utf8"));
const statusIs = (id, s) => () => {
  try {
    return meta(id).status === s;
  } catch {
    return false;
  }
};
const idle = (id) => async () => !(await api("GET", "/api/state")).jobs.running.includes(id);

async function spawnTask(title, brief, extra = {}) {
  const r = await api("POST", "/api/tasks", { repo: REPO, title, brief, ...extra });
  assert.equal(r.ok, true, r.error);
  return r;
}

test.before(async () => {
  makeRepo();
  fs.writeFileSync(ENV.BRIDGE_GH, `#!/bin/sh\nexec "${process.execPath}" "${path.join(__dirname, "gh.js")}" "$@"\n`, { mode: 0o755 });
  fs.mkdirSync(DATA, { recursive: true });
  fs.writeFileSync(path.join(DATA, "config.json"), JSON.stringify({ harness: { relay: true, mode: "normal" } }));
  await startServer();
});
test.after(async () => {
  await stopServer();
  if (!process.env.BRIDGE_TEST_KEEP) fs.rmSync(tmp, { recursive: true, force: true });
});

test("spawn → worker in its own worktree → report → relayed, main checkout untouched", async () => {
  const t = await spawnTask("add a function", "Add a function and a test.\nstub:report=ready-for-review", { by: "orchestrator" });
  assert.equal(t.state, "started");
  await waitFor(statusIs(t.taskId, "ready-for-review"), 15000, "report");

  assert.ok(fs.existsSync(t.worktree), "worktree exists");
  assert.equal(git(["rev-parse", "--abbrev-ref", "HEAD"], t.worktree), t.branch);
  assert.equal(git(["status", "--porcelain"]), "", "main checkout untouched");
  assert.equal(git(["rev-parse", "--abbrev-ref", "HEAD"]), "main");

  // The worker ran with the guard hook, its contract and its identity.
  const log = fs.readFileSync(ENV.STUB_LOG, "utf8").trim().split("\n").map(JSON.parse);
  const mine = log.find((l) => l.env.BRIDGE_TASK_ID === t.taskId);
  assert.ok(mine.argv.includes("--settings"));
  assert.match(mine.argv[mine.argv.indexOf("--settings") + 1], /guard\.js/);
  const sys = fs.readFileSync(mine.argv[mine.argv.indexOf("--append-system-prompt-file") + 1], "utf8");
  assert.match(sys, /report contract/);
  assert.match(sys, new RegExp(t.worktree.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
  assert.equal(mine.env.BRIDGE_ROLE, "task");
  assert.equal(mine.env.BRIDGE_GUARD, "1");

  const inbox = await api("GET", "/api/inbox");
  assert.ok(!inbox.todos.some((x) => x.taskId === t.taskId), "no review to-do: the chat shows the PR");

  // Its project's orchestrator got a relay turn about it (Default's is `orchestrator`).
  const project = (await api("GET", "/api/projects")).projects.find((p) => !p.root);
  const orchId = `orchestrator-${project.id}`;
  await waitFor(async () => {
    const o = await api("GET", `/api/runs/${orchId}`);
    return o.run && o.run.messages.some((m) => m.role === "relay" && m.text.includes(t.taskId));
  }, 10000, "relay");
  const o = (await api("GET", `/api/runs/${orchId}`)).run;
  assert.equal(o.kind, "orchestrator");
});

test("per-project automation: saved per project, rendered for its workers, exported to the guard", async () => {
  const project = (await api("GET", "/api/projects")).projects.find((p) => !p.root);
  assert.deepEqual(project.auto, { merge: false, review: false, resolve: false, rebase: true, decide: false });
  const sysOf = (id) => {
    const line = fs.readFileSync(ENV.STUB_LOG, "utf8").trim().split("\n").map(JSON.parse).filter((l) => l.argv && l.env.BRIDGE_TASK_ID === id).pop();
    return { env: line.env, sys: fs.readFileSync(line.argv[line.argv.indexOf("--append-system-prompt-file") + 1], "utf8") };
  };

  const plain = await spawnTask("defaults", "Nothing to automate.\nstub:report=ready-for-review");
  await waitFor(idle(plain.taskId), 15000, "idle");
  assert.doesNotMatch(sysOf(plain.taskId).sys, /This project's automation/, "all defaults: nothing added");
  assert.equal(sysOf(plain.taskId).env.BRIDGE_PROJECT, project.id);

  const saved = await api("POST", `/api/projects/${project.id}`, { auto: { merge: true, resolve: true, rebase: false, bogus: true } });
  assert.deepEqual(saved.project.auto, { merge: true, review: false, resolve: true, rebase: false, decide: false });
  const stored = JSON.parse(fs.readFileSync(path.join(DATA, "projects.json"), "utf8")).find((p) => p.id === project.id);
  assert.deepEqual(stored.auto, { merge: true, resolve: true, rebase: false }, "only what differs from the defaults is stored");

  const t = await spawnTask("automated", "Merge it when green.\nstub:report=ready-for-review");
  await waitFor(idle(t.taskId), 15000, "idle");
  const { sys } = sysOf(t.taskId);
  assert.match(sys, /## This project's automation/);
  assert.match(sys, /gh pr merge <n> --merge/);
  assert.match(sys, /- Resolve:/);
  assert.match(sys, /- Rebase: optional/);
  assert.match(sys, /stay drafts for Alex/);
  assert.doesNotMatch(sys, /- Review:|- Small decisions:/, "only the enabled toggles");

  // Default keeps its own settings in data/default.json.
  const def = await api("POST", "/api/projects/default", { auto: { decide: true } });
  assert.equal(def.project.auto.decide, true);
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(DATA, "default.json"), "utf8")).auto, { decide: true });
  await api("POST", "/api/projects/default", { auto: { decide: false } });
  assert.equal((await api("POST", `/api/projects/${project.id}`, { auto: { merge: false, resolve: false, rebase: true } })).project.auto.merge, false);
  assert.equal(JSON.parse(fs.readFileSync(path.join(DATA, "projects.json"), "utf8")).find((p) => p.id === project.id).auto, undefined);
});

test("a project's GitHub account and Linear team reach its workers", async () => {
  const project = (await api("GET", "/api/projects")).projects.find((p) => !p.root);
  assert.deepEqual((await api("GET", "/api/github/accounts")).accounts.map((a) => a.login), ["alex", "alex-work"]);
  assert.equal((await api("POST", `/api/projects/${project.id}`, { github: "stranger" })).ok, false, "an account gh doesn't know");
  assert.equal((await api("POST", `/api/projects/${project.id}`, { linear: "R-LS!" })).ok, false, "not a team key");

  const saved = (await api("POST", `/api/projects/${project.id}`, { github: "alex-work", linear: "rls" })).project;
  assert.deepEqual(saved.github, { login: "alex-work", host: "github.com", name: "alex-work", email: "42+alex-work@users.noreply.github.com" });
  assert.equal(saved.linear, "RLS");

  const t = await spawnTask("as work", "Commit as work.\nstub:report=ready-for-review");
  await waitFor(idle(t.taskId), 15000, "idle");
  const line = fs.readFileSync(ENV.STUB_LOG, "utf8").trim().split("\n").map(JSON.parse).filter((l) => l.argv && l.env.BRIDGE_TASK_ID === t.taskId).pop();
  assert.equal(line.env.GIT_AUTHOR_EMAIL, "42+alex-work@users.noreply.github.com");
  assert.equal(line.env.GH_TOKEN, "tok-work");
  const sys = fs.readFileSync(line.argv[line.argv.indexOf("--append-system-prompt-file") + 1], "utf8");
  assert.equal(sys.match(/^- This project: .*$/gm).length, 1, "one line");
  assert.match(sys, /GitHub `alex-work`/);
  assert.match(sys, /Linear team is `RLS`/);

  // Linear keys are checked against the teams Bridge resolved, when it has some.
  const idFile = path.join(DATA, "identity.json");
  const before = fs.existsSync(idFile) ? fs.readFileSync(idFile, "utf8") : null;
  fs.writeFileSync(idFile, JSON.stringify({ ...(before ? JSON.parse(before) : {}), linear: { teams: [{ key: "RLS", name: "Studio" }] } }));
  assert.equal((await api("POST", `/api/projects/${project.id}`, { linear: "DEEP" })).ok, false, "not one of your teams");
  if (before == null) fs.rmSync(idFile);
  else fs.writeFileSync(idFile, before);

  const cleared = (await api("POST", `/api/projects/${project.id}`, { github: "", linear: "" })).project;
  assert.equal(cleared.github, undefined);
  assert.equal(cleared.linear, undefined);
  const plain = await spawnTask("as me", "Back to normal.\nstub:report=ready-for-review");
  await waitFor(idle(plain.taskId), 15000, "idle");
  const l2 = fs.readFileSync(ENV.STUB_LOG, "utf8").trim().split("\n").map(JSON.parse).filter((l) => l.argv && l.env.BRIDGE_TASK_ID === plain.taskId).pop();
  assert.equal(l2.env.GH_TOKEN, process.env.GH_TOKEN, "no account: the server's own env");
  assert.doesNotMatch(fs.readFileSync(l2.argv[l2.argv.indexOf("--append-system-prompt-file") + 1], "utf8"), /- This project:/);
});

test("needs-input → decision → answer goes back to the worker → ready", async () => {
  const t = await spawnTask("pick a format", "stub:report=needs-input\nstub:question=CSV or JSON? (recommend CSV)");
  await waitFor(statusIs(t.taskId, "needs-input"), 15000, "needs-input");
  const d = (await api("GET", "/api/inbox")).decisions.find((x) => x.taskId === t.taskId);
  assert.equal(d.kind, "question");
  assert.match(d.text, /CSV or JSON/);
  await waitFor(idle(t.taskId), 5000, "idle");
  const r = cli("decide", d.id, "CSV, as you recommended");
  assert.equal(r.code, 0, r.err);
  await waitFor(statusIs(t.taskId, "ready-for-review"), 15000, "answered → ready");
  const run = (await api("GET", `/api/runs/${t.taskId}`)).run;
  assert.ok(run.messages.some((m) => m.role === "harness" && m.text.includes("CSV, as you recommended")));
  assert.ok(!(await api("GET", "/api/inbox")).decisions.some((x) => x.id === d.id), "decision closed");
});

test("a report's options reach the Inbox; For you items are to-dos", async () => {
  const t = await spawnTask("needs a token", "stub:report=needs-input\nstub:you=Add FOO_TOKEN to .env\nstub:question=Which region?\\nA) EU (recommended)\\nB) US");
  await waitFor(statusIs(t.taskId, "needs-input"), 15000, "needs-input");
  const inbox = await api("GET", "/api/inbox");
  const mine = inbox.decisions.filter((x) => x.taskId === t.taskId);
  assert.deepEqual(mine.map((x) => x.kind), ["question"], "no fallback question on top of the real one");
  assert.equal(mine[0].question, "Which region?");
  assert.deepEqual(mine[0].options.map((o) => [o.key, o.recommended]), [["A", true], ["B", false]]);
  const todo = inbox.todos.find((x) => x.taskId === t.taskId && x.key.startsWith("you:"));
  assert.equal(todo && todo.text, "Add FOO_TOKEN to .env");
});

test("a rewritten report files nothing twice; what you closed stays closed", async () => {
  const t = await spawnTask("refile", "stub:report=needs-input\nstub:question=Q-refile?\nstub:question=Q-keep?\nstub:you=Add FOO_TOKEN");
  await waitFor(statusIs(t.taskId, "needs-input"), 15000, "needs-input");
  await waitFor(idle(t.taskId), 5000, "idle");
  const first = await api("GET", "/api/inbox");
  const q = first.decisions.find((x) => x.taskId === t.taskId && x.text === "Q-refile?");
  const keep = first.decisions.find((x) => x.taskId === t.taskId && x.text === "Q-keep?");
  const todo = first.todos.find((x) => x.taskId === t.taskId);
  assert.equal(cli("dismiss", q.id).code, 0);
  assert.equal(cli("todo", "done", todo.key).code, 0);
  const hash = meta(t.taskId).reportHash;
  // Same asks, new report bytes (the status line changes).
  assert.equal(cli("followup", t.taskId, "stub:report=blocked").code, 0);
  await waitFor(() => meta(t.taskId).reportHash !== hash, 15000, "report rewritten");
  await waitFor(idle(t.taskId), 5000, "idle");
  const after = await api("GET", "/api/inbox");
  assert.deepEqual(after.decisions.filter((x) => x.taskId === t.taskId).map((x) => x.id), [keep.id], "the open ask kept its id; the dismissed one stayed dismissed");
  assert.ok(!after.todos.some((x) => x.taskId === t.taskId), "a ticked-off For you item stays ticked off");
  const all = JSON.parse(fs.readFileSync(path.join(DATA, "tasks", "decisions.json"), "utf8"));
  assert.equal(all.filter((x) => x.taskId === t.taskId && x.text === "Q-refile?").length, 1);
});

test("defer hides a decision until its day; duplicate to-dos are refused", async () => {
  const t = await spawnTask("two questions", "stub:report=needs-input\nstub:question=First?\nstub:question=Second?");
  await waitFor(statusIs(t.taskId, "needs-input"), 15000);
  const ds = (await api("GET", "/api/inbox")).decisions.filter((x) => x.taskId === t.taskId);
  assert.equal(ds.length, 2);
  const tomorrow = new Date(Date.now() + 86400000).toISOString().slice(0, 10);
  assert.equal(cli("defer", ds[1].id, tomorrow).code, 0);
  const open = (await api("GET", "/api/inbox")).decisions.filter((x) => x.taskId === t.taskId);
  assert.deepEqual(open.map((x) => x.id), [ds[0].id]);

  assert.equal(cli("todo", "add", "merge-42", "Merge PR 42").code, 0);
  const dup = cli("todo", "add", "merge-42", "Merge PR 42 again");
  assert.equal(dup.code, 3);
  assert.match(dup.err, /already on the list/);
  assert.equal(cli("todo", "done", "merge-42").code, 0);

  const c = cli("status", "--since", "1h");
  assert.equal(c.code, 0, c.err);
  assert.match(c.out, /Waiting on you/);
  assert.match(c.out, /First\?/);
  assert.doesNotMatch(c.out, /Second\?/);
});

test("Brief me hands the orchestrator the catch-up in one turn", async () => {
  assert.equal((await api("POST", "/api/brief", { since: "soon" })).status, 400);
  await waitFor(idle("orchestrator"), 15000, "orchestrator idle");
  const out = await api("POST", "/api/brief", { since: "1h" });
  assert.equal(out.runId, "orchestrator");
  const msg = await waitFor(async () => (await api("GET", "/api/runs/orchestrator")).run.messages.find((m) => m.role === "relay" && m.text.startsWith("[harness] BRIEF")), 10000, "brief turn");
  for (const h of ["## Waiting on you", "## Slack, not started", "## To-dos", "## Workers", "## What happened (last 1h)"]) assert.ok(msg.text.includes(h), h);
  assert.match(msg.text, /First\?/, "the open question is in it");
});

test("no report: an answer ends quietly; changed code gets one nudge, then idle-without-report", async () => {
  const q = await spawnTask("a question", "stub:noreport");
  await waitFor(statusIs(q.taskId, "idle"), 15000, "idle after an answer");
  await waitFor(idle(q.taskId), 5000);
  const qrun = (await api("GET", `/api/runs/${q.taskId}`)).run;
  assert.ok(!qrun.messages.some((m) => m.role === "harness"), "no nudge for a turn that changed nothing");
  assert.ok(!qrun.messages.some((m) => m.role === "user" && /\*\*Brief\*\*/.test(m.text)), "the brief shows as the plain request");

  const a = await spawnTask("silent", "stub:noreport\nstub:edit");
  await waitFor(statusIs(a.taskId, "idle-without-report"), 15000, "idle-without-report");
  const run = (await api("GET", `/api/runs/${a.taskId}`)).run;
  assert.equal(run.messages.filter((m) => m.role === "harness" && /haven't written/.test(m.text)).length, 1, "nudged exactly once");

  const b = await spawnTask("forgetful", "stub:noreport\nstub:edit\nstub:report-on-nudge");
  await waitFor(statusIs(b.taskId, "ready-for-review"), 15000, "report after nudge");
});

test("a follow-up on a chat with a report isn't nudged to rewrite it", async () => {
  const t = await spawnTask("explain", "stub:report=ready-for-review");
  await waitFor(statusIs(t.taskId, "ready-for-review"), 15000);
  await waitFor(idle(t.taskId), 5000);
  const r = await api("POST", `/api/runs/${t.taskId}/followup`, { text: "what does it mean? stub:noreport" });
  assert.equal(r.ok, true, r.error);
  await waitFor(async () => (await api("GET", `/api/runs/${t.taskId}`)).run.messages.filter((m) => m.role === "assistant" && m.state === "done").length >= 2, 15000, "follow-up done");
  await waitFor(idle(t.taskId), 5000);
  await new Promise((res) => setTimeout(res, 500));
  const run = (await api("GET", `/api/runs/${t.taskId}`)).run;
  assert.ok(!run.messages.some((m) => m.role === "harness"), "no nudge");
  assert.equal(meta(t.taskId).status, "ready-for-review");
});

test("a chat you started yourself isn't relayed to the orchestrator", async () => {
  await waitFor(idle("orchestrator"), 15000, "orchestrator idle");
  const t = await spawnTask("mine", "stub:report=needs-input\nstub:question=Which?");
  await waitFor(statusIs(t.taskId, "needs-input"), 15000);
  await new Promise((res) => setTimeout(res, 800));
  const o = (await api("GET", "/api/runs/orchestrator")).run;
  assert.ok(!o.messages.some((m) => m.role === "relay" && m.text.includes(t.taskId)), "not relayed");
});

test("stall, usage limit and a dead worker each become an outcome", async () => {
  const s = await spawnTask("slow", "stub:stall=4\nstub:report=ready-for-review");
  await waitFor(statusIs(s.taskId, "worker-stalled"), 10000, "stall");
  await waitFor(statusIs(s.taskId, "ready-for-review"), 15000, "recovers to report");

  const l = await spawnTask("limited", "stub:limit");
  await waitFor(statusIs(l.taskId, "usage-limit"), 15000, "usage-limit");

  const g = await spawnTask("crashy", "stub:exit");
  await waitFor(statusIs(g.taskId, "worker-gone"), 15000, "worker-gone");
  assert.ok((await api("GET", "/api/inbox")).decisions.some((d) => d.taskId === g.taskId && d.kind === "resume"));
});

test("a stop you ask for ends the turn as stopped, not as an error", async () => {
  const t = await spawnTask("stoppy", "stub:stall=30");
  await waitFor(async () => (await api("GET", "/api/state")).jobs.running.includes(t.taskId), 10000, "running");
  assert.equal((await api("POST", `/api/runs/${t.taskId}/stop`)).ok, true);
  await waitFor(idle(t.taskId), 10000, "idle");
  const m = (await api("GET", `/api/runs/${t.taskId}`)).run.messages.filter((x) => x.role === "assistant").pop();
  assert.equal(m.state, "stopped");
  assert.equal(m.error, undefined);
});

test("a turn's late close (a tool's orphan held stdout) doesn't end the next turn", async () => {
  const t = await spawnTask("orphan", "stub:orphan=7\nstub:report=ready-for-review");
  await waitFor(idle(t.taskId), 12000, "first turn ended by its exit");
  assert.equal((await api("POST", `/api/runs/${t.taskId}/followup`, { text: "stub:stall=6" })).ok, true);
  await new Promise((r) => setTimeout(r, 3500));
  assert.ok((await api("GET", "/api/state")).jobs.running.includes(t.taskId), "the second turn is still running after the first one's close");
  await waitFor(idle(t.taskId), 15000, "second turn ends");
});

test("bridge spawn --repo resolves a relative path from where it's run", async () => {
  const r = spawnSync(process.execPath, [path.join(ROOT, "bin", "bridge"), "spawn", "--repo", ".", "--title", "relative", "--brief", "x", "--no-start"], { env: ENV, cwd: REPO, encoding: "utf8" });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(meta(r.stdout.split(/\s/)[0]).repo, REPO);
});

test("a permission ask reaches the dashboard and the answer reaches the worker", async () => {
  const t = await spawnTask("asky", "stub:ask\nstub:report=ready-for-review");
  const ask = await waitFor(async () => {
    const r = (await api("GET", `/api/runs/${t.taskId}`)).run;
    return r && r.pendingAsk;
  }, 10000, "ask");
  const ans = await api("POST", `/api/runs/${t.taskId}/answer`, { askId: ask.id, behavior: "deny", message: "no force-push" });
  assert.equal(ans.ok, true);
  await waitFor(statusIs(t.taskId, "ready-for-review"), 15000);
});

test("a permission prompt is an Inbox item until answered; always allow sends the agent's rules", async () => {
  const t = await spawnTask("permy", "stub:ask=suggest\nstub:report=ready-for-review");
  const item = await waitFor(async () => (await api("GET", "/api/inbox")).permissions.find((p) => p.runId === t.taskId), 10000, "inbox item");
  assert.equal(item.tool, "Bash");
  assert.equal(item.command, "git push --force");
  assert.equal(item.always, true);
  assert.ok(item.title, "it names the chat");
  assert.ok((await api("GET", "/api/inbox")).counts.permissions >= 1);
  const ans = await api("POST", `/api/runs/${t.taskId}/answer`, { askId: item.askId, behavior: "allow", always: true });
  assert.equal(ans.ok, true);
  await waitFor(statusIs(t.taskId, "ready-for-review"), 15000);
  const run = (await api("GET", `/api/runs/${t.taskId}`)).run;
  assert.ok(JSON.stringify(run.messages).includes("answer: allow always: 1"), "the rules reached the agent");
  assert.ok(!(await api("GET", "/api/inbox")).permissions.some((p) => p.runId === t.taskId), "answered prompts leave the Inbox");
});

test("subagents and background commands become tasks, apart from the parent's steps", async () => {
  const t = await spawnTask("tasky", "stub:tasks\nstub:report=ready-for-review");
  await waitFor(statusIs(t.taskId, "ready-for-review"), 15000, "report");
  await waitFor(idle(t.taskId), 10000, "idle");
  const run = (await api("GET", `/api/runs/${t.taskId}`)).run;
  const m = run.messages.find((x) => x.role === "assistant" && x.tasks);
  assert.ok(m, "a message carries the tasks");
  const agent = m.tasks.find((x) => x.id === "a1");
  assert.equal(agent.type, "agent");
  assert.equal(agent.subagentType, "Explore");
  assert.equal(agent.status, "completed");
  assert.equal(agent.tokens, 1500);
  assert.equal(agent.summary, "Two files: a.txt, b.txt");
  assert.deepEqual(agent.steps.map((x) => x.kind), ["tool", "text"]);
  assert.equal(agent.steps[0].result, "a.txt\nb.txt");
  // The subagent's own `ls` is its step, not the parent's.
  assert.ok(!m.steps.some((x) => x.id === "tu-sub"));
  assert.ok(m.steps.some((x) => x.id === "tu-agent"));
  const bg = m.tasks.find((x) => x.id === "bg1");
  assert.equal(bg.type, "bash");
  assert.equal(bg.background, true);
  assert.equal(bg.command, "npm run build");
  assert.equal(bg.status, "completed");
  const out = await api("GET", `/api/runs/${t.taskId}/tasks/bg1/output`);
  assert.equal(out.text, "building...\ndone\n");
  assert.equal((await api("POST", `/api/runs/${t.taskId}/tasks/bg1/stop`)).status, 409, "a finished task can't be stopped");
  assert.equal((await api("GET", `/api/runs/${t.taskId}/tasks/nope/output`)).status, 404);
});

/** The app's Delta.apply (app/Sources/Bridge/Core.swift), for the test below. */
function applyDelta(d, run) {
  const m = [...run.messages].reverse().find((x) => x.id === d.msgId);
  if (!m) return false;
  const steps = (m.steps = m.steps || []);
  const at = (i) => (i >= 0 && i < steps.length ? steps[i] : null);
  if (d.blockStart) {
    if (d.blockStart.i === steps.length) steps.push(structuredClone(d.blockStart.step));
    else if (at(d.blockStart.i)) steps[d.blockStart.i] = structuredClone(d.blockStart.step);
    else return false;
  } else if (d.blockDelta) {
    const st = at(d.blockDelta.i);
    if (!st) return false;
    st.text = (st.text || "") + d.blockDelta.text;
  } else if (d.blockEnd) {
    const st = at(d.blockEnd.i);
    if (!st) return false;
    st.streaming = false;
  } else if (d.blockTokens) {
    const st = at(d.blockTokens.i);
    if (!st) return false;
    Object.assign(st, { tokens: d.blockTokens.tokens, approx: d.blockTokens.approx });
  } else if (d.blockDetail) {
    const st = at(d.blockDetail.i);
    if (!st) return false;
    st.detail = d.blockDetail.detail;
    if ("raw" in d.blockDetail) st.raw = d.blockDetail.raw;
  } else if (d.blockResult) {
    const st = at(d.blockResult.i);
    if (!st) return false;
    Object.assign(st, { result: d.blockResult.result, ok: d.blockResult.ok, resultLines: d.blockResult.resultLines });
  } else if (d.usage && !d.done) {
    m.usage = d.usage;
  } else return false;
  return true;
}

test("a chat fetched mid-stream plus the deltas after its seq equals the saved transcript", async () => {
  const controller = new AbortController();
  const res = await fetch(URL_ + "/api/events", { signal: controller.signal });
  const reader = res.body.getReader();
  const deltas = [];
  const reading = (async () => {
    const dec = new TextDecoder();
    let buf = "";
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        buf += dec.decode(value, { stream: true });
        let end;
        while ((end = buf.indexOf("\n\n")) >= 0) {
          const frame = buf.slice(0, end);
          buf = buf.slice(end + 2);
          if (frame.startsWith("event: delta\n")) deltas.push(JSON.parse(frame.split("\ndata: ")[1]));
        }
      }
    } catch (e) {
      if (!controller.signal.aborted) throw e;
    }
  })();
  try {
    const t = await spawnTask("streamy", "stub:stream=60\nstub:report=ready-for-review");
    const mine = () => deltas.filter((d) => d.runId === t.taskId);
    await waitFor(() => mine().some((d) => d.blockDelta), 10000, "the reply to start streaming");
    // What the app does on open: a snapshot, then every delta numbered after it.
    const snap = await api("GET", `/api/runs/${t.taskId}`);
    assert.equal(typeof snap.seq, "number");
    const local = snap.run;
    await waitFor(idle(t.taskId), 15000, "the turn to end");
    await new Promise((r) => setTimeout(r, 200));
    const after = mine().filter((d) => d.seq > snap.seq);
    assert.ok(after.length > 5, "the snapshot was taken mid-stream");
    assert.ok(mine().every((d, i, all) => i === 0 || d.seq > all[i - 1].seq), "deltas are numbered in order");
    for (const d of after) if (!d.done && !d.task && !d.blockAsk && !d.blockAskState) assert.ok(applyDelta(d, local), `applies ${Object.keys(d).join(",")}`);
    const saved = (await api("GET", `/api/runs/${t.taskId}`)).run;
    const reply = (run) => run.messages.find((x) => x.role === "assistant" && (x.steps || []).some((s) => s.id === "tu-stream"));
    const want = reply(saved), got = reply(local);
    assert.ok(want && got, "the streamed reply is in both");
    assert.deepEqual(got.steps, want.steps);
    assert.ok(want.steps[0].text.startsWith("tok0 tok1 ") && want.steps[0].text.includes("tok59 "));
    assert.equal(want.steps.find((s) => s.id === "tu-stream").result, "a.txt\nb.txt");
    // Context is the last call's prompt; the other fields sum both calls.
    assert.equal(want.usage.context, 9705);
    assert.equal(want.usage.cacheRead, 18500);
  } finally {
    controller.abort();
    await reading;
  }
});

test("workspaces: a worktree from any branch, or the main checkout, which cleanup leaves alone", async () => {
  git(["branch", "feature"]);
  git(["commit", "-q", "--allow-empty", "-m", "feature work"], REPO);
  git(["branch", "-f", "feature", "HEAD"]);
  git(["reset", "-q", "--hard", "HEAD~1"]);
  const proj = (await api("GET", "/api/projects")).projects.find((p) => p.path === REPO);
  const info = await api("GET", `/api/git?project=${proj.id}`);
  assert.equal(info.default, "main");
  assert.ok(info.branches.some((b) => b.name === "feature" && !b.remote));
  assert.ok(info.worktrees.some((w) => w.main && w.path === REPO));

  const t = await spawnTask("from feature", "stub:report=ready-for-review", { base: "feature" });
  assert.equal(git(["log", "-1", "--format=%s"], t.worktree), "feature work");
  assert.equal(meta(t.taskId).base, "feature");
  assert.equal((await api("POST", "/api/tasks", { repo: REPO, title: "x", brief: "x", base: "nope", start: false })).ok, false);

  const l = await spawnTask("in place", "stub:report=ready-for-review", { workspace: "local" });
  assert.equal(l.worktree, REPO);
  assert.equal(meta(l.taskId).adopted, "local");
  await waitFor(statusIs(l.taskId, "ready-for-review"), 15000, "report");
  await waitFor(idle(l.taskId), 10000, "idle");
  const c = await api("POST", `/api/tasks/${l.taskId}/cleanup`, {});
  assert.equal(c.ok, true, c.error);
  assert.ok(fs.existsSync(path.join(REPO, "README.md")), "the main checkout stays");
  git(["branch", "-D", "feature"]);
});

test("no cap: every task starts at once", async () => {
  const a = await spawnTask("cap a", "stub:stall=1\nstub:report=ready-for-review");
  const b = await spawnTask("cap b", "stub:stall=1\nstub:report=ready-for-review");
  const c = await spawnTask("cap c", "stub:report=ready-for-review");
  assert.deepEqual([a.state, b.state, c.state], ["started", "started", "started"]);
  await waitFor(statusIs(c.taskId, "ready-for-review"), 20000, "third task ran");
});

test("a stale running chat with no process behind it stops when asked", async () => {
  const t = await spawnTask("ghost", "stub:report=ready-for-review");
  await waitFor(statusIs(t.taskId, "ready-for-review"), 15000);
  await waitFor(idle(t.taskId), 5000, "idle");
  const file = path.join(DATA, "runs", `${t.taskId}.json`);
  const run = JSON.parse(fs.readFileSync(file, "utf8"));
  run.action = "running";
  run.messages.filter((m) => m.role === "assistant").pop().state = "running";
  fs.writeFileSync(file, JSON.stringify(run));
  assert.equal((await api("POST", `/api/runs/${t.taskId}/stop`)).ok, true);
  const after = (await api("GET", `/api/runs/${t.taskId}`)).run;
  assert.equal(after.action, "pending");
  assert.equal(after.messages.filter((m) => m.role === "assistant").pop().state, "stopped");
});

test("Slack replies filed into a chat reach its agent on the next turn, once", async () => {
  const t = await spawnTask("thread news", "stub:report=ready-for-review");
  await waitFor(statusIs(t.taskId, "ready-for-review"), 15000);
  await waitFor(idle(t.taskId), 5000, "idle");
  const file = path.join(DATA, "runs", `${t.taskId}.json`);
  const run = JSON.parse(fs.readFileSync(file, "utf8"));
  run.messages.push({ id: "slack-1.000001", ts: 1, role: "slack", who: "Cat", text: "it also breaks on XLSX", undelivered: true });
  fs.writeFileSync(file, JSON.stringify(run));
  assert.equal(cli("followup", t.taskId, "take a look").code, 0);
  await waitFor(() => fs.readFileSync(ENV.STUB_LOG, "utf8").includes("it also breaks on XLSX"), 10000, "slack news in the prompt");
  const prompt = fs.readFileSync(ENV.STUB_LOG, "utf8").split("\n").filter((l) => l.includes("it also breaks on XLSX")).map((l) => JSON.parse(l).prompt);
  assert.match(JSON.stringify(prompt), /\[slack\] New in the Slack thread/);
  const after = (await api("GET", `/api/runs/${t.taskId}`)).run;
  assert.ok(!after.messages.find((m) => m.id === "slack-1.000001").undelivered, "delivered once");
});

test("only a loopback Host gets an answer, GETs included", async () => {
  const http = require("http");
  const status = (host) => new Promise((resolve, reject) => http.get({ host: "127.0.0.1", port: PORT, path: "/api/runs", headers: { Host: host } }, (r) => resolve(r.statusCode)).on("error", reject));
  assert.equal(await status(`evil.example:${PORT}`), 403);
  assert.equal(await status(`127.0.0.1:${PORT}`), 200);
  // Another localhost port (a dev server in a browser tab) is another origin, reads included.
  const from = (origin, method = "GET", extra = {}) => fetch(`${URL_}/api/runs`, { method, headers: { Origin: origin, ...extra }, body: method === "POST" ? "{}" : undefined }).then((r) => r.status);
  assert.equal(await from("http://localhost:3000"), 403);
  assert.equal(await from("http://localhost:3000", "POST"), 403);
  assert.equal(await from("null"), 403);
  assert.equal(await from(`http://127.0.0.1:${PORT}`), 200);
  assert.equal((await fetch(`${URL_}/api/runs`, { headers: { "Sec-Fetch-Site": "cross-site" } })).status, 403);
  const bad = await fetch(`${URL_}/api/runs/%E0%A4%A`);
  assert.ok(bad.status >= 400 && bad.status < 600, "a malformed id is an error, not a crash");
  assert.equal((await fetch(`${URL_}/api/state`)).status, 200, "still up");
});

test("a follow-up sent mid-turn is queued and delivered after", async () => {
  const t = await spawnTask("busy", "stub:stall=1\nstub:report=ready-for-review");
  await waitFor(async () => (await api("GET", "/api/state")).jobs.running.includes(t.taskId), 5000);
  const r = cli("followup", t.taskId, "also handle the empty case");
  assert.equal(r.code, 0, r.err);
  assert.match(r.out, /queued/);
  await waitFor(async () => {
    const run = (await api("GET", `/api/runs/${t.taskId}`)).run;
    return run.messages.some((m) => m.role === "user" && m.text === "also handle the empty case");
  }, 15000, "delivered");
});

const running = (id) => async () => (await api("GET", "/api/state")).jobs.running.includes(id);
const replies = async (id) => (await api("GET", `/api/runs/${id}`)).run.messages.filter((m) => m.role === "assistant");

test("a steer lands in the running turn, read at its next step", async () => {
  const t = await spawnTask("steery", "stub:stall=2\nstub:report=ready-for-review");
  await waitFor(running(t.taskId), 5000, "running");
  const r = await api("POST", `/api/runs/${t.taskId}/followup`, { text: "also mind the empty case", mode: "steer" });
  assert.equal(r.steered, true);
  await waitFor(idle(t.taskId), 15000, "turn ends");
  const all = await replies(t.taskId);
  assert.equal(all.length, 1, "no extra turn");
  const m = all[0];
  assert.equal(m.state, "done");
  assert.deepEqual(m.steps.find((s) => s.kind === "steer"), { kind: "steer", text: "also mind the empty case", state: "read" });
  const said = fs.readFileSync(ENV.STUB_LOG, "utf8").trim().split("\n").map(JSON.parse).filter((l) => l.prompt === "also mind the empty case");
  assert.equal(said.length, 1, "written to the session once");
  const argv = fs.readFileSync(ENV.STUB_LOG, "utf8").trim().split("\n").map(JSON.parse).filter((l) => l.argv && l.env.BRIDGE_TASK_ID === t.taskId)[0].argv;
  assert.ok(argv.includes("--replay-user-messages"));
});

test("a steer read only after the turn's result keeps the turn open for it", async () => {
  const t = await spawnTask("late-steer", "stub:stream=120");
  await waitFor(running(t.taskId), 5000, "running");
  assert.equal((await api("POST", `/api/runs/${t.taskId}/followup`, { text: "one more thing", mode: "steer" })).steered, true);
  await waitFor(idle(t.taskId), 20000, "turn ends");
  const all = await replies(t.taskId);
  assert.equal(all.length, 1, "the steer's turn is part of this reply");
  assert.equal(all[0].state, "done");
  assert.equal(all[0].turns, 2, "both results counted");
  assert.equal(all[0].steps.find((s) => s.kind === "steer").state, "read");
});

test("queued messages: listed, edited, removed, then each runs as its own turn", async () => {
  const t = await spawnTask("queuey", "stub:stall=3\nstub:report=ready-for-review");
  await waitFor(running(t.taskId), 5000, "running");
  const a = await api("POST", `/api/runs/${t.taskId}/followup`, { text: "first queued", mode: "queue" });
  const b = await api("POST", `/api/runs/${t.taskId}/followup`, { text: "second queued", mode: "queue" });
  const c = await api("POST", `/api/runs/${t.taskId}/followup`, { text: "third queued", mode: "queue" });
  assert.equal(a.queued && b.queued && c.queued, true, JSON.stringify([a, b, c]));
  assert.deepEqual((await api("GET", `/api/runs/${t.taskId}`)).queue.map((q) => q.text), ["first queued", "second queued", "third queued"]);
  assert.equal((await api("POST", `/api/runs/${t.taskId}/queue/${b.id}`, { text: "second, edited" })).ok, true);
  assert.equal((await api("DELETE", `/api/runs/${t.taskId}/queue/${a.id}`)).ok, true);
  assert.equal((await api("DELETE", `/api/runs/${t.taskId}/queue/${a.id}`)).ok, false, "already gone");
  assert.deepEqual((await api("GET", `/api/runs/${t.taskId}`)).queue.map((q) => q.text), ["second, edited", "third queued"]);
  await waitFor(async () => {
    const run = (await api("GET", `/api/runs/${t.taskId}`)).run;
    return run.messages.some((m) => m.role === "user" && m.text === "third queued");
  }, 30000, "both delivered");
  const users = (await api("GET", `/api/runs/${t.taskId}`)).run.messages.filter((m) => m.role === "user").map((m) => m.text).slice(1);
  assert.deepEqual(users, ["second, edited", "third queued"], "one turn each, the removed one never sent");
  await waitFor(idle(t.taskId), 15000, "idle");
});

test("interrupt and send stops the turn, then sends in the same chat", async () => {
  const t = await spawnTask("interrupty", "stub:stall=30");
  await waitFor(running(t.taskId), 5000, "running");
  const q = await api("POST", `/api/runs/${t.taskId}/followup`, { text: "keep me queued", mode: "queue" });
  const r = await api("POST", `/api/runs/${t.taskId}/queue/${q.id}/send`);
  assert.equal(r.interrupted, true);
  await waitFor(async () => (await api("GET", `/api/runs/${t.taskId}`)).run.messages.some((m) => m.role === "user" && m.text === "keep me queued"), 15000, "sent after the stop");
  const all = await replies(t.taskId);
  assert.equal(all[0].state, "stopped");
  assert.equal(all.length, 2, "a new turn started");
  assert.deepEqual((await api("GET", `/api/runs/${t.taskId}`)).queue, [], "sent from the queue, not twice");
  await api("POST", `/api/runs/${t.taskId}/stop`);
  await waitFor(idle(t.taskId), 10000, "idle");
});

test("cleanup refuses unpushed work, removes with --force, keeps the branch", async () => {
  const t = await spawnTask("committer", "stub:report=ready-for-review");
  await waitFor(statusIs(t.taskId, "ready-for-review"), 15000);
  await waitFor(idle(t.taskId), 5000);
  fs.writeFileSync(path.join(t.worktree, "new.txt"), "x\n");
  git(["add", "."], t.worktree);
  git(["commit", "-q", "-m", "local only"], t.worktree);

  const refused = cli("cleanup", t.taskId);
  assert.equal(refused.code, 3);
  assert.match(refused.err, /unpushed/);
  assert.ok(fs.existsSync(t.worktree));

  const forced = cli("cleanup", t.taskId, "--force");
  assert.equal(forced.code, 0, forced.err);
  assert.ok(!fs.existsSync(t.worktree));
  assert.equal(git(["rev-parse", "--verify", "--quiet", `refs/heads/${t.branch}`]).length > 0, true, "branch kept");

  // A pushed, clean worktree goes without --force.
  const u = await spawnTask("pusher", "stub:report=ready-for-review");
  await waitFor(statusIs(u.taskId, "ready-for-review"), 15000);
  await waitFor(idle(u.taskId), 5000);
  assert.equal(cli("cleanup", u.taskId).code, 0);

  // Cleaning up takes the task's to-dos and decisions out of the Inbox.
  const inbox = await api("GET", "/api/inbox");
  assert.deepEqual([...inbox.decisions, ...inbox.todos].filter((x) => x.taskId === t.taskId || x.taskId === u.taskId), []);
});

test("modes: quiet takes the recommended option and stays silent; away relays everything to the orchestrator", async () => {
  // Outcomes go to the orchestrator of the task's project (the scratch repo's).
  const first = await spawnTask("modes warm-up", "stub:report=ready-for-review", { by: "orchestrator" });
  await waitFor(statusIs(first.taskId, "ready-for-review"), 15000);
  const orch = `orchestrator-${(await api("GET", "/api/projects")).projects.find((p) => p.path === REPO).id}`;
  const relays = async () => ((await api("GET", `/api/runs/${orch}`)).run || { messages: [] }).messages.filter((m) => m.role === "relay").length;
  await waitFor(async () => (await relays()) > 0, 10000, "normal relays (a check that can fail)");
  await waitFor(idle(orch), 10000, "orchestrator idle");

  assert.equal((await api("POST", "/api/mode", { mode: "quiet" })).ok, true);
  const before = await relays();
  const q = await spawnTask("quiet ok", "stub:report=ready-for-review", { by: "orchestrator" });
  await waitFor(statusIs(q.taskId, "ready-for-review"), 15000);
  await new Promise((r) => setTimeout(r, 800));
  assert.equal(await relays(), before, "a plain ready report is not relayed in quiet mode");

  // A question with a recommended option is answered by Bridge, logged to the digest, not relayed.
  const r = await spawnTask("quiet pick", "stub:report=needs-input\nstub:question=Rate limit per user or per IP?\\nA) Per user\\nB) Per IP (recommended)", { by: "orchestrator" });
  const answered = await waitFor(async () => {
    let all = [];
    try {
      all = JSON.parse(fs.readFileSync(path.join(DATA, "tasks", "decisions.json"), "utf8"));
    } catch {}
    return all.find((d) => d.taskId === r.taskId && d.kind === "question" && d.state === "answered");
  }, 15000, "auto answer");
  assert.equal(answered.answer, "B) Per IP");
  assert.equal(answered.by, "auto");
  const inbox = await api("GET", "/api/inbox");
  assert.equal(inbox.decisions.filter((d) => d.taskId === r.taskId).length, 0, "nothing of it waits on you");
  const digest = await waitFor(async () => (await api("GET", "/api/inbox")).decisions.find((d) => d.kind === "digest" && /B\) Per IP/.test(d.text)), 5000, "digest");
  assert.match(digest.question, /Handled for you in quiet mode/);
  await new Promise((r2) => setTimeout(r2, 800));
  assert.equal(await relays(), before, "an auto-answered question is not relayed in quiet mode");

  // merge: refused outside quiet/away rules; normal never merges. log: one digest item, rewritten.
  assert.match(cli("merge", r.taskId).err, /refusing to merge: quiet mode merges only where the project allows/);
  assert.equal(cli("log", "kept the old API name").code, 0);
  const digests = (await api("GET", "/api/inbox")).decisions.filter((d) => d.kind === "digest");
  assert.equal(digests.length, 1, "one digest, not one item per action");
  assert.match(digests[0].text, /kept the old API name/);

  // Away: every outcome goes to the orchestrator, and its next turn carries the away lines once.
  await waitFor(idle(orch), 10000, "orchestrator idle");
  assert.equal((await api("POST", "/api/mode", { mode: "away" })).ok, true);
  const w = await spawnTask("away ok", "stub:report=ready-for-review", { by: "orchestrator" });
  await waitFor(statusIs(w.taskId, "ready-for-review"), 15000);
  await waitFor(async () => (await relays()) > before, 10000, "relayed while away");
  await waitFor(idle(orch), 10000, "orchestrator idle");
  const prompts = fs.readFileSync(ENV.STUB_LOG, "utf8").trim().split("\n").map(JSON.parse).filter((l) => l.prompt && l.prompt.includes(`OUTCOME report · task ${w.taskId}`));
  assert.match(prompts[0].prompt, /\(Bridge: the relay mode changed\.\nMode: away\./);
  assert.ok(!/Mode: (normal|quiet)/.test(prompts[0].prompt), "only the active mode's lines");
  const sys = fs.readFileSync(path.join(DATA, "tasks", `${orch}.system.md`), "utf8");
  assert.match(sys, /## Mode\n\nMode: away\./);
  assert.ok(!/Mode: (normal|quiet)\./.test(sys));

  assert.equal((await api("POST", "/api/mode", { mode: "normal" })).ok, true);
  assert.match(cli("merge", w.taskId).err, /refusing to merge: normal mode/);
  // Dismissing the digest closes it; the next entry opens a fresh one.
  await api("POST", `/api/decisions/${digests[0].id}`, { action: "dismiss" });
  assert.equal((await api("GET", "/api/inbox")).decisions.filter((d) => d.kind === "digest").length, 0);
});

test("a report rewritten with nothing new isn't relayed again; a new status is", async () => {
  const t = await spawnTask("dedupe", "stub:report=ready-for-review", { by: "orchestrator" });
  const orch = `orchestrator-${(await api("GET", "/api/projects")).projects.find((p) => !p.root).id}`;
  const relays = async () => (((await api("GET", `/api/runs/${orch}`)).run || {}).messages || []).filter((m) => m.role === "relay" && m.text.includes(t.taskId)).length;
  await waitFor(async () => (await relays()) === 1, 15000, "first relay");
  await waitFor(idle(orch), 15000, "orchestrator idle");

  // Same status, TL;DR and asks, different body: an OUTCOME, but no relay turn.
  const hash = meta(t.taskId).reportHash;
  assert.equal((await api("POST", `/api/runs/${t.taskId}/followup`, { text: "stub:note=Again." })).ok, true);
  await waitFor(() => meta(t.taskId).reportHash !== hash, 15000, "rewritten report seen");
  await new Promise((r) => setTimeout(r, 800));
  assert.equal(await relays(), 1, "rewritten report not relayed");

  assert.equal((await api("POST", `/api/runs/${t.taskId}/followup`, { text: "stub:report=blocked" })).ok, true);
  await waitFor(async () => (await relays()) === 2, 15000, "new status relayed");
});

test("restart: a worker lost mid-turn is reported and resumable; reports written while down are caught up", async () => {
  const lost = await spawnTask("long", "stub:stall=60");
  await waitFor(async () => (await api("GET", "/api/state")).jobs.running.includes(lost.taskId), 5000);
  const quiet = await spawnTask("offline report", "stub:noreport\nstub:edit");
  await waitFor(statusIs(quiet.taskId, "idle-without-report"), 15000);

  await stopServer();
  fs.writeFileSync(path.join(DATA, "tasks", quiet.taskId, "report.md"), "---\nstatus: blocked\n---\n## TL;DR\nWritten while the dashboard was down.\n");
  await startServer();

  await waitFor(statusIs(lost.taskId, "worker-gone"), 5000, "lost → gone");
  await waitFor(statusIs(quiet.taskId, "blocked"), 5000, "caught up");
  const d = (await api("GET", "/api/inbox")).decisions.find((x) => x.taskId === lost.taskId && x.kind === "resume");
  assert.ok(d, "resume decision");
  assert.equal(cli("relaunch", lost.taskId).code, 0);
  await waitFor(statusIs(lost.taskId, "ready-for-review"), 15000, "resumed → report");
});

test("deleting a chat clears its to-dos and decisions", async () => {
  const mine = async (id) => {
    const i = await api("GET", "/api/inbox");
    return [...i.decisions, ...i.todos].filter((x) => x.taskId === id);
  };
  const done = await spawnTask("delete me", "stub:report=ready-for-review\nstub:you=Merge it");
  const asking = await spawnTask("delete me too", "stub:report=needs-input\nstub:question=Keep it?");
  await waitFor(statusIs(done.taskId, "ready-for-review"), 15000);
  await waitFor(statusIs(asking.taskId, "needs-input"), 15000);
  await waitFor(idle(done.taskId), 5000);
  await waitFor(idle(asking.taskId), 5000);
  assert.equal((await mine(done.taskId)).length, 1, "For you to-do");
  assert.ok((await mine(asking.taskId)).length >= 1, "open decision");

  assert.equal((await api("DELETE", `/api/runs/${done.taskId}`)).ok, true);
  assert.deepEqual(await mine(done.taskId), []);
  assert.equal(meta(done.taskId).status, "deleted");
  assert.ok(fs.existsSync(done.worktree), "worktree left for bridge cleanup");
  assert.ok(!(await api("GET", "/api/tasks")).tasks.some((t) => t.id === done.taskId), "gone from bridge status");

  assert.equal((await api("DELETE", `/api/runs/${asking.taskId}`)).ok, true);
  assert.deepEqual(await mine(asking.taskId), []);
  assert.equal(meta(asking.taskId).status, "deleted");
});

test("archiving a chat clears its Inbox items and hides it; unarchiving brings it back", async () => {
  const mine = async (id) => {
    const i = await api("GET", "/api/inbox");
    return [...i.decisions, ...i.todos].filter((x) => x.taskId === id);
  };
  const summary = async (id) => (await api("GET", "/api/runs")).runs.find((r) => r.runId === id);
  const t = await spawnTask("archive me", "stub:report=ready-for-review\nstub:you=Merge it");
  await waitFor(statusIs(t.taskId, "ready-for-review"), 15000);
  await waitFor(idle(t.taskId), 5000);
  assert.equal((await mine(t.taskId)).length, 1, "For you to-do");

  assert.equal((await api("POST", `/api/runs/${t.taskId}/archive`, {})).archived, true);
  assert.deepEqual(await mine(t.taskId), []);
  assert.equal((await summary(t.taskId)).archived, true, "the chat is kept, marked archived");
  assert.ok(!(await api("GET", "/api/tasks")).tasks.some((x) => x.id === t.taskId), "out of bridge status");
  assert.ok(!(await api("GET", "/api/sessions")).sessions.some((x) => x.id === t.taskId), "out of the roster");
  assert.equal(meta(t.taskId).status, "ready-for-review", "status kept");

  assert.equal((await api("POST", `/api/runs/${t.taskId}/archive`, { archived: false })).archived, false);
  assert.equal((await summary(t.taskId)).archived, false);
  assert.ok((await api("GET", "/api/tasks")).tasks.some((x) => x.id === t.taskId), "back in bridge status");
  assert.equal((await api("POST", "/api/runs/orchestrator/archive", {})).status, 409, "the orchestrator stays");
});

test("worktrees live at <repo>-worktrees/<branch minus user/>; a taken name moves on to -2", async () => {
  const WT = ENV.WORKTREE_ROOT;
  const named = await spawnTask("named", "x", { branch: "george-mercor/foo", start: false });
  assert.equal(named.worktree, path.join(WT, "foo"));
  assert.equal(named.branch, "george-mercor/foo");
  assert.equal(git(["rev-parse", "--abbrev-ref", "HEAD"], named.worktree), "george-mercor/foo");

  // A named branch must be free; only its folder moves on when one is in the way.
  assert.equal((await api("POST", "/api/tasks", { repo: REPO, title: "x", brief: "x", branch: "george-mercor/foo", start: false })).ok, false);
  const other = await spawnTask("other user", "x", { branch: "someone/foo", start: false });
  assert.equal(other.worktree, path.join(WT, "foo-2"));

  // Bridge's own names: `<prefix>/<slug>`, no random suffix; a repeat title takes -2 for both.
  const a = await spawnTask("Same Title", "x", { start: false });
  const b = await spawnTask("Same Title", "x", { start: false });
  assert.deepEqual([a.branch, a.worktree], ["test/same-title", path.join(WT, "same-title")]);
  assert.deepEqual([b.branch, b.worktree], ["test/same-title-2", path.join(WT, "same-title-2")]);
});

test("archive can delete the worktree Bridge made: refuses on unpushed work unless forced, keeps the chat and branch", async () => {
  const summary = async (id) => (await api("GET", "/api/runs")).runs.find((r) => r.runId === id);
  const clean = await spawnTask("archive and delete", "x", { start: false });
  const pre = await api("GET", `/api/runs/${clean.taskId}/archive`);
  assert.equal(pre.worktree.owned, true);
  assert.equal(pre.worktree.path, clean.worktree);
  const out = await api("POST", `/api/runs/${clean.taskId}/archive`, { deleteWorktree: true });
  assert.equal(out.ok, true, out.error);
  assert.equal(out.worktree.removed, true);
  assert.ok(!fs.existsSync(clean.worktree), "worktree deleted");
  assert.ok(git(["rev-parse", "--verify", "--quiet", `refs/heads/${clean.branch}`]), "branch kept");
  assert.equal((await summary(clean.taskId)).archived, true, "the chat is kept");
  assert.equal((await api("GET", `/api/runs/${clean.taskId}/archive`)).worktree.owned, false, "nothing left to delete");
  // Unarchiving a chat whose worktree is gone still works and its transcript loads.
  assert.equal((await api("POST", `/api/runs/${clean.taskId}/archive`, { archived: false })).archived, false);
  assert.ok((await api("GET", `/api/runs/${clean.taskId}`)).run.messages.length > 0);

  // Uncommitted and unpushed work: refused, nothing archived or deleted, until forced.
  const dirty = await spawnTask("archive dirty", "x", { start: false });
  fs.writeFileSync(path.join(dirty.worktree, "a.txt"), "a\n");
  git(["add", "."], dirty.worktree);
  git(["commit", "-q", "-m", "local only"], dirty.worktree);
  fs.writeFileSync(path.join(dirty.worktree, "b.txt"), "b\n");
  const st = (await api("GET", `/api/runs/${dirty.taskId}/archive`)).worktree;
  assert.deepEqual([st.owned, st.dirty, st.dirtyFiles, st.unpushed], [true, true, 1, 1]);
  const refused = await api("POST", `/api/runs/${dirty.taskId}/archive`, { deleteWorktree: true });
  assert.equal(refused.status, 409);
  assert.equal(refused.refused, true);
  assert.ok(fs.existsSync(dirty.worktree), "worktree kept");
  assert.ok(!(await summary(dirty.taskId)).archived, "not archived either");
  const forced = await api("POST", `/api/runs/${dirty.taskId}/archive`, { deleteWorktree: true, force: true });
  assert.equal(forced.ok, true, forced.error);
  assert.ok(!fs.existsSync(dirty.worktree));
  assert.equal((await summary(dirty.taskId)).archived, true);

  // A checkout Bridge didn't make (the main checkout) is never offered or deleted.
  const local = await spawnTask("archive local", "x", { workspace: "local", start: false });
  const lst = (await api("GET", `/api/runs/${local.taskId}/archive`)).worktree;
  assert.equal(lst.owned, false);
  assert.match(lst.reason, /main checkout/);
  assert.equal((await api("POST", `/api/runs/${local.taskId}/archive`, { deleteWorktree: true })).archived, true);
  assert.ok(fs.existsSync(path.join(REPO, "README.md")), "the main checkout stays");
});

test("bridge archive|unarchive|stop|rename: an orchestrator's, within its scope; archive deletes only a safe worktree", async () => {
  const proj = (await api("GET", "/api/projects")).projects.find((p) => p.path === REPO);
  const orchId = (await api("POST", `/api/projects/${proj.id}/orchestrator`, {})).runId;
  const defaultOrch = (await api("POST", "/api/projects/default/orchestrator", {})).runId;
  const other = path.join(tmp, "other-repo");
  fs.mkdirSync(other, { recursive: true });
  git(["init", "-q", "-b", "main"], other);
  const otherProj = (await api("POST", "/api/projects", { path: other })).project;
  const otherOrch = (await api("POST", `/api/projects/${otherProj.id}/orchestrator`, {})).runId;
  const as = (role, id, ...args) => {
    const r = spawnSync(process.execPath, [path.join(ROOT, "bin", "bridge"), ...args], { env: { ...ENV, BRIDGE_ROLE: role, BRIDGE_TASK_ID: id }, encoding: "utf8" });
    return { code: r.status, out: r.stdout, err: r.stderr };
  };
  const summary = async (id) => (await api("GET", "/api/runs")).runs.find((r) => r.runId === id);

  const t = await spawnTask("orchestrated chat", "x", { start: false });
  // A worker can't; another project's orchestrator can't; nor can one act on itself or another orchestrator.
  assert.match(as("task", t.taskId, "archive", t.taskId).err, /orchestrator's/);
  const far = as("orchestrator", otherOrch, "archive", t.taskId);
  assert.notEqual(far.code, 0);
  assert.match(far.err, /outside this orchestrator's/);
  assert.match(as("orchestrator", otherOrch, "stop", t.taskId).err, /outside/);
  assert.match(as("orchestrator", otherOrch, "rename", t.taskId, "nope").err, /outside/);
  assert.match(as("orchestrator", orchId, "archive", orchId).err, /its own chat/);
  assert.match(as("orchestrator", orchId, "archive", defaultOrch).err, /another orchestrator/);
  assert.equal((await api("POST", `/api/runs/${t.taskId}/archive`, { by: t.taskId })).status, 403, "`by` must be an orchestrator");
  assert.ok(!(await summary(t.taskId)).archived);

  // Rename: its project's orchestrator and the default one (every project) both can.
  let r = as("orchestrator", orchId, "rename", t.taskId, "Renamed", "by", "orchestrator");
  assert.equal(r.code, 0, r.err);
  assert.equal((await summary(t.taskId)).task.title, "Renamed by orchestrator");
  assert.equal(as("orchestrator", defaultOrch, "rename", t.taskId, "Renamed again").code, 0);
  assert.equal((await summary(t.taskId)).task.title, "Renamed again");

  // Archive with --delete-worktree refuses on uncommitted work (no force from an orchestrator).
  fs.writeFileSync(path.join(t.worktree, "wip.txt"), "wip\n");
  r = as("orchestrator", orchId, "archive", t.taskId, "--delete-worktree");
  assert.equal(r.code, 3, r.err);
  assert.match(r.err, /refusing/);
  assert.equal((await api("POST", `/api/runs/${t.taskId}/archive`, { by: orchId, deleteWorktree: true, force: true })).status, 409, "force is the app's");
  assert.ok(fs.existsSync(t.worktree), "worktree kept");
  assert.ok(!(await summary(t.taskId)).archived, "not archived either");
  fs.rmSync(path.join(t.worktree, "wip.txt"));
  r = as("orchestrator", orchId, "archive", t.taskId, "--delete-worktree");
  assert.equal(r.code, 0, r.err);
  assert.match(r.out, /archived; worktree removed/);
  assert.ok(!fs.existsSync(t.worktree), "worktree removed");
  assert.ok(git(["rev-parse", "--verify", "--quiet", `refs/heads/${t.branch}`]), "branch kept");
  assert.equal((await summary(t.taskId)).archived, true, "the chat is kept, archived");
  r = as("orchestrator", orchId, "unarchive", t.taskId);
  assert.equal(r.code, 0, r.err);
  assert.equal((await summary(t.taskId)).archived, false);

  // Stop ends a running turn.
  const live = await spawnTask("long turn", "stub:stall=20");
  await waitFor(async () => (await api("GET", "/api/state")).jobs.running.includes(live.taskId), 10000, "running");
  r = as("orchestrator", orchId, "stop", live.taskId);
  assert.equal(r.code, 0, r.err);
  assert.match(r.out, /stopped/);
  await waitFor(idle(live.taskId), 10000, "stopped");
});

test("bridge plan: a worker's task list, set, ticked and shown on its session", async () => {
  const t = await spawnTask("planny", "stub:report=ready-for-review");
  await waitFor(statusIs(t.taskId, "ready-for-review"), 15000, "report");
  const plan = (op, ...args) => api("POST", `/api/tasks/${t.taskId}/plan`, { op, args });
  assert.strictEqual((await plan("set", "Reproduce", "Fix", "Test")).plan.length, 3);
  await plan("start", 1);
  await plan("done", 1);
  await plan("start", 2);
  await plan("add", "Write it up");
  const p = (await plan("skip", 4)).plan;
  assert.deepStrictEqual(p.map((x) => x.status), ["completed", "in_progress", "pending", "cancelled"]);
  assert.strictEqual((await plan("done", 9)).status, 400, "an item that isn't there");
  const summary = (await api("GET", "/api/runs")).runs.find((r) => r.runId === t.taskId);
  assert.deepStrictEqual(summary.task.plan.map((x) => x.text), ["Reproduce", "Fix", "Test", "Write it up"]);
});
