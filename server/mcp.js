/**
 * MCP servers for the four agents: what each one loads, whether it's up, its
 * tools, and add / edit / remove / enable / disable, written where the agent
 * itself keeps them.
 *
 *   Claude   ~/.claude.json (user + local scope) and <repo>/.mcp.json, read
 *            directly; writes go through `claude mcp add-json` / `remove`.
 *            Status, tools and the claude.ai connectors come from the
 *            stream-json `mcp_status` control request (no tokens spent).
 *   Codex    `codex mcp list --json`; writes edit ~/.codex/config.toml in
 *            place (`enabled = false` is Codex's own switch).
 *   Cursor   ~/.cursor/mcp.json; status from `cursor-agent mcp list`.
 *   Devin    `devin mcp list --json`; it also loads Cursor's file, so those
 *            servers are shared and edit through Cursor's file. Plugin
 *            servers are switched off by a disabled entry of the same name
 *            in ~/.config/devin/mcp_config.json, which is how Devin wants it.
 *
 * Claude and Cursor have no global off switch, so disabling there moves the
 * server's entry into Bridge's data/mcp-stash.json and enabling puts it back.
 *
 * Status and tools for everything but Claude come from a short MCP handshake
 * Bridge runs itself (initialize + tools/list, over stdio or streamable
 * HTTP). Results are cached by the server's config, so a server four agents
 * share is started once. Env and header values never leave the server: the
 * app sees their names, and an edit that leaves one blank keeps it.
 */

const fs = require("fs");
const os = require("os");
const path = require("path");
const crypto = require("crypto");
const { execFile, spawn } = require("child_process");
const env = require("./env");
const bus = require("./bus");

const AGENTS = ["claude", "codex", "cursor", "devin"];
const LABEL = { claude: "Claude", codex: "Codex", cursor: "Cursor", devin: "Devin" };
const home = () => process.env.BRIDGE_MCP_HOME || os.homedir();
const tilde = (p) => (p.startsWith(home()) ? `~${p.slice(home().length)}` : p);
const bin = {
  claude: () => env.claudeBin,
  codex: () => process.env.CODEX_BIN || "codex",
  cursor: () => process.env.CURSOR_AGENT_BIN || "cursor-agent",
  devin: () => process.env.DEVIN_BIN || "devin",
};

const cliEnv = () => {
  const e = { ...process.env, PATH: `${env.extraPath}:${process.env.PATH || "/usr/bin:/bin"}` };
  delete e.ACP_BACKEND;
  return e;
};

function sh(cmd, args, { cwd, timeout = 30000, input } = {}) {
  return new Promise((resolve) => {
    const child = execFile(cmd, args, { cwd: cwd && fs.existsSync(cwd) ? cwd : home(), timeout, maxBuffer: 32e6, env: cliEnv() }, (err, out, errOut) =>
      resolve({ ok: !err, out: String(out || ""), err: String(errOut || (err && err.message) || "").trim() }),
    );
    if (input != null) child.stdin.end(input);
  });
}

const readJson = (f, fallback = null) => {
  try {
    return JSON.parse(fs.readFileSync(f, "utf8"));
  } catch {
    return fallback;
  }
};

/** The file as it is, for a read-modify-write: missing is empty, but a file
 *  that won't parse is an error rather than a blank page to write over. */
function readJsonStrict(f) {
  if (!fs.existsSync(f)) return {};
  try {
    return JSON.parse(fs.readFileSync(f, "utf8"));
  } catch (e) {
    throw new Error(`${tilde(f)} isn't valid JSON (${e.message}); fix it by hand first`);
  }
}

/** Replace a file in one step, keeping its permissions (these hold tokens):
 *  a new file is private to you. */
function writeTextAtomic(file, text) {
  try {
    file = fs.realpathSync(file);
  } catch {}
  fs.mkdirSync(path.dirname(file), { recursive: true });
  let mode = 0o600;
  try {
    mode = fs.statSync(file).mode & 0o777;
  } catch {}
  const tmp = `${file}.${process.pid}.${Date.now()}.tmp`;
  fs.writeFileSync(tmp, text, { mode });
  fs.chmodSync(tmp, mode);
  fs.renameSync(tmp, file);
}

const writeJsonAtomic = (file, value) => writeTextAtomic(file, JSON.stringify(value, null, 2) + "\n");

/* ------------------------------------------------------------- configs */

/** `${VAR}` and `${VAR:-default}`, the way Claude and Cursor expand them. */
const expand = (s) => String(s == null ? "" : s).replace(/\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}/g, (_, k, d) => process.env[k] ?? d ?? "");

/** Every agent's entry, as one shape: stdio (command, args, env, cwd) or
 *  http/sse (url, headers). */
function normalize(raw = {}) {
  const t = String(raw.type || raw.transport || "").toLowerCase();
  const url = raw.url || raw.serverUrl || "";
  const type = t === "sse" ? "sse" : url || /http/.test(t) ? "http" : "stdio";
  const out = { type };
  if (type === "stdio") {
    out.command = String(raw.command || "");
    out.args = Array.isArray(raw.args) ? raw.args.map(String) : [];
    out.env = raw.env && typeof raw.env === "object" ? Object.fromEntries(Object.entries(raw.env).map(([k, v]) => [k, String(v)])) : {};
    if (raw.cwd) out.cwd = String(raw.cwd);
  } else {
    out.url = String(url);
    const h = raw.headers || raw.http_headers || {};
    out.headers = Object.fromEntries(Object.entries(h).map(([k, v]) => [k, String(v)]));
    if (raw.bearer_token_env_var) out.bearerEnv = String(raw.bearer_token_env_var);
  }
  return out;
}

// Sorted: Codex prints env tables in a different order every run.
const sorted = (o) => Object.keys(o || {})
  .sort()
  .map((k) => [k, o[k]]);
const keyOf = (cfg) =>
  crypto
    .createHash("sha1")
    .update(JSON.stringify(cfg.type === "stdio" ? [cfg.command, cfg.args, sorted(cfg.env), cfg.cwd || ""] : [cfg.type, cfg.url, sorted(cfg.headers), cfg.bearerEnv || ""]))
    .digest("hex")
    .slice(0, 16);

/** What the app may see: names of env vars and headers, never values. */
function publicConfig(cfg) {
  return cfg.type === "stdio"
    ? { type: cfg.type, command: cfg.command, args: cfg.args, envKeys: Object.keys(cfg.env || {}), cwd: cfg.cwd || "" }
    : { type: cfg.type, url: cfg.url, headerKeys: Object.keys(cfg.headers || {}), bearerEnv: cfg.bearerEnv || "" };
}

/* --------------------------------------------------------------- stash */

const STASH = () => path.join(env.dataDir, "mcp-stash.json");
const readStash = () => readJson(STASH(), {}) || {};
function editStash(fn) {
  const s = readStash();
  fn(s);
  writeJsonAtomic(STASH(), s);
}

/* ------------------------------------------------------- MCP handshake */

const PROTOCOL = "2025-06-18";
const INIT = { protocolVersion: PROTOCOL, capabilities: {}, clientInfo: { name: "bridge", version: "2" } };

function cleanTools(list) {
  return (list || [])
    .filter((t) => t && t.name)
    .map((t) => {
      const a = t.annotations || {};
      const props = (t.inputSchema && t.inputSchema.properties) || {};
      const required = new Set((t.inputSchema && t.inputSchema.required) || []);
      return {
        name: String(t.name),
        title: String(t.title || a.title || ""),
        description: String(t.description || "").slice(0, 2000),
        readOnly: !!(a.readOnlyHint || a.readOnly),
        destructive: !!(a.destructiveHint || a.destructive),
        params: Object.entries(props)
          .slice(0, 40)
          .map(([name, p]) => ({ name, type: String((p && (p.type || (p.anyOf && "any"))) || ""), required: required.has(name), description: String((p && p.description) || "").slice(0, 300) })),
      };
    });
}

