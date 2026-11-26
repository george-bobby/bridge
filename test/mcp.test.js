const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const os = require("os");
const path = require("path");

const tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "bridge-mcp-")));
const HOME = path.join(tmp, "home");
const REPO = path.join(tmp, "repo");
fs.mkdirSync(path.join(HOME, ".cursor"), { recursive: true });
fs.mkdirSync(REPO, { recursive: true });
process.env.BRIDGE_MCP_HOME = HOME;
process.env.BRIDGE_DATA_DIR = path.join(tmp, "data");
process.env.BRIDGE_ENV_FILE = path.join(tmp, "none.env");
process.env.CLAUDE_CONFIG_DIR = path.join(tmp, "claude");
process.env.CLAUDE_BIN = path.join(__dirname, "stub.js");
process.env.TARGET_REPO = REPO;
// A cursor-agent that's installed and reports one server ready.
const fakeCursor = path.join(tmp, "cursor-agent");
fs.writeFileSync(fakeCursor, `#!/bin/sh\ncase "$1" in --version) echo 1.0;; mcp) echo "files: ready";; esac\n`, { mode: 0o755 });
process.env.CURSOR_AGENT_BIN = fakeCursor;

// The smallest MCP server: answers initialize and lists two tools, one page each.
const SERVER = `
let buf = "";
const out = (o) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...o }) + "\\n");
process.stdin.on("data", (c) => {
  buf += c;
  let i;
  while ((i = buf.indexOf("\\n")) >= 0) {
    const m = JSON.parse(buf.slice(0, i));
    buf = buf.slice(i + 1);
    if (m.method === "initialize") out({ id: m.id, result: { protocolVersion: m.params.protocolVersion, capabilities: { tools: {} }, serverInfo: { name: "fake", version: process.env.FAKE_VERSION || "0" } } });
    if (m.method === "tools/list" && !m.params.cursor) out({ id: m.id, result: { tools: [{ name: "read_file", description: "Read a file", inputSchema: { type: "object", properties: { path: { type: "string", description: "Which file" } }, required: ["path"] }, annotations: { readOnlyHint: true } }], nextCursor: "p2" } });
    if (m.method === "tools/list" && m.params.cursor === "p2") out({ id: m.id, result: { tools: [{ name: "delete_file", description: "Delete a file", annotations: { destructiveHint: true } }] } });
  }
});`;
const serverFile = path.join(tmp, "server.js");
fs.writeFileSync(serverFile, SERVER);

const mcp = require("../server/mcp");

test.after(() => fs.rmSync(tmp, { recursive: true, force: true }));

test("codexEdit adds, edits (keeping keys it doesn't manage), toggles and removes a server", () => {
  const start = `model = "o3"\n\n[mcp_servers.docs]\ncommand = "npx"\nargs = [\n  "-y",\n  "docs-mcp",\n]\nstartup_timeout_sec = 30\n\n[mcp_servers.docs.env]\nTOKEN = "abc"\n\n[profiles.fast]\nmodel = "mini"\n`;
  let t = mcp.codexEdit(start, "docs", { cfg: mcp.normalize({ command: "uvx", args: ["docs-mcp", "--port", "1"], env: { TOKEN: "xyz", MODE: "ro" } }) });
  assert.match(t, /^command = "uvx"$/m);
  assert.match(t, /^args = \["docs-mcp", "--port", "1"\]$/m);
  assert.match(t, /^startup_timeout_sec = 30$/m, "unmanaged key kept");
  assert.match(t, /\[mcp_servers\.docs\.env\]\nTOKEN = "xyz"\nMODE = "ro"/);
  assert.doesNotMatch(t, /"-y"/, "the multi-line array was replaced whole");
  assert.match(t, /\[profiles\.fast\]\nmodel = "mini"/, "other tables untouched");
  t = mcp.codexEdit(t, "docs", { enabled: false });
  assert.ok(t.includes("startup_timeout_sec = 30\nenabled = false\n"), "enabled goes in the server's own table");
  t = mcp.codexEdit(t, "docs", { enabled: true });
  assert.doesNotMatch(t, /enabled/);
  t = mcp.codexEdit(t, "my server", { cfg: mcp.normalize({ url: "https://x.example/mcp", headers: { "X-Key": "k" } }) });
  assert.match(t, /\[mcp_servers\."my server"\]\nurl = "https:\/\/x\.example\/mcp"/);
  assert.match(t, /\[mcp_servers\."my server"\.http_headers\]\nX-Key = "k"/);
  t = mcp.codexEdit(t, "docs", { remove: true });
  assert.doesNotMatch(t, /mcp_servers\.docs/);
  assert.match(t, /^model = "o3"$/m);
  assert.deepEqual(mcp.tomlPath(`mcp_servers."a.b".env`), ["mcp_servers", "a.b", "env"]);
});

