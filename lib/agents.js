/**
 * The agents a session can run on: Claude Code (the default, driven directly
 * by lib/jobs.js), Codex, Cursor and Devin.
 *
 * Each non-Claude agent runs headless in the session's folder and its output
 * is translated, line by line, into the same stream-json events Claude Code
 * emits. So one transcript, one watcher and one report contract serve all four:
 * the rest of Bridge never needs to know which agent ran a turn.
 *
 * Switching agents mid-session is a handoff: the incoming agent has none of
 * the conversation, so its first turn opens with a briefing built from the
 * transcript (task, where it runs, what happened, current state), the way a
 * person would hand work over.
 */

const fs = require("fs");
const path = require("path");
const env = require("./env");

const AGENTS = {
  claude: { label: "Claude", bin: () => env.claudeBin },
  codex: { label: "Codex", bin: () => process.env.CODEX_BIN || "codex" },
  cursor: { label: "Cursor", bin: () => process.env.CURSOR_AGENT_BIN || "cursor-agent" },
  devin: { label: "Devin", bin: () => process.env.DEVIN_BIN || "devin" },
};
const NAMES = Object.keys(AGENTS);

/** Command line for one turn. The prompt always goes on stdin (or a file):
 *  briefings run long, and a long argv is fragile. */
function command(agent, { workdir, sessionId, permissionMode, model, effort, promptFile, exportFile }) {
  const full = permissionMode === "bypassPermissions";
  const bin = AGENTS[agent].bin();
  if (agent === "codex") {
    const policy = full ? ["--dangerously-bypass-approvals-and-sandbox"] : ["--sandbox", permissionMode === "plan" ? "read-only" : "workspace-write"];
    const base = ["exec", ...(sessionId ? ["resume", sessionId] : []), "--json", "--skip-git-repo-check", ...policy];
    if (!sessionId) base.push("-C", workdir);
    if (model) base.push("-m", model);
    if (effort) base.push("-c", `model_reasoning_effort=${effort}`);
    return { bin, args: [...base, "-"], stdin: true };
  }
  if (agent === "cursor") {
    const args = ["-p", "--output-format", "stream-json", "--trust", "--workspace", workdir];
    if (full || permissionMode === "acceptEdits") args.push("--force");
    if (sessionId) args.push("--resume", sessionId);
    if (model) args.push("--model", model);
    return { bin, args, stdin: true };
  }
  if (agent === "devin") {
    const mode = full ? "dangerous" : permissionMode === "acceptEdits" ? "accept-edits" : "auto";
    // Print mode answers in plain text; --export leaves the session id and
    // ACU cost in a JSON trajectory after the turn.
    const args = ["-p", "--permission-mode", mode, "--respect-workspace-trust", "false", "--prompt-file", promptFile, "--export", exportFile];
    if (sessionId) args.push("-r", sessionId);
    if (model) args.push("--model", model);
    return { bin, args, stdin: false };
  }
  throw new Error(`unknown agent: ${agent}`);
}

/* ------------------------------------------------------------ adapters */

const TOOL = {
  shellToolCall: "Bash",
  readToolCall: "Read",
  editToolCall: "Edit",
  writeToolCall: "Write",
  deleteToolCall: "Delete",
  grepToolCall: "Grep",
  globToolCall: "Glob",
  lsToolCall: "LS",
  todoToolCall: "TodoWrite",
  webSearchToolCall: "WebSearch",
  fetchToolCall: "WebFetch",
};

const text = (t) => ({ type: "assistant", message: { content: [{ type: "text", text: t }] } });
const toolUse = (id, name, input) => ({ type: "assistant", message: { content: [{ type: "tool_use", id, name, input }] } });
const toolResult = (id, content, isError) => ({ type: "user", message: { content: [{ type: "tool_result", tool_use_id: id, content: String(content || "").slice(0, 20000), is_error: !!isError }] } });

/** A translator for one turn: `line(json)` returns Claude-shaped events,
 *  `end()` returns whatever closes the turn. */