/** initialize + tools/list over stdio. */
function handshakeStdio(cfg, timeout) {
  return new Promise((resolve) => {
    let child;
    try {
      child = spawn(expand(cfg.command), cfg.args.map(expand), {
        cwd: cfg.cwd && fs.existsSync(cfg.cwd) ? cfg.cwd : home(),
        env: { ...cliEnv(), ...Object.fromEntries(Object.entries(cfg.env || {}).map(([k, v]) => [k, expand(v)])) },
        stdio: ["pipe", "pipe", "pipe"],
      });
    } catch (e) {
      return resolve({ status: "failed", error: e.message });
    }
    let buf = "";
    let errOut = "";
    let done = false;
    let info = null;
    const tools = [];
    const finish = (v) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      try {
        child.kill();
      } catch {}
      resolve(v);
    };
    const timer = setTimeout(() => finish({ status: "failed", error: `no answer in ${Math.round(timeout / 1000)}s${errOut ? `: ${errOut.trim().split("\n").pop()}` : ""}` }), timeout);
    const send = (o) => {
      try {
        child.stdin.write(JSON.stringify({ jsonrpc: "2.0", ...o }) + "\n");
      } catch {}
    };
    child.on("error", (e) => finish({ status: "failed", error: e.code === "ENOENT" ? `command not found: ${cfg.command}` : e.message }));
    child.on("close", (code) => finish({ status: "failed", error: `exited (${code})${errOut ? `: ${errOut.trim().split("\n").slice(-2).join(" ").slice(0, 300)}` : ""}` }));
    child.stdin.on("error", () => {});
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (c) => (errOut = (errOut + c).slice(-4000)));
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (c) => {
      buf += c;
      if (buf.length > 16e6) return finish({ status: "failed", error: "answered with more than 16 MB on one line" });
      let i;
      while ((i = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, i).trim();
        buf = buf.slice(i + 1);
        let m;
        try {
          m = JSON.parse(line);
        } catch {
          continue;
        }
        if (!m || typeof m !== "object" || Array.isArray(m)) continue;
        if (m.id === 1) {
          if (m.error) return finish({ status: "failed", error: m.error.message || "initialize failed" });
          info = (m.result && m.result.serverInfo) || null;
          send({ method: "notifications/initialized" });
          send({ id: 2, method: "tools/list", params: {} });
        } else if (typeof m.id === "number" && m.id >= 2) {
          if (m.error) return finish({ status: "connected", serverInfo: info, tools: cleanTools(tools), error: m.error.message });
          const page = m.result && Array.isArray(m.result.tools) ? m.result.tools : [];
          tools.push(...page);
          const next = m.result && m.result.nextCursor;
          if (next && m.id < 40) send({ id: m.id + 1, method: "tools/list", params: { cursor: next } });
          else finish({ status: "connected", serverInfo: info, tools: cleanTools(tools) });
        }
      }
    });
    send({ id: 1, method: "initialize", params: INIT });
  });
}

