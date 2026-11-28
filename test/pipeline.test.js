/**
 * The pipeline every new worker opens with (server/pipeline.js, Settings ›
 * Pipeline) and the orchestrator's session roster, against a real dashboard,
 * a scratch repo, a scratch data dir and the stub agent. Nothing here touches
 * the real data/ or ~/.claude.
 */

const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawn, execFileSync, spawnSync } = require("child_process");

const ROOT = path.join(__dirname, "..");
const tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "bridge-pipeline-")));
const DATA = path.join(tmp, "data");
const REPO = path.join(tmp, "repo");
const PORT = 45000 + Math.floor(Math.random() * 1500);
const URL_ = `http://127.0.0.1:${PORT}`;
const LINEAR = "https://linear.app/acme/issue/ABC-12/fix-the-export";
const SLACK = "https://acme.slack.com/archives/C0123ABCD/p1784615086259089";

const git = (args, cwd = REPO) => execFileSync("git", args, { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();

const ENV = {
  ...process.env,
  BRIDGE_DATA_DIR: DATA,
  CLAUDE_BIN: path.join(__dirname, "stub.js"),
  CLAUDE_CONFIG_DIR: path.join(tmp, "claude-home"),
  BRIDGE_PORT: String(PORT),
  BRIDGE_ENV_FILE: path.join(tmp, "none.env"),
  TARGET_REPO: REPO,
  WORKTREE_ROOT: path.join(tmp, "wt"),
  SLACK_USER_NAME: "Alex",
  SLACK_USER_TOKEN: "",
  LINEAR_API_KEY: "",
  BRANCH_PREFIX: "test",
  STUB_LOG: path.join(tmp, "stub.log"),
  BRIDGE_URL: URL_,
  BRIDGE_TASK_ID: "",
  BRIDGE_ROLE: "",
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
const promptOf = (id) => waitFor(() => (stubLog().find((l) => l.prompt != null && l.env.BRIDGE_TASK_ID === id) || {}).prompt, 10000, `prompt for ${id}`);
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
  fs.mkdirSync(DATA, { recursive: true });
  fs.writeFileSync(path.join(DATA, "config.json"), JSON.stringify({ harness: { relay: false, mode: "normal" } }));
  server = spawn(process.execPath, [path.join(ROOT, "server")], { env: ENV, stdio: ["ignore", "pipe", "pipe"] });
  server.stderr.on("data", (d) => process.env.BRIDGE_TEST_VERBOSE && process.stderr.write(d));
  await waitFor(async () => fetch(`${URL_}/api/state`).then((r) => r.ok).catch(() => false), 15000, "server up");
});
test.after(async () => {
  if (server) await new Promise((r) => (server.on("exit", r), server.kill("SIGTERM")));
  fs.rmSync(tmp, { recursive: true, force: true });
});

const PIPELINE_HEAD = fs.readFileSync(path.join(ROOT, "prompts", "pipeline.md"), "utf8").split("\n")[0];

test("a worker from a Linear brief opens with its task, then the pipeline", async () => {
  const st = await api("GET", "/api/pipeline");
  assert.deepEqual([st.ok, st.custom, st.text], [true, false, st.default]);

  const t = await spawnTask("ABC-12 Fix the export", `Linear issue ABC-12: Fix the export\n${LINEAR}\n\nRead the issue.\nstub:report=ready-for-review`);
  const prompt = await promptOf(t.taskId);
  assert.ok(prompt.startsWith(`# Task\n\nLinear issue ABC-12: Fix the export\n${LINEAR}`), prompt.slice(0, 200));
  assert.ok(prompt.includes(`\n\n${PIPELINE_HEAD}\n`), "the default pipeline follows the task");
  assert.ok(prompt.includes(`The source\nis ${LINEAR}; the full brief is at \`${path.join(DATA, "tasks", t.taskId, "brief.md")}\``), "{{URL}} and {{BRIEF}} filled");
  assert.match(prompt, /plan a large change with\nAlex /, "{{USER}} filled");
  assert.doesNotMatch(prompt, /\{\{[A-Z_]+\}\}/);
  await waitFor(idle(t.taskId), 15000, "worker idle");
  const run = await api("GET", `/api/runs/${t.taskId}`);
  const r = run.run || run;
  assert.equal(r.linearUrl, LINEAR);
  assert.ok(r.messages.some((m) => m.role === "event" && /with the pipeline/.test(m.text)), "spawned note says so");

  // A follow-up is a plain turn: the pipeline rides on the first one only.
  await api("POST", `/api/runs/${t.taskId}/followup`, { text: "one more thing stub:noreport" });
  await waitFor(idle(t.taskId), 15000, "follow-up idle");
  const last = stubLog().filter((l) => l.prompt != null && l.env.BRIDGE_TASK_ID === t.taskId).pop().prompt;
  assert.ok(!last.includes(PIPELINE_HEAD), "no pipeline on later turns");
});

test("an edited pipeline is what the next worker gets; blank turns it off; reset brings the default back", async () => {
  const saved = await api("POST", "/api/pipeline", { text: "# Mine\r\nWork on {{URL}} for {{USER}}; brief at {{BRIEF}}; tool {{BRIDGE}}." });
  assert.deepEqual([saved.ok, saved.custom], [true, true]);
  assert.equal(fs.readFileSync(path.join(DATA, "pipeline.md"), "utf8"), "# Mine\nWork on {{URL}} for {{USER}}; brief at {{BRIEF}}; tool {{BRIDGE}}.\n");
  const t = await spawnTask("tidy the readme", "Tidy the README wording.\nstub:report=ready-for-review");
  const prompt = await promptOf(t.taskId);
  const brief = path.join(DATA, "tasks", t.taskId, "brief.md");
  assert.equal(prompt, `# Task\n\nTidy the README wording.\nstub:report=ready-for-review\n\n# Mine\nWork on the brief (no Linear or Slack link) for Alex; brief at ${brief}; tool ${path.join(ROOT, "bin", "bridge")}.`);
  await waitFor(idle(t.taskId), 15000, "worker idle");

  await api("POST", "/api/pipeline", { text: "  " });
  const off = await spawnTask("off", "Nothing fancy.\nstub:report=ready-for-review");
  assert.match(await promptOf(off.taskId), /^Read \S+brief\.md and begin/);
  await waitFor(idle(off.taskId), 15000, "idle");

  const back = await api("POST", "/api/pipeline", { reset: true });
  assert.deepEqual([back.custom, back.text === back.default], [false, true]);
  assert.equal(fs.existsSync(path.join(DATA, "pipeline.md")), false);
  assert.equal((await api("POST", "/api/pipeline", { text: "x".repeat(40001) })).ok, false, "size cap");
});

test("a Slack thread pipeline runs the pipeline on the thread, with the closing verdict", async () => {
  const r = await api("POST", "/api/runs", { url: SLACK, start: true });
  assert.equal(r.ok, true, r.error);
  assert.equal(r.started, true);
  const prompt = await promptOf(r.runId);
  assert.ok(prompt.startsWith(`# Task\n\nSlack thread: ${SLACK}\n\n${PIPELINE_HEAD}`), prompt.slice(0, 200));
  assert.match(prompt, /"action":"acted"/);
  assert.match(prompt, /scripts\/emit\.sh/);
  await waitFor(idle(r.runId), 15000, "pipeline idle");
  const sys = fs.readFileSync(path.join(DATA, "tasks", r.runId, "system.md"), "utf8");
  assert.match(sys, /the pipeline in your first message governs the work/);
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
  const line = stubLog().filter((l) => l.argv && l.env.BRIDGE_TASK_ID === "orchestrator").pop();
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
  const line2 = stubLog().filter((l) => l.argv && l.env.BRIDGE_TASK_ID === "orchestrator").pop();
  assert.ok(fs.readFileSync(line2.argv[line2.argv.indexOf("--append-system-prompt-file") + 1], "utf8").includes(`\`${late.taskId}\``));

  // bridge sessions / bridge read from the orchestrator's shell.
  const cli = (...a) => spawnSync(process.execPath, [path.join(ROOT, "bin", "bridge"), ...a], { env: { ...ENV, BRIDGE_ROLE: "orchestrator", BRIDGE_TASK_ID: "orchestrator" }, encoding: "utf8" });
  const ls = cli("sessions");
  assert.equal(ls.status, 0, ls.stderr);
  assert.ok(ls.stdout.includes(late.taskId));
  const rd = cli("read", t.id);
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
  const line = stubLog().filter((l) => l.argv && l.env.BRIDGE_TASK_ID === "orchestrator").pop();
  assert.ok(!line.argv.includes("--resume"), "the next turn doesn't resume the old session");
  assert.equal((await api("POST", "/api/runs/orchestrator/followup", { text: "/clear" })).cleared, true);
  assert.equal((await api("GET", "/api/runs/orchestrator")).run.messages.length, 0);
});

test("sourceUrl picks the Linear issue over the Slack thread", () => {
  const { sourceUrl } = require("../server/pipeline");
  assert.equal(sourceUrl(`see ${SLACK} and ${LINEAR}.`), LINEAR);
  assert.equal(sourceUrl(`thread: ${SLACK}.`), SLACK);
  assert.equal(sourceUrl("no links"), "");
});
