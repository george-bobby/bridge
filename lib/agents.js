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
    // Cursor has no edits-only mode: --force lets it edit and run commands.
    if (full || permissionMode === "acceptEdits") args.push("--force");
    else if (permissionMode === "plan") args.push("--mode", "plan");
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
  return briefing(run, {
    meta,
    report,
    since,
    title: `# Handoff: you are taking over this session from ${AGENTS[prev].label}`,
    intro: "You have none of the earlier conversation, so here is the briefing. Treat it as the state of the work, check it against the repo (`git status`, `git log -5`), and carry on.",
  });
}

// A turn that failed before doing anything isn't "having worked here".
const worked = (m) => m.role === "assistant" && (m.state === "done" || m.state === "stopped" || String(m.text || "").trim() || (m.steps || []).length);

/**
 * A briefing of a session: task, where it runs, latest report and the
 * conversation from message `since` on. Shared by the handoff, compaction
 * for agents without a native /compact, and `#` session references.
 */
function briefing(run, { meta = {}, report = null, since = 0, title = "", intro = "", transcript = "", now = true, lines: max = 30 } = {}) {
  const msgs = run.messages || [];
  const clip = (s, n) => {
    const t = String(s || "").trim();
    return t.length > n ? `${t.slice(0, n)}…` : t;
  };
  const lines = [];
  for (const m of msgs.slice(since)) {
    if (m.role === "assistant") {
      if (m.kind === "compact") continue;
      const tools = (m.steps || []).filter((s) => s.kind === "tool").map((s) => `${s.name}${s.detail ? ` ${clip(s.detail, 80)}` : ""}`);
      lines.push(`- ${(AGENTS[agentOf(m)] || AGENTS.claude).label}${tools.length ? ` (used: ${tools.slice(-8).join("; ")})` : ""}: ${clip(m.text, 1200) || "(no reply)"}`);
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
    transcript && `- Full transcript (JSON): ${transcript}`,
  ].filter(Boolean);
  return [
    title,
    "",
    intro,
    "",
    "## Task",
    clip(run.who && run.kind === "task" ? `${run.who}\n\n${run.text}` : run.text, 2000) || "(see the conversation below)",
    where.length ? "\n## Where" : "",
    ...where,
    report && report.parsed && report.parsed.tldr ? `\n## Latest report\n${clip(report.parsed.tldr, 1500)}` : "",
    "",
    `## Conversation so far${since ? ` (since you last worked here)` : ""}`,
    ...lines.slice(-max),
    "",
    now ? "## Now" : "",
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
  { id: "opus", label: "Opus", hint: "Latest Opus · most capable", alias: true },
  { id: "sonnet", label: "Sonnet", hint: "Latest Sonnet · fast, still strong at code", alias: true },
  { id: "haiku", label: "Haiku", hint: "Latest Haiku · cheapest", alias: true },
  { id: "fable", label: "Fable", hint: "Latest Fable · the frontier model", alias: true },
];

/**
 * What Claude Code itself offers in a folder: its slash commands (built-ins,
 * skills, plugins, with descriptions) and its model menu (aliases, versions,
 * effort levels). Both come back in the answer to the stream-json
 * `initialize` handshake, which costs no tokens: nothing is sent to a model.
 * Cached per folder for ten minutes.
 */
const probes = new Map();
function claudeProbe(dir, { refresh = false } = {}) {
  const key = dir || "";
  const hit = probes.get(key);
  if (hit && !refresh && Date.now() - hit.at < 10 * 60_000) return hit.promise;
  const promise = new Promise((resolve) => {
    const { spawn } = require("child_process");
    const bin = env.claudeBin;
    const args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--no-session-persistence"];
    const [cmd, argv] = bin.endsWith(".js") ? [process.execPath, [bin, ...args]] : [bin, args];
    let child;
    try {
      child = spawn(cmd, argv, { cwd: dir && fs.existsSync(dir) ? dir : require("os").homedir(), stdio: ["pipe", "pipe", "ignore"], env: cliEnv() });
    } catch {
      return resolve(null);
    }
    let buf = "";
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
    const timer = setTimeout(() => finish(null), 12000);
    child.on("error", () => finish(null));
    child.on("close", () => finish(null));
    child.stdin.on("error", () => {});
    child.stdout.on("data", (c) => {
      buf += c;
      let i;
      while ((i = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, i);
        buf = buf.slice(i + 1);
        try {
          const ev = JSON.parse(line);
          if (ev.type === "control_response" && ev.response && ev.response.request_id === "probe") {
            const r = ev.response.response || {};
            finish({ commands: Array.isArray(r.commands) ? r.commands : [], models: Array.isArray(r.models) ? r.models : [] });
          }
        } catch {}
      }
    });
    child.stdin.write(JSON.stringify({ type: "control_request", request_id: "probe", request: { subtype: "initialize", hooks: {} } }) + "\n");
  });
  probes.set(key, { at: Date.now(), promise });
  promise.then((v) => {
    if (!v) probes.delete(key);
  });
  return promise;
}

/** Every model the Anthropic API lists for Claude Code's login (or an API
 *  key): the versions the CLI's own menu leaves out. */
async function anthropicModels() {
  const headers = { "anthropic-version": "2023-06-01" };
  if (process.env.ANTHROPIC_API_KEY) headers["x-api-key"] = process.env.ANTHROPIC_API_KEY;
  else {
    const c = await require("./usage").claudeCreds().catch(() => null);
    if (!c || !c.accessToken || (c.expiresAt && c.expiresAt <= Date.now())) return [];
    headers.Authorization = `Bearer ${c.accessToken}`;
    headers["anthropic-beta"] = "oauth-2025-04-20";
  }
  try {
    const res = await fetch("https://api.anthropic.com/v1/models?limit=1000", { headers, signal: AbortSignal.timeout(10_000) });
    if (!res.ok) return [];
    const j = await res.json();
    return Array.isArray(j.data) ? j.data : [];
  } catch {
    return [];
  }
}

const tokensLabel = (n) => (!n ? "" : n >= 1e6 ? `${Math.round(n / 1e5) / 10}M context` : `${Math.round(n / 1000)}k context`);

async function claudeModels() {
  const [probe, api] = await Promise.all([claudeProbe(env.targetRepo), anthropicModels()]);
  const out = [];
  const seen = new Set();
  const apiById = new Map(api.map((m) => [m.id, m]));
  for (const m of (probe && probe.models) || []) {
    if (!m.value || m.value === "default" || seen.has(m.value)) continue;
    seen.add(m.value);
    if (m.resolvedModel) seen.add(m.resolvedModel);
    const alias = !/^claude-/.test(m.value);
    const a = apiById.get(m.resolvedModel || m.value);
    const ctx = a ? tokensLabel(a.max_input_tokens) : "";
    out.push({
      id: m.value,
      label: m.displayName || m.value,
      hint: [m.description, alias && m.resolvedModel ? `→ ${m.resolvedModel}` : "", ctx].filter(Boolean).join(" · "),
      efforts: m.supportedEffortLevels || [],
      alias,
      resolves: m.resolvedModel || "",
      group: alias ? "Latest" : "Versions",
    });
  }
  for (const a of api) {
    if (seen.has(a.id)) continue;
    seen.add(a.id);
    const efforts = Object.keys((a.capabilities && a.capabilities.effort) || {}).filter((k) => k !== "supported" && a.capabilities.effort[k] && a.capabilities.effort[k].supported);
    out.push({ id: a.id, label: a.display_name || a.id, hint: [a.id, tokensLabel(a.max_input_tokens), a.lifecycle && a.lifecycle !== "active" ? a.lifecycle : ""].filter(Boolean).join(" · "), efforts, group: "Versions", deprecated: a.lifecycle === "deprecated" });
  }
  if (!out.some((m) => m.alias)) out.unshift(...CLAUDE_MODELS.map((m) => ({ ...m, group: "Latest" })));
  return out;
}

async function models(agent) {
  if (agent === "claude") return claudeModels();
  if (agent === "codex") {
    const out = await sh(AGENTS.codex.bin(), ["debug", "models"]);
    try {
      return JSON.parse(out)
        .models.filter((m) => m.visibility !== "hide")
        .map((m) => ({ id: m.slug, label: m.display_name || m.slug, hint: (m.description || "").slice(0, 120), efforts: (m.supported_reasoning_levels || []).map((r) => r.effort) }));
    } catch {
      return [];
    }
  }
  if (agent === "cursor") {
    const out = await sh(AGENTS.cursor.bin(), ["--list-models"]);
    return String(out || "")
      .split("\n")
      .map((l) => /^(\S+) - (.+?)(?:\s+\((.*)\))?$/.exec(l.trim()))
      .filter(Boolean)
      .map((m) => ({ id: m[1], label: m[2], hint: m[3] ? `${m[1]} · ${m[3]}` : m[1], isDefault: /default/.test(m[3] || "") }));
  }
  if (agent === "devin") {
    const out = await sh(AGENTS.devin.bin(), ["models", "list", "--format", "json"]);
    try {
      return JSON.parse(out).families.flatMap((f) =>
        (f.variants || []).map((v) => ({
          id: v.model_uid,
          label: v.label || v.model_uid,
          family: f.slug,
          group: f.family_label || f.slug,
          hint: [v.cost_tier, tokensLabel(v.max_context_tokens), v.is_new ? "new" : "", v.is_beta ? "beta" : ""].filter(Boolean).join(" · ") || v.model_uid,
        })),
      );
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
  if (refresh) probes.clear();
  const list = await Promise.all(
    NAMES.map(async (id) => {
      const version = await sh(AGENTS[id].bin(), ["--version"], 10000);
      return { id, label: AGENTS[id].label, installed: !!version, version: version ? version.trim().split("\n")[0].slice(0, 60) : "", models: version ? await models(id) : [] };
    }),
  );
  catalogCache = { at: Date.now(), data: { agents: list, fetchedAt: Date.now() } };
  return catalogCache.data;
}

module.exports = { AGENTS, NAMES, command, adapter, handoff, briefing, agentOf, unwrapShell, catalog, claudeProbe };
