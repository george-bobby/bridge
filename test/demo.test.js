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
    env: { ...process.env, SB_DATA_DIR: path.join(tmp, "data"), BRIDGE_PORT: String(PORT) },
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
