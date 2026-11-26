/**
 * The worker skill (WORKER_SKILL, default `fetch`) and the orchestrator's
 * session roster, against a real dashboard, a scratch repo, a scratch
 * ~/.claude (CLAUDE_CONFIG_DIR) holding a fake `fetch` skill, and the stub
 * agent. Nothing here touches the real data/ or the real ~/.claude.
 */

const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawn, execFileSync, spawnSync } = require("child_process");

const ROOT = path.join(__dirname, "..");
const tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "sb-fetch-")));
const DATA = path.join(tmp, "data");
const REPO = path.join(tmp, "repo");
const HOME_CLAUDE = path.join(tmp, "claude-home");
const PORT = 45000 + Math.floor(Math.random() * 1500);
const URL_ = `http://127.0.0.1:${PORT}`;
const LINEAR = "https://linear.app/acme/issue/ABC-12/fix-the-export";
const SLACK = "https://acme.slack.com/archives/C0123ABCD/p1784615086259089";

const SKILL = `---
name: fetch
description: Fake fetch skill for the tests.
argument-hint: <linear-issue-url | slack-thread-url>
---

# Fetch Skill
Work on $ARGUMENTS end to end.
`;

const git = (args, cwd = REPO) => execFileSync("git", args, { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();

const ENV = {
  ...process.env,
  SB_DATA_DIR: DATA,
  CLAUDE_BIN: path.join(__dirname, "stub-claude.js"),
  CLAUDE_CONFIG_DIR: HOME_CLAUDE,
  BRIDGE_PORT: String(PORT),
  BRIDGE_ENV_FILE: path.join(tmp, "none.env"),
  TARGET_REPO: REPO,
  WORKTREE_ROOT: path.join(tmp, "wt"),
  SLACK_USER_NAME: "Alex",
  SLACK_USER_TOKEN: "",
  LINEAR_API_KEY: "",
  BRANCH_PREFIX: "test",
  WORKER_SKILL: "",
  STUB_LOG: path.join(tmp, "stub.log"),
  SB_URL: URL_,
  SB_TASK_ID: "",
  SB_ROLE: "",
};

let server;
async function api(method, p, body) {
  const r = await fetch(URL_ + p, { method, headers: body ? { "Content-Type": "application/json" } : {}, body: body ? JSON.stringify(body) : undefined });
  return { status: r.status, ...(await r.json().catch(() => ({}))) };
}
async function waitFor(fn, ms = 15000, what = "condition") {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    const v = await fn();
    if (v) return v;
    await new Promise((r) => setTimeout(r, 150));
  }
  throw new Error(`timed out waiting for ${what}`);
}
const stubLog = () => (fs.existsSync(ENV.STUB_LOG) ? fs.readFileSync(ENV.STUB_LOG, "utf8").trim().split("\n").filter(Boolean).map(JSON.parse) : []);
const promptOf = (id) => waitFor(() => (stubLog().find((l) => l.prompt != null && l.env.SB_TASK_ID === id) || {}).prompt, 10000, `prompt for ${id}`);
const idle = (id) => async () => !(await api("GET", "/api/state")).jobs.running.includes(id);
async function spawnTask(title, brief) {
  const r = await api("POST", "/api/tasks", { repo: REPO, title, brief });
  assert.equal(r.ok, true, r.error);
  return r;
}

test.before(async () => {
  fs.mkdirSync(REPO, { recursive: true });
  git(["init", "-q", "-b", "main"]);
  git(["config", "user.email", "t@example.com"]);
  git(["config", "user.name", "t"]);
  git(["config", "commit.gpgsign", "false"]);
  fs.writeFileSync(path.join(REPO, "README.md"), "scratch\n");
  git(["add", "."]);
  git(["commit", "-q", "-m", "init"]);
  fs.mkdirSync(path.join(HOME_CLAUDE, "skills", "fetch"), { recursive: true });
  fs.writeFileSync(path.join(HOME_CLAUDE, "skills", "fetch", "SKILL.md"), SKILL);
  fs.mkdirSync(DATA, { recursive: true });
  fs.writeFileSync(path.join(DATA, "config.json"), JSON.stringify({ harness: { maxWorkers: 5, maxPerRepo: 5, relay: false, mode: "normal" } }));
  server = spawn(process.execPath, [path.join(ROOT, "index.js")], { env: ENV, stdio: ["ignore", "pipe", "pipe"] });
  server.stderr.on("data", (d) => process.env.SB_TEST_VERBOSE && process.stderr.write(d));
  await waitFor(async () => fetch(`${URL_}/api/state`).then((r) => r.ok).catch(() => false), 10000, "server up");
});
test.after(async () => {
  if (server) await new Promise((r) => (server.on("exit", r), server.kill("SIGTERM")));
  fs.rmSync(tmp, { recursive: true, force: true });
});

test("a worker from a Linear brief starts with /fetch <issue url>, Bridge's rules after it", async () => {
  const st = await api("GET", "/api/state");
  assert.deepEqual({ name: st.workerSkill.name, installed: st.workerSkill.installed }, { name: "fetch", installed: true });

  const t = await spawnTask("ABC-12 Fix the export", `Linear issue ABC-12: Fix the export\n${LINEAR}\n\nRead the issue.\nstub:report=ready-for-review`);
  const prompt = await promptOf(t.taskId);
  assert.ok(prompt.startsWith(`/fetch ${LINEAR}\n\n`), prompt.slice(0, 200));
  assert.match(prompt, /## Bridge \(applies on top of the skill\)/);
  assert.ok(prompt.includes(path.join(DATA, "tasks", t.taskId, "report.md")), "report path in the rules");
  assert.ok(prompt.includes(t.worktree), "worktree in the rules");
  await waitFor(idle(t.taskId), 15000, "worker idle");
  const run = await api("GET", `/api/runs/${t.taskId}`);
  const r = run.run || run;
  assert.equal(r.linearUrl, LINEAR);
  assert.ok(r.messages.some((m) => m.role === "event" && /with \/fetch/.test(m.text)), "spawned note names the skill");
});

test("a brief without a link is the skill's argument", async () => {
  const t = await spawnTask("tidy the readme", "Tidy the README wording.\nstub:report=ready-for-review");
  const prompt = await promptOf(t.taskId);
  assert.ok(prompt.startsWith("/fetch Tidy the README wording."), prompt.slice(0, 120));
  await waitFor(idle(t.taskId), 15000, "worker idle");
});

test("a Slack thread pipeline runs /fetch on the thread, with the closing verdict", async () => {
  const r = await api("POST", "/api/runs", { url: SLACK, start: true });
  assert.equal(r.ok, true, r.error);
  assert.equal(r.started, true);
  const prompt = await promptOf(r.runId);
  assert.ok(prompt.startsWith(`/fetch ${SLACK}\n\n`), prompt.slice(0, 200));
  assert.match(prompt, /"action":"acted"/);
  assert.match(prompt, /scripts\/emit\.sh/);
  await waitFor(idle(r.runId), 15000, "pipeline idle");
});

test("WORKER_SKILL off or missing falls back to the built-in prompt", async () => {
  await api("POST", "/api/config", { harness: { workerSkill: "none" } });
  const off = await spawnTask("off", "Nothing fancy.\nstub:report=ready-for-review");
  assert.match(await promptOf(off.taskId), /^Read \S+brief\.md and begin/);
  await waitFor(idle(off.taskId), 15000, "idle");

  await api("POST", "/api/config", { harness: { workerSkill: "no-such-skill" } });
  const miss = await spawnTask("missing", "Nothing fancy.\nstub:report=ready-for-review");
  assert.match(await promptOf(miss.taskId), /^Read \S+brief\.md and begin/);
  await waitFor(idle(miss.taskId), 15000, "idle");
  const run = await api("GET", `/api/runs/${miss.taskId}`);
  assert.ok((run.run || run).messages.some((m) => /no-such-skill not installed/.test(m.text || "")));

  await api("POST", "/api/config", { harness: { workerSkill: "" } });
  assert.equal((await api("GET", "/api/state")).workerSkill.name, "fetch");
});

test("the orchestrator's prompt carries the roster of every session, rebuilt each turn", async () => {
  const before = await api("GET", "/api/sessions");
  const t = before.sessions.find((s) => s.linearKey === "ABC-12");
  assert.ok(t, "the Linear task is in /api/sessions");
  assert.ok(t.transcript.endsWith(`${t.id}.json`));
  assert.ok(t.report.endsWith("report.md"));

  const f = await api("POST", "/api/runs/orchestrator/followup", { text: "what's going on?" });
  assert.equal(f.ok, true, f.error);
  await waitFor(idle("orchestrator"), 15000, "orchestrator idle");
  const line = stubLog().filter((l) => l.argv && l.env.SB_TASK_ID === "orchestrator").pop();
  const sys = fs.readFileSync(line.argv[line.argv.indexOf("--append-system-prompt-file") + 1], "utf8");
  assert.match(sys, /## Every session in all projects/);
  for (const s of before.sessions.filter((x) => x.id !== "orchestrator")) assert.ok(sys.includes(`\`${s.id}\``), `roster lists ${s.id}`);
  assert.ok(sys.includes(t.transcript), "transcript path");
  assert.ok(sys.includes(LINEAR), "Linear link");
  assert.ok(fs.existsSync(path.join(DATA, "tasks", "orchestrator.sessions.md")));

  // A session born after the first turn shows up on the next one.
  const late = await spawnTask("late arrival", "Another one.\nstub:report=ready-for-review");
  await waitFor(idle(late.taskId), 15000, "idle");
  await api("POST", "/api/runs/orchestrator/followup", { text: "and now?" });
  await waitFor(idle("orchestrator"), 15000, "orchestrator idle");
  const line2 = stubLog().filter((l) => l.argv && l.env.SB_TASK_ID === "orchestrator").pop();
  assert.ok(fs.readFileSync(line2.argv[line2.argv.indexOf("--append-system-prompt-file") + 1], "utf8").includes(`\`${late.taskId}\``));

  // sb sessions / sb read from the orchestrator's shell.
  const sb = (...a) => spawnSync(process.execPath, [path.join(ROOT, "bin", "sb"), ...a], { env: { ...ENV, SB_ROLE: "orchestrator", SB_TASK_ID: "orchestrator" }, encoding: "utf8" });
  const ls = sb("sessions");
  assert.equal(ls.status, 0, ls.stderr);
  assert.ok(ls.stdout.includes(late.taskId));
  const rd = sb("read", t.id);
  assert.equal(rd.status, 0, rd.stderr);
  assert.match(rd.stdout, /Referenced session/);
  assert.ok(rd.stdout.includes(t.transcript));
});

test("clearing the orchestrator empties its chat and starts a fresh agent session", async () => {
  const before = await api("GET", "/api/runs/orchestrator");
  assert.ok(before.run.messages.length > 0);
  assert.ok(before.run.sessionId);
  assert.equal((await api("POST", "/api/runs/orchestrator/clear")).ok, true);
  const after = (await api("GET", "/api/runs/orchestrator")).run;
  assert.deepEqual([after.messages.length, after.sessionId, after.kind], [0, null, "orchestrator"]);
  const late = (await api("GET", "/api/sessions")).sessions.find((s) => s.id !== "orchestrator");
  assert.equal((await api("POST", `/api/runs/${late.id}/clear`)).ok, false, "only orchestrators clear");

  await api("POST", "/api/runs/orchestrator/followup", { text: "fresh start" });
  await waitFor(idle("orchestrator"), 15000, "orchestrator idle");
  const line = stubLog().filter((l) => l.argv && l.env.SB_TASK_ID === "orchestrator").pop();
  assert.ok(!line.argv.includes("--resume"), "the next turn doesn't resume the old session");
  assert.equal((await api("POST", "/api/runs/orchestrator/followup", { text: "/clear" })).cleared, true);
  assert.equal((await api("GET", "/api/runs/orchestrator")).run.messages.length, 0);
});

test("non-Claude agents get the skill inlined, $ARGUMENTS filled in", () => {
  const ws = require("../lib/workerskill");
  const skill = { name: "fetch", file: "/x/SKILL.md", text: SKILL };
  const codex = ws.prompt({ skill, agent: "codex", arg: LINEAR, rules: "## Bridge" });
  assert.ok(codex.startsWith(`Run the \`fetch\` skill below on: ${LINEAR}`));
  assert.ok(codex.includes(`Work on ${LINEAR} end to end.`));
  assert.ok(!codex.includes("argument-hint"), "frontmatter stripped");
  assert.ok(codex.trimEnd().endsWith("## Bridge"));
  assert.equal(ws.prompt({ skill: { name: "p:s", file: "", text: "" }, agent: "devin", arg: "x" }), null);
  assert.equal(ws.prompt({ skill, agent: "claude", arg: SLACK, rules: "R" }), `/fetch ${SLACK}\n\nR`);
  assert.equal(ws.sourceUrl(`see ${SLACK} and ${LINEAR}.`), LINEAR);
  assert.equal(ws.normalise("/fetch"), "fetch");
  assert.equal(ws.normalise("none"), "");
});