function adapter(agent, { started = Date.now() } = {}) {
  let last = "";
  let usage = null;
  let sessionId = "";
  let thinking = "";
  let out = "";
  let resulted = false;
  const result = (extra = {}) => {
    resulted = true;
    return {
      type: "result",
      subtype: "success",
      result: last,
      duration_ms: Date.now() - started,
      usage: usage || {},
      total_cost_usd: 0,
      ...extra,
    };
  };

  const codex = (ev) => {
    if (ev.type === "thread.started") return [{ type: "system", subtype: "init", session_id: (sessionId = ev.thread_id), bridgeAgent: agent }];
    const it = ev.item || {};
    if (ev.type === "item.started" && it.type === "command_execution") return [toolUse(it.id, "Bash", { command: unwrapShell(it.command) })];
    if (ev.type === "item.completed") {
      if (it.type === "agent_message") return [text((last = it.text || ""))];
      if (it.type === "reasoning") return [{ type: "assistant", message: { content: [{ type: "thinking", thinking: it.text || "" }] } }];
      if (it.type === "command_execution") return [toolResult(it.id, it.aggregated_output, it.exit_code !== 0)];
      if (it.type === "file_change") {
        const files = (it.changes || []).map((c) => `${c.kind || "edit"} ${c.path}`).join("\n");
        return [toolUse(it.id, "Edit", { file_path: (it.changes || []).map((c) => c.path).join(", ") }), toolResult(it.id, files, it.status === "failed")];
      }
      if (it.type === "mcp_tool_call") return [toolUse(it.id, `mcp__${it.server}__${it.tool}`, it.arguments || {}), toolResult(it.id, JSON.stringify(it.result || it.error || ""), !!it.error)];
      if (it.type === "web_search") return [toolUse(it.id, "WebSearch", { query: it.query }), toolResult(it.id, "", false)];
      if (it.type === "error") return [text(`Error: ${it.message}`)];
    }
    if (ev.type === "turn.completed") {
      const u = ev.usage || {};
      usage = { input_tokens: u.input_tokens || 0, output_tokens: (u.output_tokens || 0) + (u.reasoning_output_tokens || 0), cache_read_input_tokens: u.cached_input_tokens || 0 };
      return [result()];
    }
    if (ev.type === "turn.failed" || ev.type === "error") return [result({ subtype: "error", result: (ev.error && ev.error.message) || ev.message || "Codex failed" })];
    return [];
  };

  const cursor = (ev) => {
    if (ev.type === "system" && ev.subtype === "init") return [{ type: "system", subtype: "init", session_id: (sessionId = ev.session_id), bridgeAgent: agent, model: ev.model }];
    if (ev.type === "thinking") {
      if (ev.subtype === "delta") thinking += ev.text || "";
      if (ev.subtype === "completed" && thinking) {
        const t = thinking;
        thinking = "";
        return [{ type: "assistant", message: { content: [{ type: "thinking", thinking: t }] } }];
      }
      return [];
    }
    if (ev.type === "assistant") {
      const t = ((ev.message || {}).content || []).filter((c) => c.type === "text").map((c) => c.text).join("");
      if (t) last = t;
      return t ? [text(t)] : [];
    }
    if (ev.type === "tool_call") {
      const [key, call] = Object.entries(ev.tool_call || {})[0] || ["tool", {}];
      const name = TOOL[key] || key.replace(/ToolCall$/, "");
      const args = call.args || {};
      const input = name === "Bash" ? { command: args.command } : args.path ? { file_path: args.path, ...args } : args;
      if (ev.subtype === "started") return [toolUse(ev.call_id, name, input)];
      if (ev.subtype === "completed") {
        const r = call.result || {};
        const ok = r.success || (!r.error && !r.failure);
        const body = (r.success && (r.success.stdout || r.success.content || r.success.output)) || (r.error && (r.error.message || r.error.stderr)) || JSON.stringify(r).slice(0, 4000);
        return [toolResult(ev.call_id, typeof body === "string" ? body : JSON.stringify(body), !ok)];
      }
      return [];
    }
    if (ev.type === "result") return [result({ subtype: ev.is_error ? "error" : "success", result: ev.result || last, duration_ms: ev.duration_ms || Date.now() - started })];
    return [];
  };

  return {
    get sessionId() {
      return sessionId;
    },
    line(raw) {
      if (agent === "devin") {
        out += raw + "\n";
        return [];
      }
      let ev;
      try {
        ev = JSON.parse(raw);
      } catch {
        return [];
      }
      return agent === "codex" ? codex(ev) : cursor(ev);
    },
    /** The child closed its stdout. Devin answers in plain text, all at once;
     *  its export file has the session id, tokens and ACU cost. */
    end(exportFile) {
      if (agent === "devin") {
        const answer = out.trim();
        last = answer;
        const evs = [];
        let acu = 0;
        try {
          const x = JSON.parse(fs.readFileSync(exportFile, "utf8"));
          if (x.session_id) evs.push({ type: "system", subtype: "init", session_id: (sessionId = x.session_id), bridgeAgent: agent });
          for (const st of x.steps || []) acu += Number((st.extra || {}).committed_acu_cost) || 0;
          const f = x.final_metrics || {};
          usage = { input_tokens: f.total_prompt_tokens || f.input_tokens || 0, output_tokens: f.total_completion_tokens || f.output_tokens || 0, cache_read_input_tokens: f.total_cached_tokens || 0 };
        } catch {}
        return [...evs, ...(answer ? [text(answer), result({ acu })] : [result({ subtype: "error", result: "Devin returned nothing", acu })])];
      }
      return resulted ? [] : [result({ subtype: "error", result: last || `${AGENTS[agent].label} ended without finishing the turn` })];
    },
  };
}