/** One JSON-RPC message from a streamable-HTTP answer (JSON or SSE). */
async function rpcAnswer(res, id) {
  const text = await res.text();
  if (/text\/event-stream/.test(res.headers.get("content-type") || "")) {
    for (const block of text.replace(/\r\n?/g, "\n").split(/\n\n+/)) {
      const data = block
        .split("\n")
        .filter((l) => l.startsWith("data:"))
        .map((l) => l.slice(5).trim())
        .join("\n");
      try {
        const m = JSON.parse(data);
        if (m.id === id) return m;
      } catch {}
    }
    return null;
  }
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

async function handshakeHttp(cfg, timeout) {
  if (!/^https?:\/\//.test(cfg.url)) return { status: "unknown", error: `${cfg.url === "<redacted>" ? "The agent hides this server's URL" : "Not an http(s) URL"}, so Bridge can't check it` };
  if (cfg.type === "sse") return { status: "unknown", error: "Bridge checks streamable-HTTP and stdio servers; this one uses the older SSE transport" };
  const headers = { "Content-Type": "application/json", Accept: "application/json, text/event-stream", "MCP-Protocol-Version": PROTOCOL };
  for (const [k, v] of Object.entries(cfg.headers || {})) headers[k] = expand(v);
  if (cfg.bearerEnv && process.env[cfg.bearerEnv]) headers.Authorization = `Bearer ${process.env[cfg.bearerEnv]}`;
  const url = expand(cfg.url);
  const post = (body) => fetch(url, { method: "POST", headers, body: JSON.stringify({ jsonrpc: "2.0", ...body }), signal: AbortSignal.timeout(timeout) });
  let sid = "";
  try {
    const r1 = await post({ id: 1, method: "initialize", params: INIT });
    if (r1.status === 401 || r1.status === 403) return { status: "needs-auth", error: `${new URL(url).host} wants a sign-in (${r1.status})` };
    if (!r1.ok) return { status: "failed", error: `${new URL(url).host} answered ${r1.status}` };
    sid = r1.headers.get("mcp-session-id") || "";
    if (sid) headers["Mcp-Session-Id"] = sid;
    const init = await rpcAnswer(r1, 1);
    if (!init || init.error) return { status: "failed", error: (init && init.error && init.error.message) || "unreadable initialize answer" };
    // Later requests carry the version the server agreed to.
    if (init.result && init.result.protocolVersion) headers["MCP-Protocol-Version"] = String(init.result.protocolVersion);
    await post({ method: "notifications/initialized" })
      .then((r) => r.text())
      .catch(() => {});
    const tools = [];
    let cursor;
    for (let id = 2; id < 40; id++) {
      const r = await post({ id, method: "tools/list", params: cursor ? { cursor } : {} });
      const m = r.ok ? await rpcAnswer(r, id) : null;
      if (!m || m.error) break;
      tools.push(...(m.result && Array.isArray(m.result.tools) ? m.result.tools : []));
      cursor = m.result && m.result.nextCursor;
      if (!cursor) break;
    }
    return { status: "connected", serverInfo: (init.result && init.result.serverInfo) || null, tools: cleanTools(tools) };
  } catch (e) {
    const why = e.cause && (e.cause.code || e.cause.message);
    return { status: "failed", error: e.name === "TimeoutError" ? `no answer in ${Math.round(timeout / 1000)}s` : why ? `couldn't reach ${hostOf(url)} (${why})` : String(e.message || e) };
  } finally {
    if (sid) fetch(url, { method: "DELETE", headers, signal: AbortSignal.timeout(3000) }).catch(() => {});
  }
}

const hostOf = (u) => {
  try {
    return new URL(u).host;
  } catch {
    return u;
  }
};

// 30s, like Claude Code's own MCP startup timeout: uvx/npx servers can be slow to boot.
function handshake(cfg, { timeout = 30000 } = {}) {
  if (cfg.type === "stdio") return cfg.command ? handshakeStdio(cfg, timeout) : Promise.resolve({ status: "failed", error: "no command" });
  return cfg.url ? handshakeHttp(cfg, timeout) : Promise.resolve({ status: "failed", error: "no URL" });
}

/* --------------------------------------------------------------- cache */

const TTL = 5 * 60_000;
/** By config key: the last handshake. */
const checks = new Map();
/** By config key: tool lists learned from anywhere (Claude's probe included). */
const toolsSeen = new Map();
const inflight = new Map();

function remember(key, r) {
  checks.set(key, { ...r, at: Date.now() });
  // A server that answered with no tools has none now, whatever it had before.
  if (r.status === "connected" && r.tools && !r.tools.length) toolsSeen.delete(key);
  if (r.tools && r.tools.length) {
    const prev = toolsSeen.get(key);
    // A list with descriptions beats one with names only.
    if (!prev || r.tools.some((t) => t.description) || !prev.some((t) => t.description)) toolsSeen.set(key, r.tools);
  }
}

function check(cfg, { refresh = false } = {}) {
  const key = keyOf(cfg);
  const hit = checks.get(key);
  if (hit && !refresh && Date.now() - hit.at < TTL) return Promise.resolve(hit);
  if (inflight.has(key)) return inflight.get(key);
  const p = handshake(cfg).then((r) => {
    remember(key, r);
    inflight.delete(key);
    return checks.get(key);
  });
  inflight.set(key, p);
  return p;
}

/** Run `fns` at most `n` at a time. */
async function pool(fns, n = 4) {
  const out = [];
  let i = 0;
  await Promise.all(
    Array.from({ length: Math.min(n, fns.length) }, async () => {
      while (i < fns.length) {
        const k = i++;
        out[k] = await fns[k]().catch(() => null);
      }
    }),
  );
  return out;
}

/* ------------------------------------------------------- Claude's view */

const claudeFile = () => path.join(process.env.CLAUDE_CONFIG_DIR || home(), ".claude.json");
const realDir = (d) => {
  try {
    return fs.realpathSync(d);
  } catch {
    return d;
  }
};

/** What a live Claude session in `dir` loads: every server's status, scope
 *  and tools, claude.ai connectors and plugin servers included. Polls the
 *  `mcp_status` control request until nothing is pending (25s at most). */
const claudeProbes = new Map();
function claudeProbe(dir, { refresh = false } = {}) {
  const key = dir || "";
  const hit = claudeProbes.get(key);
  if (hit && !refresh && (hit.pending || Date.now() - hit.at < 3 * 60_000)) return hit.promise;
  const entry = { at: Date.now(), pending: true };
  entry.promise = new Promise((resolve) => {
    const b = bin.claude();
    const args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--no-session-persistence"];
    const [cmd, argv] = b.endsWith(".js") ? [process.execPath, [b, ...args]] : [b, args];
    let child;
    try {
      child = spawn(cmd, argv, { cwd: dir && fs.existsSync(dir) ? dir : home(), stdio: ["pipe", "pipe", "ignore"], env: cliEnv() });
    } catch {
      return resolve(null);
    }
    let buf = "";
    let n = 0;
    let last = null;
    let done = false;
    const finish = (v) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      try {
        child.kill();
      } catch {}
      resolve(v);
    };
    const timer = setTimeout(() => finish(last), 25000);
    const ask = () => {
      try {
        child.stdin.write(JSON.stringify({ type: "control_request", request_id: `s${n++}`, request: { subtype: "mcp_status" } }) + "\n");
      } catch {}
    };
    child.on("error", () => finish(null));
    child.on("close", () => finish(last));
    child.stdin.on("error", () => {});
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (c) => {
      buf += c;
      let i;
      while ((i = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, i);
        buf = buf.slice(i + 1);
        let ev;
        try {
          ev = JSON.parse(line);
        } catch {
          continue;
        }
        if (ev.type !== "control_response" || !ev.response) continue;
        if (ev.response.request_id === "init") ask();
        const servers = ev.response.response && ev.response.response.mcpServers;
        if (!Array.isArray(servers)) continue;
        last = servers;
        // claude.ai connectors join a few seconds in; give them the chance.
        if (servers.every((s) => s.status !== "pending") && n > 3) finish(servers);
        else setTimeout(ask, 1200);
      }
    });
    child.stdin.write(JSON.stringify({ type: "control_request", request_id: "init", request: { subtype: "initialize", hooks: {} } }) + "\n");
  });
  entry.promise.then((v) => {
    entry.pending = false;
    entry.at = Date.now();
    if (!v && claudeProbes.get(key) === entry) claudeProbes.delete(key);
    for (const s of v || []) {
      if (!s.config || !s.tools) continue;
      const cfg = normalize(s.config);
      const tools = s.tools.map((t) => ({ name: t.name, title: "", description: "", readOnly: !!(t.annotations && t.annotations.readOnly), destructive: !!(t.annotations && t.annotations.destructive), params: [] }));
      if (!toolsSeen.has(keyOf(cfg))) toolsSeen.set(keyOf(cfg), tools);
    }
    bus.broadcast("mcp", { agent: "claude" });
  });
  claudeProbes.set(key, entry);
  return entry.promise;
}

/** Toggle a server for one project, the way Claude's own /mcp menu does. */
function claudeToggle(dir, name, enabled) {
  return new Promise((resolve) => {
    const b = bin.claude();
    const args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--no-session-persistence"];
    const [cmd, argv] = b.endsWith(".js") ? [process.execPath, [b, ...args]] : [b, args];
    let child;
    try {
      child = spawn(cmd, argv, { cwd: dir && fs.existsSync(dir) ? dir : home(), stdio: ["pipe", "pipe", "ignore"], env: cliEnv() });
    } catch (e) {
      return resolve({ ok: false, error: e.message });
    }
    let buf = "";
    let tries = 0;
    let done = false;
    const finish = (v) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      try {
        child.kill();
      } catch {}
      resolve(v);
    };
    const timer = setTimeout(() => finish({ ok: false, error: "Claude didn't answer" }), 30000);
    const send = (id, request) => {
      try {
        child.stdin.write(JSON.stringify({ type: "control_request", request_id: id, request }) + "\n");
      } catch {}
    };
    child.on("error", (e) => finish({ ok: false, error: e.message }));
    child.on("close", () => finish({ ok: false, error: "Claude exited" }));
    child.stdin.on("error", () => {});
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (c) => {
      buf += c;
      let i;
      while ((i = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, i);
        buf = buf.slice(i + 1);
        let ev;
        try {
          ev = JSON.parse(line);
        } catch {
          continue;
        }
        if (ev.type !== "control_response" || !ev.response) continue;
        const id = ev.response.request_id;
        if (id === "init") send(`t${tries++}`, { subtype: "mcp_toggle", serverName: name, enabled });
        else if (/^t\d+$/.test(id)) {
          if (ev.response.subtype === "success") finish({ ok: true });
          // Connectors load a few seconds after start; until then they're "not found".
          else if (tries < 12) setTimeout(() => send(`t${tries++}`, { subtype: "mcp_toggle", serverName: name, enabled }), 1000);
          else finish({ ok: false, error: ev.response.error || "Claude refused the change" });
        }
      }
    });
    send("init", { subtype: "initialize", hooks: {} });
  });
}

