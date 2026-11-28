/**
 * The request handler's gate: loopback Host (DNS rebinding), this server's own
 * Origin, Sec-Fetch-Site for browsers that send no Origin, and the body cap.
 * A real server on a scratch data dir.
 */

const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const http = require("http");
const { spawn } = require("child_process");

const tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "bridge-http-")));
const PORT = 47600 + Math.floor(Math.random() * 800);
let server;

test.before(async () => {
  server = spawn(process.execPath, [path.join(__dirname, "..", "server")], {
    env: { ...process.env, BRIDGE_DATA_DIR: path.join(tmp, "data"), BRIDGE_PORT: String(PORT), BRIDGE_ENV_FILE: path.join(tmp, "none.env"), BRIDGE_MCP_HOME: path.join(tmp, "home"), CLAUDE_CONFIG_DIR: path.join(tmp, "claude-home"), CLAUDE_BIN: path.join(__dirname, "stub.js"), TARGET_REPO: tmp, PORT: "1" },
    stdio: "ignore",
  });
  const end = Date.now() + 10000;
  while (Date.now() < end) {
    if (await fetch(`http://127.0.0.1:${PORT}/api/state`).then((r) => r.ok).catch(() => false)) return;
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error("server did not start");
});

test.after(() => {
  if (server) server.kill("SIGTERM"); // the exact PID this test started
  fs.rmSync(tmp, { recursive: true, force: true });
});

function request(p, { method = "GET", headers = {}, body } = {}) {
  return new Promise((resolve) => {
    const req = http.request({ host: "127.0.0.1", port: PORT, path: p, method, headers: { Host: `127.0.0.1:${PORT}`, ...headers } }, (res) => {
      let text = "";
      res.on("data", (c) => (text += c));
      res.on("end", () => resolve({ status: res.statusCode, text }));
    });
    req.on("error", () => resolve({ status: 0, text: "" }));
    req.end(body);
  });
}

test("BRIDGE_PORT is the port; a stray PORT in the environment is ignored", async () => {
  assert.strictEqual((await request("/api/state")).status, 200);
});

test("a foreign Host is refused, reads included", async () => {
  for (const host of ["evil.example", `evil.example:${PORT}`, "127.0.0.1.evil.example"]) {
    const r = await request("/api/state", { headers: { Host: host } });
    assert.strictEqual(r.status, 403, host);
    assert.match(r.text, /loopback only/);
  }
  assert.strictEqual((await request("/api/state", { headers: { Host: `localhost:${PORT}` } })).status, 200);
});

test("only this server's own Origin may call it", async () => {
  for (const origin of ["http://evil.example", "http://localhost:3000", `http://localhost:${PORT}.evil.example`, "null"]) {
    assert.strictEqual((await request("/api/state", { headers: { Origin: origin } })).status, 403, origin);
    assert.strictEqual((await request("/api/runs/x/seen", { method: "POST", headers: { Origin: origin } })).status, 403, origin);
  }
  assert.strictEqual((await request("/api/state", { headers: { Origin: `http://127.0.0.1:${PORT}` } })).status, 200);
});

test("without an Origin, a browser's Sec-Fetch-Site must be same-origin or none", async () => {
  for (const site of ["cross-site", "same-site"]) assert.strictEqual((await request("/api/sources/ports", { headers: { "Sec-Fetch-Site": site } })).status, 403, site);
  for (const site of ["same-origin", "none"]) assert.strictEqual((await request("/api/state", { headers: { "Sec-Fetch-Site": site } })).status, 200, site);
});

test("a body over the cap is refused and the server stays up", async () => {
  const r = await request("/api/runs", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ url: "x".repeat(3e6) }) });
  assert.notStrictEqual(r.status, 200);
  assert.strictEqual((await request("/api/state")).status, 200);
});

test("a malformed id costs that request only", async () => {
  assert.strictEqual((await request("/api/runs/%E0%A4%A")).status, 500);
  assert.strictEqual((await request("/api/state")).status, 200);
});
