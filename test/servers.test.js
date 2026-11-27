/**
 * Stopping a dev server from the app: only a pid the dev-server listing
 * returned, SIGTERM then SIGKILL, never Bridge itself, and never from a session.
 */

const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const http = require("http");
const { spawn } = require("child_process");

const tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "bridge-servers-")));
process.env.BRIDGE_DATA_DIR = path.join(tmp, "data");
const { stopListed } = require("../server/sources");
const { check, DEFAULT_POLICY } = require("../server/policy");

const kids = [];
const alive = (pid) => { try { process.kill(pid, 0); return true; } catch { return false; } };

/** A throwaway `node -e` http server in the scratch folder; resolves once it listens. */
function devServer(code = "") {
  const child = spawn(process.execPath, ["-e", `${code}require("http").createServer((q, s) => s.end("ok")).listen(0, () => console.log("up"))`], { cwd: tmp, stdio: ["ignore", "pipe", "ignore"] });
  kids.push(child);
  return new Promise((resolve) => child.stdout.once("data", () => resolve(child)));
}
const listing = (child) => [{ pid: child.pid, command: "node", cwd: tmp, ports: [3000] }];
const exited = (child) => new Promise((r) => (child.exitCode !== null || child.signalCode ? r() : child.once("exit", r)));

test.after(() => {
  for (const k of kids) if (k.exitCode === null && !k.signalCode) k.kill("SIGKILL"); // the exact PIDs this test started
  fs.rmSync(tmp, { recursive: true, force: true });
});

test("a listed dev server stops on SIGTERM", async () => {
  const child = await devServer();
  const r = await stopListed(child.pid, listing(child));
  assert.deepStrictEqual(r, { ok: true, signal: "SIGTERM" });
  await exited(child);
  assert.strictEqual(alive(child.pid), false);
});

test("one that ignores SIGTERM is killed after the grace period", async () => {
  const child = await devServer('process.on("SIGTERM", () => {});');
  const r = await stopListed(child.pid, listing(child), 400);
  assert.deepStrictEqual(r, { ok: true, signal: "SIGKILL" });
  await exited(child);
  assert.strictEqual(child.signalCode, "SIGKILL");
});

test("a pid outside the listing, Bridge itself or a nonsense pid is refused and left running", async () => {
  const child = await devServer();
  assert.strictEqual((await stopListed(child.pid, [])).status, 404);
  assert.strictEqual(alive(child.pid), true);
  const self = [{ pid: process.pid, command: "node", cwd: tmp, ports: [1] }];
  assert.strictEqual((await stopListed(process.pid, self)).status, 403);
  for (const bad of [0, 1, -1, NaN, 1.5]) assert.strictEqual((await stopListed(bad, [{ pid: bad }])).status, 403, String(bad));
});

test("POST /api/servers/:pid/stop refuses a pid the listing didn't return", async () => {
  const child = await devServer(); // in os.tmpdir(), outside your home folder: never listed
  const PORT = 48400 + Math.floor(Math.random() * 500);
  const server = spawn(process.execPath, [path.join(__dirname, "..", "server")], {
    env: { ...process.env, BRIDGE_DATA_DIR: path.join(tmp, "srv"), BRIDGE_PORT: String(PORT), BRIDGE_ENV_FILE: path.join(tmp, "none.env"), CLAUDE_BIN: path.join(__dirname, "stub.js"), TARGET_REPO: tmp },
    stdio: "ignore",
  });
  kids.push(server);
  const post = (p) => new Promise((resolve) => {
    const req = http.request({ host: "127.0.0.1", port: PORT, path: p, method: "POST", headers: { Host: `127.0.0.1:${PORT}` } }, (res) => {
      let text = "";
      res.on("data", (c) => (text += c));
      res.on("end", () => resolve({ status: res.statusCode, text }));
    });
    req.on("error", () => resolve({ status: 0, text: "" }));
    req.end();
  });
  const end = Date.now() + 10000;
  let r = { status: 0 };
  while (Date.now() < end && !r.status) {
    r = await post(`/api/servers/${child.pid}/stop`);
    if (!r.status) await new Promise((res) => setTimeout(res, 100));
  }
  assert.strictEqual(r.status, 404, r.text);
  assert.strictEqual(alive(child.pid), true);
  assert.strictEqual((await post(`/api/servers/${server.pid}/stop`)).status, 403, "Bridge's own server");
  server.kill("SIGTERM");
});

test("a session can't call it: it isn't one of bin/bridge's write routes", () => {
  const port = require("../server/env").port;
  const v = (c) => (check("Bash", { command: c }, { policy: { ...DEFAULT_POLICY } }) || { decision: "pass" }).decision;
  assert.strictEqual(v(`curl -X POST http://127.0.0.1:${port}/api/servers/4242/stop`), "deny");
  assert.strictEqual(v(`curl -X POST "$BRIDGE_URL/api/servers/4242/stop"`), "deny");
});