function claudeEntries(dir) {
  const j = readJson(claudeFile(), {}) || {};
  const proj = (j.projects || {})[realDir(dir)] || (j.projects || {})[dir] || {};
  const out = [];
  const add = (raw, name, scope, source) => out.push({ name, raw, cfg: normalize(raw), scope, source, enabled: true, editable: true, removable: true, toggleable: true });
  for (const [n, raw] of Object.entries(j.mcpServers || {})) add(raw, n, "user", tilde(claudeFile()));
  for (const [n, raw] of Object.entries(proj.mcpServers || {})) add(raw, n, "local", `${tilde(claudeFile())} · this project`);
  const shared = readJson(path.join(dir, ".mcp.json"), {}) || {};
  for (const [n, raw] of Object.entries(shared.mcpServers || {})) {
    out.push({ name: n, raw, cfg: normalize(raw), scope: "project", source: ".mcp.json", enabled: true, editable: false, removable: false, toggleable: true, note: "Checked into the repo's .mcp.json; edit the file to change it" });
  }
  for (const [k, s] of Object.entries(readStash().claude || {})) {
    // Local-scope entries belong to one project.
    if (s.scope === "local" && realDir(s.dir || "") !== realDir(dir)) continue;
    const n = s.name || k;
    if (out.some((e) => e.name === n)) continue;
    out.push({ name: n, stashKey: k, raw: s.raw, cfg: normalize(s.raw), scope: s.scope, source: "Disabled by Bridge", enabled: false, editable: true, removable: true, toggleable: true });
  }
  const off = new Set(proj.disabledMcpServers || []);
  for (const e of out) if (off.has(e.name)) e.enabled = false;
  return { entries: out, disabledHere: off };
}

/* ------------------------------------------------------------ Codex */

const codexFile = () => path.join(process.env.CODEX_HOME || path.join(home(), ".codex"), "config.toml");

/** `a."b c".d` → ["a", "b c", "d"]. */
function tomlPath(s) {
  const out = [];
  let cur = "";
  let q = "";
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (q) {
      if (ch === "\\" && q === '"') {
        cur += s[++i] || "";
      } else if (ch === q) q = "";
      else cur += ch;
    } else if (ch === '"' || ch === "'") q = ch;
    else if (ch === ".") {
      out.push(cur.trim());
      cur = "";
    } else cur += ch;
  }
  out.push(cur.trim());
  return out;
}

const tomlKey = (k) => (/^[A-Za-z0-9_-]+$/.test(k) ? k : JSON.stringify(k));
const tomlVal = (v) => (Array.isArray(v) ? `[${v.map((x) => JSON.stringify(String(x))).join(", ")}]` : typeof v === "boolean" || typeof v === "number" ? String(v) : JSON.stringify(String(v)));
const tomlHeader = (p) => `[${p.map(tomlKey).join(".")}]`;

