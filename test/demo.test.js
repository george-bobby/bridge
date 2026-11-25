/**
 * `npm run demo` serves a fictional team and never calls out: fixture feeds,
 * seeded sessions in every state, and the CSV question still pending after boot.
 */

const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawn } = require("child_process");

const tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "sb-demo-")));
const PORT = 49700 + Math.floor(Math.random() * 200);
const URL_ = `http://127.0.0.1:${PORT}`;
let server;

test.before(async () => {
  server = spawn(process.execPath, [path.join(__dirname, "..", "scripts", "demo.js")], {
    env: { ...process.env, BRIDGE_DEMO_DIR: path.join(tmp, "data"), BRIDGE_PORT: String(PORT) },
    stdio: "ignore",
  });
  const end = Date.now() + 10000;
  while (Date.now() < end) {
    if (await fetch(`${URL_}/api/state`).then((r) => r.ok).catch(() => false)) break;
    await new Promise((r) => setTimeout(r, 100));
  }
  await new Promise((r) => setTimeout(r, 600)); // the post-boot rewrite of the sessions
});

test.after(() => {
  if (server) server.kill("SIGTERM"); // the exact PID this test started
  fs.rmSync(tmp, { recursive: true, force: true });
});

const get = (p) => fetch(URL_ + p).then((r) => r.json());

test("demo serves fixture PRs, Linear sub-issues and dev servers", async () => {
  const pulls = await get("/api/sources/pulls");
  assert.ok(pulls.mine.length >= 3 && pulls.review.length >= 1 && pulls.merged.length >= 1);
  const linear = await get("/api/sources/linear");
  const parent = linear.issues.find((i) => i.key === "WEB-120");
  assert.ok(parent.children.length >= 5, "the parent issue carries its sub-issues");
  assert.ok(linear.issues.some((i) => i.parent && i.parent.key === "WEB-120"));
  assert.ok((await get("/api/sources/ports")).servers.length >= 1);
});

test("demo sessions cover the board, and the pending question survives boot", async () => {
  const { runs } = await get("/api/runs");
  const csv = runs.find((r) => r.runId === "1732530001.000100");
  assert.strictEqual(csv.awaiting, true);
  assert.ok(runs.some((r) => r.kind === "task" && r.task && r.task.status === "ready-for-review"));
  assert.ok(runs.some((r) => r.action === "skipped"));
  const inbox = await get("/api/inbox");
  assert.strictEqual(inbox.counts.decisions, 1);
});

const post = (p, body) => fetch(URL_ + p, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body || {}) }).then(async (r) => ({ status: r.status, ...(await r.json()) }));

test("pin and move a session between projects; each project gets its own orchestrator", async () => {
  const id = "1732530002.000200";
  assert.strictEqual((await post(`/api/runs/${id}/pin`, { pinned: true })).pinned, true);
  assert.strictEqual((await post(`/api/runs/${id}/project`, { project: "mobile" })).project, "mobile");
  let r = (await get("/api/runs")).runs.find((x) => x.runId === id);
  assert.deepStrictEqual([r.pinned, r.project], [true, "mobile"]);
  assert.strictEqual((await post(`/api/runs/${id}/project`, { project: "nope" })).status, 400);
  const orch = await post("/api/projects/mobile/orchestrator");
  assert.strictEqual(orch.runId, "orchestrator-mobile");
  r = (await get("/api/runs")).runs.find((x) => x.runId === "orchestrator-mobile");
  assert.deepStrictEqual([r.kind, r.project], ["orchestrator", "mobile"]);
  assert.strictEqual((await post("/api/projects/storefront/orchestrator")).runId, "orchestrator", "the default project keeps the original chat");
});

test(".env editing keeps secrets out of responses and comments in the file", async () => {
  await post("/api/env", { values: { GITHUB_LOGIN: "octocat", SLACK_USER_TOKEN: "xoxp-secret-value" } });
  const { entries, file } = await get("/api/env");
  const login = entries.find((e) => e.key === "GITHUB_LOGIN");
  const token = entries.find((e) => e.key === "SLACK_USER_TOKEN");
  assert.strictEqual(login.value, "octocat");
  assert.deepStrictEqual([token.secret, token.set, token.value], [true, true, ""], "a secret is reported as set, never returned");
  assert.ok(!JSON.stringify(entries).includes("xoxp-secret-value"));
  assert.match(fs.readFileSync(file, "utf8"), /^SLACK_USER_TOKEN=xoxp-secret-value$/m);
  assert.strictEqual((await post("/api/env", { values: { "BAD KEY": "x" } })).status, 400);
});

test("demo refuses to wipe a folder that isn't its own", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "sb-real-"));
  fs.writeFileSync(path.join(dir, "keep.json"), "{}");
  assert.throws(() => require("../lib/demo").seed(dir), /refusing/);
  assert.ok(fs.existsSync(path.join(dir, "keep.json")));
  fs.rmSync(dir, { recursive: true, force: true });
});

test("slack connector routes answer from the demo workspace", async () => {
  assert.strictEqual((await get("/api/slack/status")).team, "Acme");
  const { mentions } = await get("/api/slack/mentions");
  assert.ok(mentions.length >= 3);
  const t = await get(`/api/slack/thread?url=${encodeURIComponent(mentions[0].permalink)}`);
  assert.ok(t.messages.length >= 1 && t.channel);
});