/** `/bin/zsh -lc 'cat a.txt'` reads better as `cat a.txt`. */
function unwrapShell(cmd) {
  const c = String(cmd || "");
  const single = /^\/bin\/(?:ba|z)?sh -lc '([\s\S]*)'$/.exec(c);
  if (single) return single[1].replace(/'\\''/g, "'");
  const double = /^\/bin\/(?:ba|z)?sh -lc "([\s\S]*)"$/.exec(c);
  return double ? double[1].replace(/\\(["\\$`])/g, "$1") : c;
}

/* ------------------------------------------------------------- handoff */

/** Which agent ran each assistant turn (older turns predate agents: Claude). */
const agentOf = (m) => (m && m.agent) || "claude";

/**
 * The briefing an agent gets when it picks a session up from another agent:
 * everything since it last worked here (or all of it, if it never has).
 * Returns "" when no handoff is needed.
 */
function handoff(run, agent, { meta = {}, report = null } = {}) {
  const msgs = run.messages || [];
  // A turn that failed before doing anything isn't "having worked here".
  const worked = (m) => m.role === "assistant" && (m.state === "done" || m.state === "stopped" || String(m.text || "").trim() || (m.steps || []).length);
  const assistants = msgs.filter(worked);
  if (!assistants.length) return "";
  const prev = agentOf(assistants[assistants.length - 1]);
  if (prev === agent) return "";
  let since = 0;
  for (let i = msgs.length - 1; i >= 0; i--) {
    if (worked(msgs[i]) && agentOf(msgs[i]) === agent) {
      since = i + 1;
      break;
    }
  }
  const clip = (s, n) => {
    const t = String(s || "").trim();
    return t.length > n ? `${t.slice(0, n)}…` : t;
  };
  const lines = [];
  for (const m of msgs.slice(since)) {
    if (m.role === "assistant") {
      const tools = (m.steps || []).filter((s) => s.kind === "tool").map((s) => `${s.name}${s.detail ? ` ${clip(s.detail, 80)}` : ""}`);
      lines.push(`- ${AGENTS[agentOf(m)].label}${tools.length ? ` (used: ${tools.slice(-8).join("; ")})` : ""}: ${clip(m.text, 1200) || "(no reply)"}`);
    } else if (m.role === "user" || m.role === "slack" || m.role === "thread") {
      lines.push(`- ${m.role === "user" ? "User" : m.who || "Slack"}: ${clip(m.text, 1500)}`);
    } else if (m.role === "event" || m.role === "outcome") {
      lines.push(`- Event: ${clip(m.text, 300)}`);
    }
  }
  const where = [
    meta.worktree && `- Worktree (work here): ${meta.worktree}`,
    meta.branch && `- Branch: ${meta.branch}`,
    meta.repo && `- Main checkout (do not edit): ${meta.repo}`,
    run.prUrl && `- Pull request: ${run.prUrl}`,
    run.linearUrl && `- Linear issue: ${run.linearUrl}`,
    run.permalink && `- Slack thread: ${run.permalink}`,
  ].filter(Boolean);
  return [
    `# Handoff: you are taking over this session from ${AGENTS[prev].label}`,
    "",
    `You have none of the earlier conversation, so here is the briefing. Treat it as the state of the work, check it against the repo (\`git status\`, \`git log -5\`), and carry on.`,
    "",
    "## Task",
    clip(run.who && run.kind === "task" ? `${run.who}\n\n${run.text}` : run.text, 2000) || "(see the conversation below)",
    where.length ? "\n## Where" : "",
    ...where,
    report && report.parsed && report.parsed.tldr ? `\n## Latest report\n${clip(report.parsed.tldr, 1500)}` : "",
    "",
    `## Conversation so far${since ? ` (since you last worked here)` : ""}`,
    ...lines.slice(-30),
    "",
    "## Now",
  ]
    .filter((l) => l != null && l !== false)
    .join("\n");
}

/* ------------------------------------------------------------- catalog */

const { execFile } = require("child_process");

const cliEnv = () => {
  const e = { ...process.env, PATH: `${env.extraPath}:${process.env.PATH || "/usr/bin:/bin"}` };
  delete e.ACP_BACKEND;
  return e;
};
const sh = (bin, args, timeout = 30000) =>
  new Promise((resolve) => execFile(bin, args, { timeout, maxBuffer: 64e6, env: cliEnv() }, (err, out) => resolve(err ? null : String(out))));

const CLAUDE_MODELS = [
  { id: "opus", label: "Opus", hint: "Most capable" },
  { id: "sonnet", label: "Sonnet", hint: "Fast, still strong at code" },
  { id: "haiku", label: "Haiku", hint: "Cheapest" },
  { id: "fable", label: "Fable", hint: "The Claude 5 frontier model" },
];

async function models(agent) {
  if (agent === "claude") return CLAUDE_MODELS;
  if (agent === "codex") {
    const out = await sh(AGENTS.codex.bin(), ["debug", "models"]);
    try {
      return JSON.parse(out).models.filter((m) => m.visibility !== "hide").map((m) => ({ id: m.slug, label: m.display_name || m.slug, hint: (m.description || "").slice(0, 90), efforts: (m.supported_reasoning_levels || []).map((r) => r.effort) }));
    } catch {
      return [];
    }
  }
  if (agent === "cursor") {
    const out = await sh(AGENTS.cursor.bin(), ["--list-models"]);
    return String(out || "")
      .split("\n")
      .map((l) => /^(\S+) - (.+?)(?:\s+\(.*\))?$/.exec(l.trim()))
      .filter(Boolean)
      .map((m) => ({ id: m[1], label: m[2] }));
  }
  if (agent === "devin") {
    const out = await sh(AGENTS.devin.bin(), ["models", "list", "--format", "json"]);
    try {
      return JSON.parse(out).families.flatMap((f) => (f.variants || []).map((v) => ({ id: v.model_uid, label: v.label || v.model_uid, family: f.slug })));
    } catch {
      return [];
    }
  }
  return [];
}

let catalogCache = null;
/** Which agents are installed, their versions and models. Cached 30 minutes. */
async function catalog({ refresh = false } = {}) {
  if (catalogCache && !refresh && Date.now() - catalogCache.at < 30 * 60_000) return catalogCache.data;
  const list = await Promise.all(
    NAMES.map(async (id) => {
      const version = await sh(AGENTS[id].bin(), ["--version"], 10000);
      return { id, label: AGENTS[id].label, installed: !!version, version: version ? version.trim().split("\n")[0].slice(0, 60) : "", models: version ? await models(id) : [] };
    }),
  );
  catalogCache = { at: Date.now(), data: { agents: list } };
  return catalogCache.data;
}

module.exports = { AGENTS, NAMES, command, adapter, handoff, agentOf, unwrapShell, catalog };