function tomlSections(lines) {
  const out = [];
  for (let i = 0; i < lines.length; i++) {
    // [[array.of.tables]] ends a section too; it's never one Bridge edits.
    const arr = /^\s*\[\[(.+?)\]\]\s*(#.*)?$/.exec(lines[i]);
    const m = arr ? null : /^\s*\[(.+?)\]\s*(#.*)?$/.exec(lines[i]);
    if (arr) out.push({ i, path: ["[[]]", ...tomlPath(arr[1])] });
    else if (m) out.push({ i, path: tomlPath(m[1]) });
  }
  return out.map((s, k) => ({ ...s, end: k + 1 < out.length ? out[k + 1].i : lines.length }));
}

const same = (a, b) => a.length === b.length && a.every((x, i) => x === b[i]);
const under = (p, base) => p.length > base.length && base.every((x, i) => p[i] === x);

/** Lines a `key = value` spans, multi-line arrays and tables included. */
function valueEnd(lines, i) {
  let depth = 0;
  let q = "";
  for (let k = i; k < lines.length; k++) {
    const line = lines[k];
    for (let c = k === i ? line.indexOf("=") + 1 : 0; c < line.length; c++) {
      const ch = line[c];
      if (q) {
        if (ch === "\\" && q === '"') c++;
        else if (ch === q) q = "";
      } else if (ch === '"' || ch === "'") q = ch;
      else if (ch === "#") break;
      else if (ch === "[" || ch === "{") depth++;
      else if (ch === "]" || ch === "}") depth--;
    }
    if (depth <= 0) return k + 1;
  }
  return lines.length;
}

/** Set (or with `value === undefined`, delete) `key` in the section that
 *  starts at header line `h`. */
function tomlSet(lines, h, key, value) {
  const secs = tomlSections(lines);
  const sec = secs.find((s) => s.i === h);
  const esc = (k) => k.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  // `command`, `"command"` and `'command'` are the same key.
  const re = new RegExp(`^\\s*(?:${esc(key)}|"${esc(key)}"|'${esc(key)}')\\s*=`);
  for (let i = h + 1; i < sec.end; i++) {
    if (!re.test(lines[i])) continue;
    const end = valueEnd(lines, i);
    if (value === undefined) lines.splice(i, end - i);
    else lines.splice(i, end - i, `${tomlKey(key)} = ${tomlVal(value)}`);
    return;
  }
  if (value === undefined) return;
  let at = sec.end;
  while (at > h + 1 && !lines[at - 1].trim()) at--;
  lines.splice(at, 0, `${tomlKey(key)} = ${tomlVal(value)}`);
}

/** Drop the server's sub-table `sub` ([mcp_servers.x.env]) and write `obj`
 *  as a fresh one right after the server's own table. */
function tomlTable(lines, name, sub, obj) {
  const base = ["mcp_servers", name];
  let secs = tomlSections(lines);
  const old = secs.find((s) => same(s.path, [...base, sub]));
  if (old) lines.splice(old.i, old.end - old.i);
  secs = tomlSections(lines);
  const main = secs.find((s) => same(s.path, base));
  if (!main) return;
  tomlSet(lines, main.i, sub, undefined);
  if (!Object.keys(obj).length) return;
  secs = tomlSections(lines);
  const after = secs.filter((s) => s.i > main.i && under(s.path, base)).map((s) => s.end);
  let at = after.length ? Math.max(...after) : secs.find((s) => s.i === main.i).end;
  while (at > main.i + 1 && !lines[at - 1].trim()) at--;
  const block = ["", tomlHeader([...base, sub]), ...Object.entries(obj).map(([k, v]) => `${tomlKey(k)} = ${tomlVal(v)}`)];
  lines.splice(at, 0, ...block);
}

function codexHas(text, name) {
  return tomlSections(text.split("\n")).some((s) => same(s.path, ["mcp_servers", name]));
}

/** Pure: config.toml text with server `name` written as `cfg` (keys this
 *  form doesn't manage are kept), toggled, or removed. */
function codexEdit(text, name, op) {
  const lines = text.split("\n");
  let secs = tomlSections(lines);
  const base = ["mcp_servers", name];
  let main = secs.find((s) => same(s.path, base));
  if (op.remove) {
    if (!main) return text;
    const drop = secs.filter((s) => same(s.path, base) || under(s.path, base)).sort((a, b) => b.i - a.i);
    for (const s of drop) lines.splice(s.i, s.end - s.i);
    return lines.join("\n").replace(/\n{3,}/g, "\n\n");
  }
  if (!main) {
    if (!op.cfg) throw new Error(`${name} isn't in ${tilde(codexFile())}`);
    while (lines.length && !lines[lines.length - 1].trim()) lines.pop();
    lines.push("", tomlHeader(base), "");
    secs = tomlSections(lines);
    main = secs.find((s) => same(s.path, base));
  }
  if (op.enabled !== undefined) tomlSet(lines, main.i, "enabled", op.enabled ? undefined : false);
  if (op.cfg) {
    const c = op.cfg;
    const stdio = c.type === "stdio";
    tomlSet(lines, main.i, "command", stdio ? c.command : undefined);
    tomlSet(lines, main.i, "args", stdio ? c.args : undefined);
    tomlSet(lines, main.i, "url", stdio ? undefined : c.url);
    tomlSet(lines, main.i, "bearer_token_env_var", !stdio && c.bearerEnv ? c.bearerEnv : undefined);
    if (stdio) tomlSet(lines, main.i, "cwd", c.cwd || undefined);
    tomlTable(lines, name, "env", stdio ? c.env || {} : {});
    tomlTable(lines, name, "http_headers", stdio ? {} : c.headers || {});
  }
  let out = lines.join("\n").replace(/\n{3,}/g, "\n\n");
  if (!out.endsWith("\n")) out += "\n";
  return out;
}

const codexLists = new Map();
/** In the checkout: a trusted project's own .codex/config.toml adds to the list. */
async function codexList(dir, { refresh = false } = {}) {
  const hit = codexLists.get(dir);
  if (hit && !refresh && Date.now() - hit.at < 60_000) return hit.data;
  const r = await sh(bin.codex(), ["mcp", "list", "--json"], { cwd: dir, timeout: 20000 });
  let data = null;
  try {
    data = JSON.parse(r.out);
  } catch {}
  if (!data) throw new Error(`Couldn't read Codex's servers: ${r.err.split("\n").filter(Boolean).pop() || "codex mcp list failed"}`);
  codexLists.set(dir, { at: Date.now(), data });
  return data;
}

async function codexEntries(dir) {
  const list = await codexList(dir, { refresh: true });
  const text = fs.existsSync(codexFile()) ? fs.readFileSync(codexFile(), "utf8") : "";
  let repoText = "";
  const repoFile = path.join(dir, ".codex", "config.toml");
  try {
    if (realDir(repoFile) !== realDir(codexFile())) repoText = fs.readFileSync(repoFile, "utf8");
  } catch {}
  return list.map((s) => {
    const t = s.transport || {};
    const raw = t.type === "stdio" ? { command: t.command, args: t.args, env: t.env, cwd: t.cwd } : { url: t.url, type: "http", http_headers: t.http_headers, bearer_token_env_var: t.bearer_token_env_var };
    const repo = codexHas(repoText, s.name);
    const own = !repo && codexHas(text, s.name);
    return {
      name: s.name,
      raw,
      cfg: normalize(raw),
      scope: own ? "user" : repo ? "project" : "plugin",
      source: own ? tilde(codexFile()) : repo ? ".codex/config.toml" : "A Codex plugin",
      enabled: s.enabled !== false,
      editable: own,
      removable: own,
      toggleable: own,
      authStatus: s.auth_status || "",
      note: own ? "" : repo ? "Checked into the repo's .codex/config.toml" : "Provided by a Codex plugin; manage it from Codex's plugins",
    };
  });
}

/* ------------------------------------------------------------ Cursor */

const cursorFile = () => path.join(home(), ".cursor", "mcp.json");

function cursorEntries(dir) {
  const out = [];
  const j = readJson(cursorFile(), {}) || {};
  for (const [n, raw] of Object.entries(j.mcpServers || {})) out.push({ name: n, raw, cfg: normalize(raw), scope: "user", source: tilde(cursorFile()), enabled: true, editable: true, removable: true, toggleable: true, sharedWith: ["devin"] });
  const repoFile = dir ? path.join(dir, ".cursor", "mcp.json") : "";
  const pj = repoFile && realDir(repoFile) !== realDir(cursorFile()) ? readJson(repoFile, {}) || {} : {};
  for (const [n, raw] of Object.entries(pj.mcpServers || {})) {
    // Cursor takes the project's entry over a global one of the same name.
    const shadowed = out.findIndex((e) => e.name === n);
    const e = { name: n, raw, cfg: normalize(raw), scope: "project", source: ".cursor/mcp.json", enabled: true, editable: false, removable: false, toggleable: false, note: shadowed >= 0 ? "This repo's .cursor/mcp.json overrides your global entry of the same name" : "Checked into the repo's .cursor/mcp.json" };
    if (shadowed >= 0) out.splice(shadowed, 1, e);
    else out.push(e);
  }
  for (const [n, s] of Object.entries(readStash().cursor || {})) {
    if (out.some((e) => e.name === n)) continue;
    out.push({ name: n, raw: s.raw, cfg: normalize(s.raw), scope: "user", source: "Disabled by Bridge", enabled: false, editable: true, removable: true, toggleable: true, sharedWith: ["devin"] });
  }
  return out;
}

const cursorStatuses = new Map();
async function cursorStatus(dir, { refresh = false } = {}) {
  const hit = cursorStatuses.get(dir);
  if (hit && !refresh && Date.now() - hit.at < TTL) return hit.data;
  const r = await sh(bin.cursor(), ["mcp", "list"], { cwd: dir, timeout: 45000 });
  const data = {};
  for (const line of r.out.split("\n")) {
    const m = /^(\S[^:]*):\s*(.+)$/.exec(line.replace(/\x1b\[[0-9;]*m/g, "").trim());
    if (m) data[m[1]] = m[2].trim();
  }
  cursorStatuses.set(dir, { at: Date.now(), data });
  return data;
}

/* ------------------------------------------------------------- Devin */

const devinFile = () => path.join(home(), ".config", "devin", "mcp_config.json");

async function devinEntries() {
  const r = await sh(bin.devin(), ["mcp", "list", "--json"], { timeout: 30000 });
  let list = null;
  try {
    list = JSON.parse(r.out);
  } catch {}
  if (!list) throw new Error(`Couldn't read Devin's servers: ${r.err.split("\n").filter(Boolean).pop() || "devin mcp list failed"}`);
  const stash = readStash();
  const overrides = stash.devin || {};
  const cursorServers = (readJson(cursorFile(), {}) || {}).mcpServers || {};
  const devinServers = (readJson(devinFile(), {}) || {}).mcpServers || {};
  const out = list.map((s) => {
    const raw = s.transport === "stdio" ? { command: s.command, args: s.args } : { url: s.url, type: s.transport };
    const src = String(s.source || "");
    const fromCursor = /\.cursor\/mcp\.json/.test(src) && !/^\./.test(src);
    const plugin = /^plugin /.test(src) || !!overrides[s.name];
    const project = /^\.devin|project/.test(src) && !fromCursor;
    const scope = fromCursor ? "shared" : plugin ? "plugin" : project ? "project" : "user";
    const cursorRaw = fromCursor ? cursorServers[s.name] : null;
    const userRaw = scope === "user" ? devinServers[s.name] : null;
    const full = cursorRaw || userRaw || raw;
    return {
      name: s.name,
      raw: full,
      cfg: normalize(full),
      scope,
      source: plugin && overrides[s.name] ? overrides[s.name].source || "A Devin plugin" : src.replace(/^plugin /, "Plugin ") || tilde(devinFile()),
      enabled: s.enabled !== false,
      editable: scope === "user" || scope === "shared",
      removable: scope === "user" || scope === "shared",
      toggleable: scope !== "project",
      sharedWith: fromCursor ? ["cursor"] : undefined,
      disabledTools: s.disabled_tools || [],
      note: fromCursor ? "Devin loads this from Cursor's ~/.cursor/mcp.json: changes apply to Cursor too" : plugin ? "From a Devin plugin. Disabling adds an override to ~/.config/devin/mcp_config.json" : project ? "From this project's .devin config" : "",
    };
  });
  for (const [n, s] of Object.entries(stash.cursor || {})) {
    if (out.some((e) => e.name === n)) continue;
    out.push({ name: n, raw: s.raw, cfg: normalize(s.raw), scope: "shared", source: "Disabled by Bridge (Cursor's file)", enabled: false, editable: true, removable: true, toggleable: true, sharedWith: ["cursor"], note: "Devin loads this from Cursor's ~/.cursor/mcp.json: changes apply to Cursor too" });
  }
  return out;
}

/* -------------------------------------------------------------- views */

function view(agent, e, status) {
  const key = keyOf(e.cfg);
  const tools = (status && status.tools && status.tools.length ? status.tools : toolsSeen.get(key)) || null;
  return {
    name: e.name,
    agent,
    ...publicConfig(e.cfg),
    scope: e.scope,
    source: e.source,
    enabled: e.enabled,
    editable: !!e.editable,
    removable: !!e.removable,
    toggleable: !!e.toggleable,
    sharedWith: e.sharedWith || [],
    note: e.note || "",
    status: !e.enabled ? "disabled" : (status && status.status) || "unknown",
    error: (e.enabled && status && status.error) || "",
    serverInfo: (status && status.serverInfo) || null,
    toolCount: tools ? tools.length : null,
    tools: tools ? tools.map((t) => ({ name: t.name, readOnly: t.readOnly, destructive: t.destructive })) : null,
    disabledTools: e.disabledTools || [],
    checkedAt: (status && status.at) || 0,
  };
}

/** Why an HTTP handshake's 401 isn't the whole story: the agent signs in
 *  on its own and keeps the token to itself. */
function authAware(agent, e, st, extra) {
  if (!st || st.status !== "needs-auth") return st;
  if (agent === "codex" && /o_?auth|bearer/i.test(e.authStatus || "")) return { ...st, status: "signed-in", error: "" };
  if (agent === "codex" && /not_logged_in/i.test(e.authStatus || "")) return st;
  if (agent === "cursor" && extra && /^ready/.test(extra)) return { ...st, status: "signed-in", error: "" };
  if (agent === "devin") return { ...st, status: "oauth", error: `Signs in through Devin; Bridge can't see its login` };
  return st;
}

async function entriesFor(agent, dir) {
  if (agent === "claude") return claudeEntries(dir).entries;
  if (agent === "codex") return codexEntries(dir);
  if (agent === "cursor") return cursorEntries(dir);
  return devinEntries();
}

const installedCache = new Map();
async function installed(agent) {
  const hit = installedCache.get(agent);
  if (hit && Date.now() - hit.at < 10 * 60_000) return hit.v;
  const r = await sh(bin[agent](), ["--version"], { timeout: 10000 });
  installedCache.set(agent, { at: Date.now(), v: r.ok });
  return r.ok;
}

const checking = new Set();

/** A command a repo's own file defines: Bridge never starts one of those
 *  itself. The agent asks before it runs them; Bridge has no such prompt. */
const repoDefined = (e) => e.scope === "project" && e.cfg.type === "stdio";

/** One agent's servers. Statuses come from the cache; a stale cache starts
 *  a check in the background and a `mcp` bus event says when it's done. */
async function list(agent, { dir, refresh = false } = {}) {
  if (!AGENTS.includes(agent)) throw new Error(`unknown agent: ${agent}`);
  dir = dir || env.targetRepo || home();
  if (!(await installed(agent))) return { agent, label: LABEL[agent], installed: false, servers: [], checking: false, files: [] };
  let entries;
  try {
    entries = (await entriesFor(agent, dir)) || [];
  } catch (e) {
    return { agent, label: LABEL[agent], installed: true, servers: [], checking: false, files: [], dir, error: String(e.message || e) };
  }
  const files = { claude: [tilde(claudeFile())], codex: [tilde(codexFile())], cursor: [tilde(cursorFile())], devin: [tilde(devinFile()), tilde(cursorFile())] }[agent];

  if (agent === "claude") {
    const hit = claudeProbes.get(dir);
    if (refresh || !hit || (!hit.pending && Date.now() - hit.at > 3 * 60_000)) claudeProbe(dir, { refresh });
    const live = hit && !hit.pending ? await hit.promise : null;
    const byName = new Map((live || []).map((s) => [s.name, s]));
    const servers = entries.map((e) => {
      const s = byName.get(e.name);
      const st = s ? { status: s.status === "needs-auth" ? "needs-auth" : s.status, error: s.error || "", serverInfo: s.serverInfo, at: hit.at } : null;
      return view(agent, e, st && st.status === "disabled" ? null : st);
    });
    for (const s of live || []) {
      if (entries.some((e) => e.name === s.name)) continue;
      const scope = s.scope === "claudeai" ? "claudeai" : s.scope === "dynamic" || /plugin/.test(String(s.source || s.scope)) ? "plugin" : String(s.scope || "plugin");
      const cfg = normalize(s.config || {});
      const e = {
        name: s.name,
        cfg,
        scope,
        source: scope === "claudeai" ? "claude.ai connector" : `Plugin${s.source && s.source !== s.scope ? ` · ${s.source}` : ""}`,
        enabled: s.status !== "disabled",
        editable: false,
        removable: false,
        toggleable: true,
        note: scope === "claudeai" ? "Managed on claude.ai. On/off applies to this project" : "From a Claude Code plugin. On/off applies to this project",
      };
      if (s.config && s.config.type === "claudeai-proxy") e.cfg = { type: "http", url: s.config.url || "", headers: {} };
      servers.push(view(agent, e, s.status === "disabled" ? null : { status: s.status, error: s.error || "", serverInfo: s.serverInfo, at: hit.at }));
    }
    return { agent, label: LABEL[agent], installed: true, servers: sortServers(servers), checking: !!(claudeProbes.get(dir) || {}).pending, files, dir };
  }

  const extra = agent === "cursor" ? (cursorStatuses.get(dir) || {}).data || {} : {};
  const stale = entries.filter((e) => e.enabled && !repoDefined(e) && (refresh || !checks.has(keyOf(e.cfg)) || Date.now() - checks.get(keyOf(e.cfg)).at > TTL));
  const flag = `${agent}:${dir}`;
  if ((stale.length || (agent === "cursor" && (refresh || !cursorStatuses.has(dir)))) && !checking.has(flag)) {
    checking.add(flag);
    Promise.all([pool(stale.map((e) => () => check(e.cfg, { refresh }))), agent === "cursor" ? cursorStatus(dir, { refresh }) : null]).finally(() => {
      checking.delete(flag);
      bus.broadcast("mcp", { agent });
    });
  }
  const servers = entries.map((e) => {
    if (repoDefined(e)) return view(agent, e, { status: "unknown", error: "Defined by this repo: Bridge doesn't start it to check" });
    const st = checks.get(keyOf(e.cfg));
    let s = authAware(agent, e, st, extra[e.name]);
    if (agent === "cursor" && extra[e.name] && /requires_authentication/.test(extra[e.name])) s = { ...(s || {}), status: "needs-auth", error: "Cursor needs you to sign in to this server" };
    return view(agent, e, s);
  });
  return { agent, label: LABEL[agent], installed: true, servers: sortServers(servers), checking: checking.has(flag), files, dir };
}

const SCOPE_ORDER = { user: 0, shared: 1, local: 2, project: 3, plugin: 4, claudeai: 5 };
const sortServers = (l) => l.sort((a, b) => (SCOPE_ORDER[a.scope] ?? 9) - (SCOPE_ORDER[b.scope] ?? 9) || a.name.localeCompare(b.name));

/** Every agent at once, for Settings' overview. */
async function all({ dir, refresh = false } = {}) {
  const agents = await Promise.all(AGENTS.map((a) => list(a, { dir, refresh }).catch((e) => ({ agent: a, label: LABEL[a], installed: false, servers: [], error: String(e.message || e) }))));
  return { agents };
}

/** A server's tools with descriptions and parameters. */
async function tools(agent, name, { dir, refresh = false } = {}) {
  dir = dir || env.targetRepo || home();
  const entries = (await entriesFor(agent, dir)) || [];
  let e = entries.find((x) => x.name === name);
  if (!e && agent === "claude") {
    const live = (await claudeProbe(dir)) || [];
    const s = live.find((x) => x.name === name);
    if (s) e = { name, cfg: s.config && s.config.type !== "claudeai-proxy" ? normalize(s.config) : { type: "http", url: (s.config || {}).url || "", headers: {} }, claudeOnly: s.config && s.config.type === "claudeai-proxy" };
  }
  if (!e) throw new Error(`no MCP server called ${name}`);
  const key = keyOf(e.cfg);
  const known = toolsSeen.get(key);
  // Off, or a repo's own command: what's known, never a fresh start.
  if (e.enabled === false || repoDefined(e)) {
    if (known) return { name, tools: known, source: "cache", note: e.enabled === false ? "Last seen while it was on" : "" };
    return { name, tools: [], source: "none", status: e.enabled === false ? "disabled" : "unknown", error: e.enabled === false ? "Turn it on to list its tools" : "Defined by this repo: Bridge doesn't start it. Ask the agent, which asks you before running it" };
  }
  if (known && known.some((t) => t.description) && !refresh) return { name, tools: known, source: "server" };
  const r = e.claudeOnly ? { status: "needs-auth" } : await check(e.cfg, { refresh: true });
  if (r && r.tools && r.tools.length) return { name, tools: r.tools, source: "server" };
  const fallback = toolsSeen.get(key);
  if (fallback) return { name, tools: fallback, source: "claude", note: "Names from Claude's live session; this server didn't let Bridge in to read descriptions" };
  return { name, tools: [], source: "none", error: (r && r.error) || "Couldn't list this server's tools", status: (r && r.status) || "failed" };
}

/* ---------------------------------------------------------- mutations */

const NAME = /^[A-Za-z0-9][A-Za-z0-9 _.@:-]{0,63}$/;

/** The form's fields → a config, keeping secret values the form left blank. */
function fromForm(form, prev) {
  const type = form.type === "http" || form.type === "sse" ? form.type : "stdio";
  const keep = (kind, list, carry = true) => {
    const old = (carry && prev && prev[kind]) || {};
    const out = {};
    for (const { key, value } of list || []) {
      const k = String(key || "").trim();
      if (!k) continue;
      if (!/^[A-Za-z_][A-Za-z0-9_-]*$/.test(k) && kind === "env") throw new Error(`bad variable name: ${k}`);
      out[k] = value == null || value === "" ? old[k] ?? "" : String(value);
    }
    return out;
  };
  if (type === "stdio") {
    const command = String(form.command || "").trim();
    if (!command) throw new Error("a stdio server needs a command");
    const args = Array.isArray(form.args) ? form.args.map(String).filter((a) => a !== "") : [];
    const cfg = { type, command, args, env: keep("env", form.env) };
    // The form has no working-folder field: an edit keeps the one it had.
    const cwd = form.cwd != null ? String(form.cwd) : (prev && prev.cwd) || "";
    if (cwd) cfg.cwd = cwd;
    return cfg;
  }
  const url = String(form.url || "").trim();
  if (!/^https?:\/\/\S+$/.test(url)) throw new Error("a remote server needs an http(s) URL");
  const cfg = { type, url, headers: keep("headers", form.headers, !!prev && !!prev.url && hostOf(expand(prev.url)) === hostOf(expand(url))) };
  if (form.bearerEnv) cfg.bearerEnv = String(form.bearerEnv).trim();
  return cfg;
}

/** A config in the shape each agent's own file uses, layered over the old
 *  entry so keys Bridge doesn't edit survive. */
function toRaw(agent, cfg, prevRaw = {}) {
  const base = { ...(prevRaw || {}) };
  for (const k of ["command", "args", "env", "cwd", "url", "headers", "type", "transport", "serverUrl"]) delete base[k];
  if (cfg.type === "stdio") {
    const out = { ...base, command: cfg.command, args: cfg.args };
    if (agent === "claude") out.type = "stdio";
    if (Object.keys(cfg.env).length) out.env = cfg.env;
    if (cfg.cwd) out.cwd = cfg.cwd;
    return out;
  }
  const out = { ...base, url: cfg.url };
  if (agent === "claude") out.type = cfg.type;
  if (agent === "devin") out.transport = cfg.type;
  if (agent === "cursor" && cfg.type === "sse") out.type = "sse";
  if (Object.keys(cfg.headers).length) out.headers = cfg.headers;
  return out;
}

const invalidate = (agent) => {
  codexLists.clear();
  cursorStatuses.clear();
  if (agent === "claude") claudeProbes.clear();
  bus.broadcast("mcp", { agent });
};

async function claudeCli(args, dir) {
  const r = await sh(bin.claude(), ["mcp", ...args], { cwd: dir, timeout: 30000 });
  if (!r.ok) throw new Error(r.err.split("\n").filter(Boolean).pop() || "claude mcp failed");
}

/** Add (no `original`) or edit a server. */
async function save(agent, { name, original, form }, { dir } = {}) {
  dir = dir || env.targetRepo || home();
  name = String(name || "").trim();
  if (!NAME.test(name)) throw new Error("names are letters, digits, spaces and . _ - @ : (up to 64)");
  const entries = (await entriesFor(agent, dir)) || [];
  const prev = original ? entries.find((e) => e.name === original) : null;
  if (original && !prev) throw new Error(`no MCP server called ${original}`);
  if (prev && !prev.editable) throw new Error(prev.note || `${original} can't be edited from Bridge`);
  if ((!prev || name !== original) && entries.some((e) => e.name === name)) throw new Error(`${LABEL[agent]} already has a server called ${name}`);
  const cfg = fromForm(form || {}, prev && prev.cfg);
  const stashed = prev && !prev.enabled && prev.source.startsWith("Disabled by Bridge");

  if (agent === "claude") {
    const scope = prev ? prev.scope : "user";
    const raw = toRaw(agent, cfg, prev && prev.raw);
    if (stashed) {
      editStash((s) => {
        delete (s.claude || {})[prev.stashKey || original];
        (s.claude = s.claude || {})[scope === "local" ? `${realDir(dir)}::${name}` : name] = { name, scope, dir: realDir(dir), raw };
      });
    } else {
      if (prev) await claudeCli(["remove", "-s", scope, original], dir);
      try {
        await claudeCli(["add-json", "-s", scope, name, JSON.stringify(raw)], dir);
      } catch (err) {
        if (prev) await claudeCli(["add-json", "-s", scope, original, JSON.stringify(prev.raw)], dir).catch(() => {});
        throw err;
      }
    }
  } else if (agent === "codex") {
    const file = codexFile();
    let text = fs.existsSync(file) ? fs.readFileSync(file, "utf8") : "";
    if (prev && name !== original) {
      text = codexEdit(text, original, { remove: true });
      text = codexEdit(text, name, { cfg, enabled: prev.enabled });
    } else text = codexEdit(text, name, { cfg });
    writeTextAtomic(file, text);
  } else if (agent === "cursor" || (agent === "devin" && (!prev || prev.scope === "shared"))) {
    // Devin's new servers land in its own file; shared ones stay in Cursor's.
    const useCursor = agent === "cursor" || (prev && prev.scope === "shared");
    const file = useCursor ? cursorFile() : devinFile();
    const flavour = useCursor ? "cursor" : "devin";
    if (stashed) {
      editStash((s) => {
        delete (s.cursor || {})[original];
        (s.cursor = s.cursor || {})[name] = { raw: toRaw(flavour, cfg, prev.raw) };
      });
    } else {
      const j = readJsonStrict(file);
      j.mcpServers = j.mcpServers || {};
      const raw = toRaw(flavour, cfg, prev && j.mcpServers[original]);
      if (prev && name !== original) delete j.mcpServers[original];
      j.mcpServers[name] = raw;
      writeJsonAtomic(file, j);
    }
  } else {
    const file = devinFile();
    const j = readJsonStrict(file);
    j.mcpServers = j.mcpServers || {};
    const raw = toRaw("devin", cfg, j.mcpServers[original]);
    if (name !== original) delete j.mcpServers[original];
    j.mcpServers[name] = raw;
    writeJsonAtomic(file, j);
  }
  invalidate(agent);
  if (agent === "cursor" || agent === "devin") invalidate(agent === "cursor" ? "devin" : "cursor");
  return { name };
}

async function remove(agent, name, { dir } = {}) {
  dir = dir || env.targetRepo || home();
  const entries = (await entriesFor(agent, dir)) || [];
  const e = entries.find((x) => x.name === name);
  if (!e) throw new Error(`no MCP server called ${name}`);
  if (!e.removable) throw new Error(e.note || `${name} can't be removed from Bridge`);
  const stashed = !e.enabled && e.source.startsWith("Disabled by Bridge");
  if (agent === "claude") {
    if (stashed) editStash((s) => delete (s.claude || {})[e.stashKey || name]);
    else await claudeCli(["remove", "-s", e.scope, name], dir);
  } else if (agent === "codex") {
    writeTextAtomic(codexFile(), codexEdit(fs.readFileSync(codexFile(), "utf8"), name, { remove: true }));
  } else {
    const useCursor = agent === "cursor" || e.scope === "shared";
    if (stashed) editStash((s) => delete (s.cursor || {})[name]);
    else {
      const file = useCursor ? cursorFile() : devinFile();
      const j = readJsonStrict(file);
      delete (j.mcpServers || {})[name];
      writeJsonAtomic(file, j);
    }
  }
  invalidate(agent);
  if (agent !== "claude" && agent !== "codex") invalidate(agent === "cursor" ? "devin" : "cursor");
  return { removed: name };
}

async function setEnabled(agent, name, on, { dir } = {}) {
  dir = dir || env.targetRepo || home();
  const entries = (await entriesFor(agent, dir)) || [];
  let e = entries.find((x) => x.name === name);
  if (!e && agent === "claude") e = { name, scope: "claudeai", toggleable: true, enabled: !on };
  if (!e) throw new Error(`no MCP server called ${name}`);
  if (!e.toggleable) throw new Error(e.note || `${name} can't be switched from Bridge`);

  if (agent === "claude") {
    if (e.scope === "user" || e.scope === "local") {
      // Stash: out of Claude's config (so it's off everywhere), back on enable.
      const stashKey = e.scope === "local" ? `${realDir(dir)}::${name}` : name;
      if (!on && e.enabled) {
        // Stashed first, so a failed remove never loses the entry.
        editStash((s) => ((s.claude = s.claude || {})[stashKey] = { name, scope: e.scope, dir: realDir(dir), raw: e.raw }));
        try {
          await claudeCli(["remove", "-s", e.scope, name], dir);
        } catch (err) {
          editStash((s) => delete s.claude[stashKey]);
          throw err;
        }
      } else if (on) {
        const k = e.stashKey || stashKey;
        const s = (readStash().claude || {})[k];
        if (s) {
          await claudeCli(["add-json", "-s", s.scope, name, JSON.stringify(s.raw)], s.scope === "local" ? s.dir || dir : dir);
          editStash((x) => delete x.claude[k]);
        }
        const j = readJson(claudeFile(), {}) || {};
        if (((j.projects || {})[realDir(dir)] || {}).disabledMcpServers?.includes(name)) {
          const r = await claudeToggle(dir, name, true);
          if (!r.ok) throw new Error(r.error);
        }
      }
    } else {
      const r = await claudeToggle(dir, name, on);
      if (!r.ok) throw new Error(r.error);
    }
  } else if (agent === "codex") {
    writeTextAtomic(codexFile(), codexEdit(fs.readFileSync(codexFile(), "utf8"), name, { enabled: on }));
  } else if (agent === "cursor" || e.scope === "shared") {
    if (!on && e.enabled) {
      const j = readJsonStrict(cursorFile());
      const raw = (j.mcpServers || {})[name];
      if (!raw) throw new Error(`${name} isn't in ${tilde(cursorFile())}`);
      editStash((s) => ((s.cursor = s.cursor || {})[name] = { raw }));
      delete j.mcpServers[name];
      writeJsonAtomic(cursorFile(), j);
    } else if (on) {
      const s = (readStash().cursor || {})[name];
      if (s) {
        const j = readJsonStrict(cursorFile());
        (j.mcpServers = j.mcpServers || {})[name] = s.raw;
        writeJsonAtomic(cursorFile(), j);
        editStash((x) => delete x.cursor[name]);
      }
    }
  } else if (e.scope === "plugin") {
    // Devin's documented override: a disabled entry of the same name.
    const j = readJsonStrict(devinFile());
    j.mcpServers = j.mcpServers || {};
    if (!on) {
      j.mcpServers[name] = { ...toRaw("devin", e.cfg), disabled: true };
      editStash((s) => ((s.devin = s.devin || {})[name] = { source: e.source }));
    } else {
      if (j.mcpServers[name] && j.mcpServers[name].disabled) delete j.mcpServers[name];
      editStash((s) => delete (s.devin || {})[name]);
    }
    writeJsonAtomic(devinFile(), j);
  } else {
    const r = await sh(bin.devin(), ["mcp", on ? "enable" : "disable", "-s", "user", name], { timeout: 30000 });
    if (!r.ok) throw new Error(r.err.split("\n").filter(Boolean)[0] || "devin mcp failed");
  }
  invalidate(agent);
  if (agent === "cursor" || e.scope === "shared") invalidate(agent === "cursor" ? "devin" : "cursor");
  return { name, enabled: on };
}

/** Start the agent's own OAuth sign-in for a server (it opens the browser). */
async function login(agent, name, { dir } = {}) {
  if (!AGENTS.includes(agent)) throw new Error(`unknown agent: ${agent}`);
  if (!NAME.test(String(name || ""))) throw new Error("bad server name");
  const child = spawn(bin[agent](), ["mcp", "login", name], { cwd: dir && fs.existsSync(dir) ? dir : home(), env: cliEnv(), stdio: ["ignore", "ignore", "pipe"], detached: false });
  let errOut = "";
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (c) => (errOut = (errOut + c).slice(-2000)));
  // Started, or failed right away (not installed, unknown server): say which.
  await new Promise((resolve, reject) => {
    const early = setTimeout(resolve, 1500);
    child.once("error", (e) => {
      clearTimeout(early);
      reject(new Error(e.code === "ENOENT" ? `${LABEL[agent]} isn't installed` : e.message));
    });
    child.once("exit", (code) => {
      clearTimeout(early);
      if (code) reject(new Error(errOut.trim().split("\n").filter(Boolean).pop() || `${LABEL[agent]} couldn't start the sign-in`));
      else resolve();
    });
  });
  const timer = setTimeout(() => {
    try {
      child.kill();
    } catch {}
  }, 5 * 60_000);
  child.on("close", () => {
    clearTimeout(timer);
    for (const a of AGENTS) invalidate(a);
    checks.clear();
  });
  return { started: true };
}

module.exports = { AGENTS, list, all, tools, save, remove, setEnabled, login, handshake, normalize, codexEdit, tomlPath, fromForm, toRaw, keyOf };