test("a form keeps secret values it leaves blank and validates what it needs", () => {
  const prev = mcp.normalize({ command: "x", env: { API_KEY: "secret", OLD: "1" } });
  const cfg = mcp.fromForm({ type: "stdio", command: "y", args: ["a", ""], env: [{ key: "API_KEY", value: "" }, { key: "NEW", value: "2" }] }, prev);
  assert.deepEqual(cfg, { type: "stdio", command: "y", args: ["a"], env: { API_KEY: "secret", NEW: "2" } });
  assert.throws(() => mcp.fromForm({ type: "stdio" }), /command/);
  assert.throws(() => mcp.fromForm({ type: "http", url: "ftp://x" }), /http/);
  assert.equal(mcp.keyOf(mcp.normalize({ command: "a", env: { A: "1", B: "2" } })), mcp.keyOf(mcp.normalize({ command: "a", env: { B: "2", A: "1" } })), "env order doesn't change the cache key");
});

test("the handshake reads every page of tools with annotations and parameters", async () => {
  const r = await mcp.handshake(mcp.normalize({ command: process.execPath, args: [serverFile], env: { FAKE_VERSION: "7" } }));
  assert.equal(r.status, "connected");
  assert.equal(r.serverInfo.version, "7");
  assert.deepEqual(r.tools.map((t) => [t.name, t.readOnly, t.destructive]), [["read_file", true, false], ["delete_file", false, true]]);
  assert.deepEqual(r.tools[0].params, [{ name: "path", type: "string", required: true, description: "Which file" }]);
  const bad = await mcp.handshake(mcp.normalize({ command: path.join(tmp, "nope") }));
  assert.equal(bad.status, "failed");
  assert.match(bad.error, /not found/);
});

test("Cursor: add, list with status and tools, disable into the stash, enable back, remove", async () => {
  await mcp.save("cursor", { name: "files", form: { type: "stdio", command: process.execPath, args: [serverFile], env: [{ key: "FAKE_VERSION", value: "3" }] } }, { dir: REPO });
  const file = path.join(HOME, ".cursor", "mcp.json");
  assert.deepEqual(JSON.parse(fs.readFileSync(file, "utf8")).mcpServers.files, { command: process.execPath, args: [serverFile], env: { FAKE_VERSION: "3" } });
  await assert.rejects(mcp.save("cursor", { name: "files", form: { type: "stdio", command: "x" } }, { dir: REPO }), /already has/);

  let l = await mcp.list("cursor", { dir: REPO });
  assert.equal(l.installed, true);
  assert.deepEqual(l.servers[0].envKeys, ["FAKE_VERSION"], "names only");
  assert.equal(JSON.stringify(l).includes('"3"'), false, "env values never leave the server");
  const end = Date.now() + 10000;
  while (l.checking && Date.now() < end) {
    await new Promise((r) => setTimeout(r, 100));
    l = await mcp.list("cursor", { dir: REPO });
  }
  assert.equal(l.servers[0].status, "connected");
  assert.equal(l.servers[0].toolCount, 2);
  const tools = await mcp.tools("cursor", "files", { dir: REPO });
  assert.equal(tools.tools[0].description, "Read a file");

  // Edit with the secret left blank keeps it.
  await mcp.save("cursor", { name: "files", original: "files", form: { type: "stdio", command: process.execPath, args: [serverFile, "--x"], env: [{ key: "FAKE_VERSION", value: "" }] } }, { dir: REPO });
  assert.deepEqual(JSON.parse(fs.readFileSync(file, "utf8")).mcpServers.files.env, { FAKE_VERSION: "3" });

  await mcp.setEnabled("cursor", "files", false, { dir: REPO });
  assert.equal(JSON.parse(fs.readFileSync(file, "utf8")).mcpServers.files, undefined, "out of Cursor's file");
  l = await mcp.list("cursor", { dir: REPO });
  assert.equal(l.servers[0].enabled, false);
  assert.equal(l.servers[0].status, "disabled");
  await mcp.setEnabled("cursor", "files", true, { dir: REPO });
  assert.deepEqual(JSON.parse(fs.readFileSync(file, "utf8")).mcpServers.files.args, [serverFile, "--x"]);

  await mcp.remove("cursor", "files", { dir: REPO });
  assert.deepEqual(JSON.parse(fs.readFileSync(file, "utf8")).mcpServers, {});
});

test("Claude: config servers plus the live session's connectors, and a per-project toggle", async () => {
  fs.mkdirSync(process.env.CLAUDE_CONFIG_DIR, { recursive: true });
  fs.writeFileSync(path.join(process.env.CLAUDE_CONFIG_DIR, ".claude.json"), JSON.stringify({ mcpServers: { "stub-tools": { type: "stdio", command: "stub-mcp", args: [] } } }));
  let l = await mcp.list("claude", { dir: REPO });
  assert.deepEqual(l.servers.map((s) => s.name), ["stub-tools"]);
  const end = Date.now() + 15000;
  while (l.checking && Date.now() < end) {
    await new Promise((r) => setTimeout(r, 200));
    l = await mcp.list("claude", { dir: REPO });
  }
  const byName = Object.fromEntries(l.servers.map((s) => [s.name, s]));
  assert.equal(byName["stub-tools"].status, "connected");
  assert.equal(byName["stub-tools"].toolCount, 1);
  assert.equal(byName["claude.ai Docs"].scope, "claudeai");
  assert.equal(byName["claude.ai Docs"].editable, false);
  assert.equal(byName["claude.ai Docs"].toggleable, true);
  assert.deepEqual(await mcp.setEnabled("claude", "claude.ai Docs", false, { dir: REPO }), { name: "claude.ai Docs", enabled: false });
});
