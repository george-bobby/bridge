/**
 * Chats you had with an agent outside Bridge, read from the agent's own
 * history on this Mac, and imported as a worker that carries on in the same
 * agent session.
 *
 *   Claude Code  ~/.claude/projects/<cwd>/<session>.jsonl      resumed with --resume (from the same cwd)
 *   Codex        ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl  codex exec resume <id>
 *   Cursor       ~/.cursor/chats/<hash>/<chat>/store.db         cursor-agent --resume <id>
 *   Devin        ~/.local/share/devin/cli/sessions.db           devin -r <id>
 *
 * Everything here is read-only: the files belong to the agents. Cursor and
 * Devin keep SQLite databases, read with node:sqlite (Node 22.5+) or the
 * sqlite3 CLI; without either those two simply list nothing.
 * BRIDGE_HISTORY_HOME points every path at a scratch home in tests.
 */

const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");

const HOME = () => process.env.BRIDGE_HISTORY_HOME || os.homedir();
const LIST_MAX = 400;
const MSG_MAX = 600;
const STEPS_MAX = 200;
const RESULT_MAX = 6000;

const AGENTS = ["claude", "codex", "cursor", "devin"];

/* ------------------------------------------------------------------ files */

function readHead(file, bytes) {
  let fd;
  try {
    fd = fs.openSync(file, "r");
    const buf = Buffer.alloc(bytes);
    const n = fs.readSync(fd, buf, 0, bytes, 0);
    return buf.subarray(0, n).toString("utf8");
  } catch {
    return "";
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
}

function readTail(file, bytes, size) {
  let fd;
  try {
    fd = fs.openSync(file, "r");
    const start = Math.max(0, size - bytes);
    const buf = Buffer.alloc(Math.min(bytes, size));
    const n = fs.readSync(fd, buf, 0, buf.length, start);
    return buf.subarray(0, n).toString("utf8");
  } catch {
    return "";
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
}

/** JSON lines, skipping the partial first/last line a byte window cuts. */
function jsonLines(text) {
  const out = [];
  for (const l of String(text).split("\n")) {
    if (!l.trim()) continue;
    try {
      out.push(JSON.parse(l));
    } catch {}
  }
  return out;
}

function ls(dir) {
  try {
    return fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return [];
  }
}

function stat(file) {
  try {
    return fs.statSync(file);
  } catch {
    return null;
  }
}

/* ----------------------------------------------------------------- sqlite */

let nodeSqlite;
function sqliteModule() {
  if (nodeSqlite !== undefined) return nodeSqlite;
  // node:sqlite prints an ExperimentalWarning on load; it's expected here.
  const emit = process.emitWarning;
  process.emitWarning = () => {};
  try {
    nodeSqlite = require("node:sqlite");
  } catch {
    nodeSqlite = null;
  } finally {
    process.emitWarning = emit;
  }
  return nodeSqlite;
}

let cliChecked;
function hasSqliteCli() {
  if (cliChecked !== undefined) return cliChecked;
  try {
    execFileSync("sqlite3", ["-version"], { stdio: "ignore", timeout: 5000 });
    cliChecked = true;
  } catch {
    cliChecked = false;
  }
  return cliChecked;
}

/** Rows of a read-only query. `?` params are inlined for the CLI (strings only). */
function query(db, sql, params = []) {
  if (!stat(db)) return [];
  const m = sqliteModule();
  if (m && m.DatabaseSync) {
    let conn;
    try {
      conn = new m.DatabaseSync(db, { readOnly: true });
      return conn.prepare(sql).all(...params);
    } catch {
      // An older node:sqlite without readOnly, or a locked file: try the CLI.
    } finally {
      try {
        if (conn) conn.close();
      } catch {}
    }
  }
  if (!hasSqliteCli()) return [];
  let i = 0;
  const inlined = sql.replace(/\?/g, () => `'${String(params[i++]).replace(/'/g, "''")}'`);
  try {
    const out = execFileSync("sqlite3", ["-readonly", "-json", db, inlined], { encoding: "utf8", timeout: 20000, maxBuffer: 256e6 });
    return out.trim() ? JSON.parse(out) : [];
  } catch {
    return [];
  }
}

/* ---------------------------------------------------------------- helpers */

const clip = (s, n) => {
  const t = String(s == null ? "" : s);
  return t.length > n ? `${t.slice(0, n - 1)}…` : t;
};
const oneLine = (s) => String(s || "").replace(/\s+/g, " ").trim();
const secs = (v) => {
  if (v == null || v === "") return 0;
  if (typeof v === "number") return v > 1e12 ? Math.floor(v / 1000) : Math.floor(v);
  const t = Date.parse(v);
  return Number.isFinite(t) ? Math.floor(t / 1000) : 0;
};

/** The words you typed, without the wrappers agents put around them. */
function cleanPrompt(text) {
  let t = String(text || "");
  const cmd = t.match(/<command-name>([^<]*)<\/command-name>/);
  if (cmd) {
    const args = (t.match(/<command-args>([\s\S]*?)<\/command-args>/) || [])[1] || "";
    return `${cmd[1].trim()} ${args.trim()}`.trim();
  }
  const q = t.match(/<user_query>([\s\S]*?)<\/user_query>/);
  if (q) t = q[1];
  return t.replace(/<timestamp>[\s\S]*?<\/timestamp>/g, "").trim();
}

/** Injected context rather than something you said. */
function isNoise(text) {
  const t = String(text || "").trimStart();
  return (
    !t ||
    /^<(system-reminder|local-command|environment_context|user_instructions|instructions|permissions|user_info|system_info|rules|available_rules|available_skills|bash_mode|system_guidance|INSTRUCTIONS)\b/i.test(t) ||
    t.startsWith("Caveat: The messages below") ||
    t.startsWith("# AGENTS.md instructions") ||
    t.startsWith("Base directory for this skill:") ||
    t.startsWith("[Request interrupted")
  );
}

function describe(name, input) {
  const i = input && typeof input === "object" ? input : {};
  const first = i.command || i.cmd || i.file_path || i.path || i.pattern || i.query || i.url || i.description || i.prompt || Object.values(i).find((v) => typeof v === "string");
  if (Array.isArray(first)) return clip(first.join(" "), 200);
  return clip(oneLine(first || (typeof input === "string" ? input : "")), 200);
}

function resultText(v) {
  if (v == null) return "";
  if (typeof v === "string") return v;
  if (Array.isArray(v)) return v.map((x) => (typeof x === "string" ? x : x && (x.text || x.output || (x.type === "image" ? "[image]" : "")))).filter(Boolean).join("\n");
  if (typeof v === "object") return resultText(v.output || v.content || v.text || v.result || JSON.stringify(v));
  return String(v);
}

/**
 * Builds Bridge's transcript shape: your messages, and one assistant message
 * per turn (everything the agent did until you spoke again).
 */
function transcript(agent, model, workdir) {
  const messages = [];
  let turn = null;
  const tools = new Map();
  let lastTs = 0;
  const endTurn = () => {
    if (turn && turn.steps.length) {
      // A marathon turn keeps its latest steps: that's where the work stands.
      if (turn.steps.length > STEPS_MAX) {
        const cut = turn.steps.length - STEPS_MAX;
        turn.steps = [{ kind: "text", text: `_${cut} earlier steps of this turn aren't shown._` }, ...turn.steps.slice(cut)];
      }
      const texts = turn.steps.filter((s) => s.kind === "text").map((s) => s.text);
      turn.text = texts[texts.length - 1] || "";
      messages.push(turn);
    }
    turn = null;
  };
  return {
    user(text, ts) {
      const t = cleanPrompt(text);
      if (isNoise(t)) return;
      endTurn();
      lastTs = ts || lastTs;
      messages.push({ role: "user", text: clip(t, 20000), ts: lastTs, imported: true });
    },
    step(step, ts, m) {
      lastTs = ts || lastTs;
      if (!turn) turn = { role: "assistant", kind: "imported", label: "imported", agent, model: m || model || "", state: "done", workdir, steps: [], ts: lastTs, imported: true };
      if (m && !turn.model) turn.model = m;
      if (turn.steps.length >= STEPS_MAX * 5) return;
      if (step.kind === "text" || step.kind === "thinking") {
        const prev = turn.steps[turn.steps.length - 1];
        if (!step.text) return;
        if (prev && prev.kind === step.kind) prev.text += `\n\n${step.text}`;
        else turn.steps.push({ kind: step.kind, text: step.text });
        return;
      }
      const s = { kind: "tool", name: step.name || "tool", detail: step.detail || "", id: step.id || "", raw: clip(JSON.stringify(step.input == null ? {} : step.input), /^(TodoWrite|todo_write|update_plan)$/.test(step.name || "") ? 40000 : 2000) };
      turn.steps.push(s);
      if (s.id) tools.set(s.id, s);
    },
    result(id, value, ok = true) {
      const s = tools.get(id);
      if (!s) return;
      const body = clip(resultText(value), RESULT_MAX);
      s.result = body;
      s.ok = ok;
      s.resultLines = body.trim() ? body.trim().split("\n").length : 0;
    },
    done() {
      endTurn();
      return messages.slice(-MSG_MAX);
    },
  };
}

/* ------------------------------------------------------------ Claude Code */

const claudeDir = () => path.join(process.env.BRIDGE_HISTORY_HOME ? path.join(HOME(), ".claude") : process.env.CLAUDE_CONFIG_DIR || path.join(HOME(), ".claude"), "projects");

function claudeFiles() {
  const out = [];
  for (const d of ls(claudeDir())) {
    if (!d.isDirectory()) continue;
    const dir = path.join(claudeDir(), d.name);
    for (const f of ls(dir)) {
      if (!f.isFile() || !f.name.endsWith(".jsonl")) continue;
      const file = path.join(dir, f.name);
      const st = stat(file);
      if (st && st.size > 0) out.push({ file, id: f.name.slice(0, -6), mtime: st.mtimeMs, size: st.size });
    }
  }
  return out;
}

function claudePromptOf(e) {
  if (!e || e.type !== "user" || e.isMeta || e.isSidechain || !e.message) return "";
  const c = e.message.content;
  const text = typeof c === "string" ? c : Array.isArray(c) ? c.filter((b) => b.type === "text").map((b) => b.text).join("\n") : "";
  const t = cleanPrompt(text);
  return isNoise(t) ? "" : t;
}

function claudeSummary(f) {
  const head = jsonLines(readHead(f.file, 512 * 1024));
  const tail = f.size > 512 * 1024 ? jsonLines(readTail(f.file, 256 * 1024, f.size)) : head;
  let cwd = "";
  let prompt = "";
  let created = 0;
  let branch = "";
  for (const e of head) {
    if (!cwd && e.cwd) cwd = e.cwd;
    if (!branch && e.gitBranch) branch = e.gitBranch;
    if (!created && e.timestamp) created = secs(e.timestamp);
    if (!prompt) prompt = claudePromptOf(e);
    if (cwd && prompt && created) break;
  }
  if (!prompt) return null;
  let title = "";
  for (const e of [...head, ...tail]) {
    if (e.type === "custom-title" && e.customTitle) title = e.customTitle;
    else if (e.type === "ai-title" && e.aiTitle && !title) title = e.aiTitle;
    else if (e.type === "summary" && e.summary && !title) title = e.summary;
  }
  for (const e of tail) if (e.type === "custom-title" && e.customTitle) title = e.customTitle;
  return { agent: "claude", id: f.id, title: oneLine(title) || clip(oneLine(prompt), 90), prompt: clip(oneLine(prompt), 240), cwd, branch, createdAt: created || Math.floor(f.mtime / 1000), updatedAt: Math.floor(f.mtime / 1000), size: f.size };
}

function claudeRead(id) {
  const f = claudeFiles().find((x) => x.id === id);
  if (!f) throw new Error("no such Claude Code session");
  const lines = jsonLines(fs.readFileSync(f.file, "utf8"));
  const cwd = (lines.find((e) => e.cwd) || {}).cwd || "";
  const t = transcript("claude", "", cwd);
  for (const e of lines) {
    if (e.isSidechain || !e.message) continue;
    const ts = secs(e.timestamp);
    const c = e.message.content;
    if (e.type === "user") {
      if (e.isMeta) continue;
      if (typeof c === "string") t.user(c, ts);
      else if (Array.isArray(c)) {
        for (const b of c) if (b.type === "tool_result") t.result(b.tool_use_id, b.content, !b.is_error);
        const text = c.filter((b) => b.type === "text").map((b) => b.text).join("\n");
        if (text) t.user(text + (c.some((b) => b.type === "image") ? "\n\n[image]" : ""), ts);
      }
    } else if (e.type === "assistant" && Array.isArray(c)) {
      const model = e.message.model && e.message.model !== "<synthetic>" ? e.message.model : "";
      for (const b of c) {
        if (b.type === "text") t.step({ kind: "text", text: b.text }, ts, model);
        else if (b.type === "thinking") t.step({ kind: "thinking", text: b.thinking }, ts, model);
        else if (b.type === "tool_use") t.step({ kind: "tool", name: b.name, id: b.id, input: b.input, detail: describe(b.name, b.input) }, ts, model);
      }
    }
  }
  return { cwd, messages: t.done() };
}

/* ------------------------------------------------------------------ Codex */

const codexDir = () => path.join(process.env.BRIDGE_HISTORY_HOME ? path.join(HOME(), ".codex") : process.env.CODEX_HOME || path.join(HOME(), ".codex"), "sessions");

function codexFiles() {
  const out = [];
  const walk = (dir, depth) => {
    for (const d of ls(dir)) {
      const p = path.join(dir, d.name);
      if (d.isDirectory() && depth < 4) walk(p, depth + 1);
      else if (d.isFile() && /^rollout-.*\.jsonl$/.test(d.name)) {
        const st = stat(p);
        const id = (d.name.match(/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$/) || [])[1] || d.name;
        if (st && st.size > 0) out.push({ file: p, id, mtime: st.mtimeMs, size: st.size });
      }
    }
  };
  walk(codexDir(), 0);
  return out;
}

function codexText(content) {
  return (Array.isArray(content) ? content : [])
    .map((b) => (typeof b === "string" ? b : b.text || ""))
    .filter(Boolean)
    .join("\n");
}

function codexSummary(f) {
  const head = jsonLines(readHead(f.file, 384 * 1024));
  let cwd = "";
  let created = 0;
  let id = f.id;
  let prompt = "";
  for (const e of head) {
    const p = e.payload || {};
    if (e.type === "session_meta") {
      cwd = p.cwd || cwd;
      id = p.id || p.session_id || id;
      created = secs(p.timestamp || e.timestamp);
    } else if (!prompt && e.type === "response_item" && p.type === "message" && p.role === "user") {
      const t = cleanPrompt(codexText(p.content));
      if (!isNoise(t)) prompt = t;
    } else if (!prompt && e.type === "event_msg" && p.type === "user_message" && p.message) {
      const t = cleanPrompt(p.message);
      if (!isNoise(t)) prompt = t;
    }
    if (prompt && cwd) break;
  }
  if (!prompt) return null;
  return { agent: "codex", id, title: clip(oneLine(prompt), 90), prompt: clip(oneLine(prompt), 240), cwd, branch: "", createdAt: created || Math.floor(f.mtime / 1000), updatedAt: Math.floor(f.mtime / 1000), size: f.size };
}

function codexRead(id) {
  const f = codexFiles().find((x) => x.id === id) || codexFiles().find((x) => (codexSummary(x) || {}).id === id);
  if (!f) throw new Error("no such Codex session");
  const lines = jsonLines(fs.readFileSync(f.file, "utf8"));
  const meta = (lines.find((e) => e.type === "session_meta") || {}).payload || {};
  const cwd = meta.cwd || "";
  let model = "";
  const t = transcript("codex", "", cwd);
  for (const e of lines) {
    const p = e.payload || {};
    const ts = secs(e.timestamp);
    if (e.type === "turn_context" && p.model) model = p.model;
    if (e.type !== "response_item") continue;
    if (p.type === "message" && p.role === "user") t.user(codexText(p.content), ts);
    else if (p.type === "message" && p.role === "assistant") t.step({ kind: "text", text: codexText(p.content) }, ts, model);
    else if (p.type === "reasoning") t.step({ kind: "thinking", text: (p.summary || []).map((s) => s.text || "").join("\n") }, ts, model);
    else if (p.type === "function_call" || p.type === "custom_tool_call" || p.type === "local_shell_call") {
      let input = p.input != null ? p.input : p.arguments;
      if (typeof input === "string") {
        try {
          input = JSON.parse(input);
        } catch {}
      }
      if (p.type === "local_shell_call") input = p.action || {};
      t.step({ kind: "tool", name: p.name || "shell", id: p.call_id || p.id, input, detail: describe(p.name, input) }, ts, model);
    } else if (p.type === "function_call_output" || p.type === "custom_tool_call_output" || p.type === "local_shell_call_output") {
      t.result(p.call_id, p.output);
    }
  }
  return { cwd, model, messages: t.done() };
}

/* ----------------------------------------------------------------- Cursor */

const cursorDir = () => path.join(HOME(), ".cursor", "chats");

function cursorFiles() {
  const out = [];
  for (const h of ls(cursorDir())) {
    if (!h.isDirectory()) continue;
    for (const c of ls(path.join(cursorDir(), h.name))) {
      const dir = path.join(cursorDir(), h.name, c.name);
      const db = path.join(dir, "store.db");
      const st = stat(db);
      if (!c.isDirectory() || !st) continue;
      let meta = {};
      try {
        meta = JSON.parse(fs.readFileSync(path.join(dir, "meta.json"), "utf8"));
      } catch {}
      if (meta.hasConversation === false) continue;
      out.push({ id: c.name, db, meta, mtime: meta.updatedAtMs || st.mtimeMs, size: st.size });
    }
  }
  return out;
}

/** The chat's meta row: hex-encoded JSON with its name and root blob. */
function cursorMeta(db) {
  const row = query(db, "select value from meta where key = '0'")[0];
  if (!row) return {};
  try {
    const v = String(row.value);
    return JSON.parse(/^[0-9a-f]+$/i.test(v) ? Buffer.from(v, "hex").toString("utf8") : v);
  } catch {
    return {};
  }
}

/** Message blob ids, in order: field 1 of the root blob, 32 bytes each. */
function cursorOrder(root) {
  const ids = [];
  let i = 0;
  while (i + 2 <= root.length && root[i] === 0x0a && root[i + 1] === 0x20) {
    ids.push(root.subarray(i + 2, i + 34).toString("hex"));
    i += 34;
  }
  return ids;
}

function blobOf(v) {
  if (v == null) return Buffer.alloc(0);
  if (Buffer.isBuffer(v)) return v;
  if (v instanceof Uint8Array) return Buffer.from(v);
  return Buffer.from(String(v), /^[0-9a-f]*$/i.test(String(v)) ? "hex" : "utf8");
}

function cursorMessages(db) {
  const meta = cursorMeta(db);
  const rows = query(db, "select id, hex(data) as data from blobs");
  const blobs = new Map(rows.map((r) => [r.id, blobOf(r.data)]));
  const root = blobs.get(meta.latestRootBlobId);
  const order = root ? cursorOrder(root) : [];
  const out = [];
  for (const id of order) {
    const b = blobs.get(id);
    if (!b) continue;
    try {
      out.push(JSON.parse(b.toString("utf8")));
    } catch {}
  }
  return { meta, messages: out };
}

function cursorPromptOf(m) {
  if (!m || m.role !== "user") return "";
  const text = typeof m.content === "string" ? m.content : (m.content || []).filter((b) => b.type === "text").map((b) => b.text).join("\n");
  const t = cleanPrompt(text);
  return isNoise(t) ? "" : t;
}

function cursorSummary(f) {
  const meta = cursorMeta(f.db);
  let prompt = "";
  if (!meta.name || meta.name === "New Agent") prompt = (cursorMessages(f.db).messages.map(cursorPromptOf).find(Boolean)) || "";
  const title = meta.name && meta.name !== "New Agent" ? meta.name : prompt;
  if (!title) return null;
  return { agent: "cursor", id: f.id, title: clip(oneLine(title), 90), prompt: clip(oneLine(prompt || title), 240), cwd: f.meta.cwd || "", branch: "", createdAt: secs(f.meta.createdAtMs || meta.createdAt) || Math.floor(f.mtime / 1000), updatedAt: Math.floor(f.mtime / 1000), size: f.size };
}

function cursorRead(id) {
  const f = cursorFiles().find((x) => x.id === id);
  if (!f) throw new Error("no such Cursor chat");
  const { messages } = cursorMessages(f.db);
  const cwd = f.meta.cwd || "";
  const ts = secs(f.meta.updatedAtMs) || Math.floor(f.mtime / 1000);
  const t = transcript("cursor", "", cwd);
  for (const m of messages) {
    const content = typeof m.content === "string" ? [{ type: "text", text: m.content }] : m.content || [];
    if (m.role === "user") t.user(content.filter((b) => b.type === "text").map((b) => b.text).join("\n"), ts);
    else if (m.role === "assistant") {
      for (const b of content) {
        const model = (((b.providerOptions || {}).cursor || {}).modelName) || "";
        if (b.type === "text") t.step({ kind: "text", text: b.text }, ts, model);
        else if (b.type === "reasoning" && b.text) t.step({ kind: "thinking", text: b.text }, ts, model);
        else if (b.type === "tool-call") t.step({ kind: "tool", name: b.toolName, id: b.toolCallId, input: b.args, detail: describe(b.toolName, b.args) }, ts, model);
      }
    } else if (m.role === "tool") {
      for (const b of content) if (b.type === "tool-result") t.result(b.toolCallId, b.result != null ? b.result : b.output, !b.isError);
    }
  }
  return { cwd, messages: t.done() };
}

/* ------------------------------------------------------------------ Devin */

const devinDb = () => path.join(HOME(), ".local", "share", "devin", "cli", "sessions.db");

function devinSummaries() {
  // One query, first prompts included: the CLI fallback is a subprocess per query.
  const rows = query(
    devinDb(),
    "select s.id, s.working_directory, s.title, s.created_at, s.last_activity_at, (select p.content from prompt_history p where p.session_id = s.id and p.is_shell = 0 order by p.timestamp asc limit 1) as first from sessions s where s.hidden = 0 order by s.last_activity_at desc limit 400"
  );
  const out = [];
  for (const r of rows) {
    const prompt = r.first ? cleanPrompt(r.first) : "";
    const title = r.title || prompt;
    if (!title) continue;
    out.push({ agent: "devin", id: r.id, title: clip(oneLine(title), 90), prompt: clip(oneLine(prompt || title), 240), cwd: r.working_directory || "", branch: "", createdAt: secs(r.created_at), updatedAt: secs(r.last_activity_at), size: 0 });
  }
  return out;
}

function devinRead(id) {
  const s = query(devinDb(), "select id, working_directory, model, main_chain_id from sessions where id = ?", [id])[0];
  if (!s) throw new Error("no such Devin session");
  const rows = query(devinDb(), "select node_id, parent_node_id, chat_message, created_at from message_nodes where session_id = ?", [id]);
  const nodes = new Map(rows.map((r) => [Number(r.node_id), r]));
  // The conversation is the chain from the session's head back to its root.
  const chain = [];
  const seen = new Set();
  let cur = s.main_chain_id != null ? Number(s.main_chain_id) : Math.max(-1, ...nodes.keys());
  while (nodes.has(cur) && !seen.has(cur)) {
    seen.add(cur);
    chain.push(nodes.get(cur));
    const p = nodes.get(cur).parent_node_id;
    cur = p == null ? NaN : Number(p);
  }
  chain.reverse();
  const cwd = s.working_directory || "";
  const t = transcript("devin", s.model || "", cwd);
  for (const r of chain) {
    let m;
    try {
      m = JSON.parse(r.chat_message);
    } catch {
      continue;
    }
    const ts = secs((m.metadata && m.metadata.created_at) || r.created_at);
    const text = typeof m.content === "string" ? m.content : resultText(m.content);
    if (m.role === "user") {
      if (m.metadata && m.metadata.is_user_input === false) continue;
      t.user(text, ts);
    } else if (m.role === "assistant") {
      if (m.thinking && m.thinking.thinking) t.step({ kind: "thinking", text: m.thinking.thinking }, ts);
      if (text) t.step({ kind: "text", text }, ts);
      for (const c of m.tool_calls || []) t.step({ kind: "tool", name: c.name, id: c.id, input: c.arguments, detail: describe(c.name, c.arguments) }, ts);
    } else if (m.role === "tool") {
      const ok = !(m.metadata && m.metadata.extensions && m.metadata.extensions["chisel/tool_result_meta"] && m.metadata.extensions["chisel/tool_result_meta"].success === false);
      t.result(m.tool_call_id, text, ok);
    }
  }
  return { cwd, model: s.model || "", messages: t.done() };
}

/* ------------------------------------------------------------------ list */

/** Session ids Bridge already has a chat for, so a chat isn't imported twice. */
function known(runs) {
  const map = new Map();
  for (const r of runs || []) {
    const add = (agent, id) => id && map.set(`${agent}:${id}`, r.runId);
    add("claude", r.sessionId);
    for (const [a, id] of Object.entries(r.agentSessions || {})) add(a, id);
    if (r.imported) add(r.imported.agent, r.imported.id);
  }
  return map;
}

function summaries(agent) {
  if (agent === "claude") return claudeFiles().sort((a, b) => b.mtime - a.mtime).slice(0, LIST_MAX).map(claudeSummary);
  if (agent === "codex") return codexFiles().sort((a, b) => b.mtime - a.mtime).slice(0, LIST_MAX).map(codexSummary);
  if (agent === "cursor") return cursorFiles().sort((a, b) => b.mtime - a.mtime).slice(0, LIST_MAX).map(cursorSummary);
  if (agent === "devin") return devinSummaries();
  return [];
}

/**
 * Every chat found, newest first. `agents` limits the scan (each is
 * independent: one agent's unreadable history never hides another's).
 */
function list({ agents = AGENTS, q = "", runs = [], limit = 800 } = {}) {
  const have = known(runs);
  const out = [];
  const counts = {};
  for (const a of agents.filter((x) => AGENTS.includes(x))) {
    let items = [];
    try {
      items = summaries(a).filter(Boolean);
    } catch {
      items = [];
    }
    counts[a] = items.length;
    for (const it of items) {
      out.push({ ...it, runId: have.get(`${a}:${it.id}`) || "", gone: !it.cwd || !stat(it.cwd) });
    }
  }
  const words = String(q || "").toLowerCase().split(/\s+/).filter(Boolean);
  const hits = words.length ? out.filter((it) => words.every((w) => `${it.title} ${it.prompt} ${it.cwd}`.toLowerCase().includes(w))) : out;
  hits.sort((a, b) => b.updatedAt - a.updatedAt);
  return { chats: hits.slice(0, limit), counts, sqlite: !!(sqliteModule() || hasSqliteCli()) };
}

function read(agent, id) {
  if (agent === "claude") return claudeRead(id);
  if (agent === "codex") return codexRead(id);
  if (agent === "cursor") return cursorRead(id);
  if (agent === "devin") return devinRead(id);
  throw new Error(`unknown agent: ${agent}`);
}

/**
 * list/read off the server's event loop: a scan reads hundreds of files (and,
 * on the sqlite3 fallback, runs subprocesses), which would otherwise stall
 * every other request and every worker's stream while it runs.
 */
function inWorker(fn, args) {
  const { Worker } = require("worker_threads");
  return new Promise((resolve, reject) => {
    const w = new Worker(__filename, { workerData: { fn, args }, env: process.env });
    w.once("message", (m) => (m.error ? reject(new Error(m.error)) : resolve(m.value)));
    w.once("error", reject);
    w.once("exit", (code) => code !== 0 && reject(new Error(`history worker exited with ${code}`)));
  });
}
const listAsync = (opts) => inWorker("list", opts);
const readAsync = (agent, id) => inWorker("read", [agent, id]);

const { isMainThread, parentPort, workerData } = require("worker_threads");
if (!isMainThread && workerData && workerData.fn) {
  try {
    const value = workerData.fn === "list" ? list(workerData.args) : read(...workerData.args);
    parentPort.postMessage({ value });
  } catch (e) {
    parentPort.postMessage({ error: String(e.message || e) });
  }
}

module.exports = { list, read, listAsync, readAsync, known, AGENTS, cleanPrompt, isNoise, cursorOrder };
