/**
 * Persistence for the dashboard.
 *
 *   config.json     the pipeline gates and the job defaults (Settings writes it)
 *   runs/<id>.json  the chat record — one file per Slack thread you handed the
 *                   bridge, holding the whole conversation: the Slack message,
 *                   every phase the pipeline reported, the outcome, and every
 *                   follow-up you typed plus what Claude did about it.
 *
 * Nothing here is written by a background process. A chat exists because you
 * pasted its Slack link (or a run you started from a terminal narrated itself
 * through scripts/emit.sh).
 *
 * Per-run files rather than one big log because a follow-up streams for
 * minutes: appending a token to a 5MB JSON array means rewriting 5MB.
 */

const fs = require("fs");
const path = require("path");

const env = require("./env");

const ROOT = path.join(__dirname, "..");

// Everything mutable lives under data/, which is gitignored wholesale (bar the
// committed config.example.json). Keeping it in one directory is what makes
// "what is state and what is source" answerable at a glance — and what lets
// the ignore rule be one line instead of five that drift.
const DATA_DIR = env.dataDir;
const RUNS_DIR = path.join(DATA_DIR, "runs");

const PATHS = {
  data: DATA_DIR,
  config: path.join(DATA_DIR, "config.json"),
  runs: RUNS_DIR,
};

// The toggles the pipeline is gated on, passed through to slack-fetch-pipeline
// as `toggles`.
const TOGGLE_KEYS = ["createLinearIssue", "botReview", "saveToMemory", "reply"];

/* --------------------------------------------------------------- job opts */

/**
 * How a job runs: which repo, which model, how much rope, how hard it thinks.
 *
 * These used to be two text boxes in Settings that applied to every job on the
 * machine. They are now per chat — the composer writes them into the run file
 * and Settings only supplies the starting point — so the validation lives here
 * rather than inside writeConfig(): three callers need exactly the same rules
 * (the defaults in config.json, a chat's overrides in its run file, and the
 * argv assembled in server/jobs.js).
 */
const PERMISSION_MODES = ["plan", "manual", "acceptEdits", "bypassPermissions"];
const EFFORT_LEVELS = ["", "low", "medium", "high", "xhigh", "max"];

const DEFAULT_JOB_OPTS = {
  model: env.pipelineModel,
  // How much the session may do unattended. bypassPermissions is what every
  // job hard-coded before this was selectable; plan, manual and acceptEdits are
  // the three ways to hand it less rope. They stopped being merely narrower
  // when the dashboard learned to answer a prompt: `manual` asks you about
  // every tool call, and under plan the session's ExitPlanMode now reaches you
  // rather than being refused — see the ask lifecycle in server/jobs.js.
  permissionMode: "bypassPermissions",
  // "" leaves --effort off the command line entirely, which is the behaviour
  // that shipped before the dial existed.
  effort: "",
  // The 1M-context variant, requested by suffixing the model id: `opus[1m]`.
  // Off by default — it prices differently, so it should be a choice.
  context1m: false,
};

function isDir(p) {
  try {
    return fs.statSync(p).isDirectory();
  } catch {
    return false;
  }
}

/**
 * Keep only the keys we recognise, and only when the value is usable. Anything
 * rejected is dropped silently so the caller keeps whatever it had — a bad
 * value must never widen what a job can do.
 */
function sanitizeJobOpts(patch) {
  const out = {};
  if (!patch || typeof patch !== "object") return out;
  if (patch.model != null) {
    const v = String(patch.model).trim();
    if (/^[a-z0-9._-]{1,60}$/i.test(v)) out.model = v;
  }
  if (patch.workdir != null) {
    const v = String(patch.workdir).trim();
    // A job spawns a session that can write; pointing it at a path that isn't
    // there is how you get one rooted at /.
    if (v === "" || (path.isAbsolute(v) && isDir(v))) out.workdir = v;
  }
  if (patch.permissionMode != null && PERMISSION_MODES.includes(String(patch.permissionMode))) {
    out.permissionMode = String(patch.permissionMode);
  }
  if (patch.effort != null && EFFORT_LEVELS.includes(String(patch.effort))) {
    out.effort = String(patch.effort);
  }
  if (patch.context1m != null) out.context1m = Boolean(patch.context1m);
  if (patch.agent != null && ["claude", "codex", "cursor", "devin"].includes(String(patch.agent))) out.agent = String(patch.agent);
  if (patch.agentModel != null) {
    const v = String(patch.agentModel).trim();
    if (v === "" || /^[A-Za-z0-9._:\[\]-]{1,80}$/.test(v)) out.agentModel = v;
  }
  return out;
}

/** What a job in this chat actually runs with: chat picks over Settings
 *  defaults over the built-ins. */
function jobOpts(config, run) {
  return {
    ...DEFAULT_JOB_OPTS,
    ...((config && config.followup) || {}),
    ...((run && run.opts) || {}),
  };
}

/**
 * mode         normal: every outcome is relayed to the orchestrator
 *              quiet:  only what needs you (questions, blocks, stalls, ...)
 *              away:   nothing is relayed; it's held and briefed on return
 * relay        whether outcomes start a turn in the orchestrator chat at all
 * stallMinutes silence before a working worker is flagged as stalled
 * workerSkill  skill every new worker opens with; "" = WORKER_SKILL (.env), "none" = off
 * policy       per-category overrides of server/policy.js (ask | allow)
 */
// slackWatch: "off" | "watch" (file mentions in the Inbox) | "triage" (and let
// the orchestrator decide which ones to start); server/watch.js.
const DEFAULT_HARNESS = {
  mode: "normal", relay: true, stallMinutes: 15, workerSkill: "", policy: {},
  slackWatch: "watch", slackPollSec: 120, slackChannels: [],
  failover: false, failoverThreshold: 95, failoverOrder: ["devin", "codex", "cursor"],
};
const POLICY_KEYS = ["chat", "tickets", "docs", "prComments", "prMerge", "otherWrites", "destructiveGit"];

function sanitizeHarness(patch, base) {
  const out = { ...base, policy: { ...(base.policy || {}) } };
  if (!patch || typeof patch !== "object") return out;
  if (["normal", "quiet", "away"].includes(patch.mode)) out.mode = patch.mode;
  if (patch.relay != null) out.relay = Boolean(patch.relay);
  const int = (v, lo, hi) => Math.min(hi, Math.max(lo, Math.round(Number(v))));
  if (Number.isFinite(Number(patch.stallMinutes)) && patch.stallMinutes !== "") out.stallMinutes = int(patch.stallMinutes, 1, 240);
  if (patch.failover != null) out.failover = Boolean(patch.failover);
  if (Number.isFinite(Number(patch.failoverThreshold)) && patch.failoverThreshold !== "") out.failoverThreshold = int(patch.failoverThreshold, 50, 100);
  if (Array.isArray(patch.failoverOrder)) {
    const order = [...new Set(patch.failoverOrder.map(String).filter((a) => ["devin", "codex", "cursor"].includes(a)))];
    if (order.length === 3) out.failoverOrder = order;
  }
  // "" follows WORKER_SKILL in .env; "none" turns the worker skill off.
  if (patch.workerSkill != null) {
    const v = String(patch.workerSkill).trim().replace(/^\//, "");
    if (v === "" || /^[\w.-]+(?::[\w.-]+)?$/.test(v)) out.workerSkill = v.slice(0, 64);
  }
  if (["off", "watch", "triage"].includes(patch.slackWatch)) out.slackWatch = patch.slackWatch;
  // Picked in Settings instead of typed into .env (server/identity.js): the
  // project Slack threads are worked in, the Linear team tickets go to, and the
  // Slack pipeline's model. "" falls back to .env.
  if (patch.pipelineProject != null && /^[a-z0-9-]{0,40}$/.test(String(patch.pipelineProject))) out.pipelineProject = String(patch.pipelineProject);
  if (patch.linearTeam != null && /^[A-Za-z0-9]{0,12}$/.test(String(patch.linearTeam))) out.linearTeam = String(patch.linearTeam).toUpperCase();
  if (patch.pipelineModel != null && /^[\w.:\[\]-]{0,64}$/.test(String(patch.pipelineModel))) out.pipelineModel = String(patch.pipelineModel);
  if (Number.isFinite(Number(patch.slackPollSec)) && patch.slackPollSec !== "") out.slackPollSec = int(patch.slackPollSec, 30, 3600);
  if (Array.isArray(patch.slackChannels)) out.slackChannels = [...new Set(patch.slackChannels.map(String).filter((c) => /^[CG][A-Z0-9]{4,}$/.test(c)))].slice(0, 20);
  if (patch.policy && typeof patch.policy === "object") {
    for (const k of POLICY_KEYS) if (patch.policy[k] === "ask" || patch.policy[k] === "allow") out.policy[k] = patch.policy[k];
  }
  return out;
}

const DEFAULT_CONFIG = {
  // Offer to file a Linear ticket once the verdict is in. The run drafts it and
  // asks you before creating anything.
  createLinearIssue: true,
  // After the PR opens, wait for the review bots that run on every push to a
  // ready PR, then run /resolve.
  botReview: true,
  // Let a run *propose* a memory — never write one. Proposals land in
  // data/runs/memories/, which no session loads, and only recurrence or an
  // explicit approval promotes one into the repo's memory. See server/proposals.js
  // for why the old always-bank behaviour had to go.
  saveToMemory: true,
  reply: true,
  // The harness: how outcomes reach you.
  harness: { ...DEFAULT_HARNESS },
  // The starting point for every new chat's job options. A chat that has been
  // tuned in the composer keeps its own values; changing these only affects
  // chats you haven't touched.
  followup: { ...DEFAULT_JOB_OPTS },
};

function readJson(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return fallback;
  }
}

// Atomic write so a reader (a job, another tab, us) never sees a
// half-written file. The mkdir is here rather than at boot because a fresh
// clone has no data/ at all, and the first thing to touch it may as well be
// whichever writer got there first.
function writeJsonAtomic(file, value, { compact = false } = {}) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, (compact ? JSON.stringify(value) : JSON.stringify(value, null, 2)) + "\n");
  fs.renameSync(tmp, file);
}

/** Run files are rewritten every 600ms while a turn streams and can run to
 *  megabytes: written compact, which is a third smaller and quicker to
 *  serialise than the indented form config.json keeps for hand-editing. */
const writeRun = (run) => writeJsonAtomic(runPath(run.runId), run, { compact: true });

/* ------------------------------------------------------------------ config */

// A workdir is a chat's own (run.opts); there is no global one. A chat with
// none runs in Default's folder (jobs.resolveWorkdir), never a project.
function withoutWorkdir(opts) {
  const { workdir, ...rest } = opts || {};
  return rest;
}

function readConfig() {
  const raw = readJson(PATHS.config, {});
  const config = {
    ...DEFAULT_CONFIG,
    followup: { ...DEFAULT_CONFIG.followup, ...withoutWorkdir(raw.followup) },
    harness: sanitizeHarness(raw.harness, DEFAULT_HARNESS),
  };
  for (const key of TOGGLE_KEYS) if (key in raw) config[key] = Boolean(raw[key]);
  return config;
}

// Only ever merge known keys, so a stray field from an old config or a bad
// POST cannot end up steering a run.
function writeConfig(patch) {
  const next = readConfig();
  for (const key of TOGGLE_KEYS) {
    if (key in patch) next[key] = Boolean(patch[key]);
  }
  if (patch.followup && typeof patch.followup === "object") {
    Object.assign(next.followup, withoutWorkdir(sanitizeJobOpts(patch.followup)));
  }
  if (patch.harness && typeof patch.harness === "object") next.harness = sanitizeHarness(patch.harness, next.harness);
  writeJsonAtomic(PATHS.config, next);
  return next;
}

/* -------------------------------------------------------------------- cost */

/**
 * What the jobs you started have cost: today, and a 14-day daily series for
 * the Spend chart. Read off the runs themselves — every finished job records
 * its `total_cost_usd` on its message — so there is no second ledger to drift.
 */
/**
 * What the totals and search need from each run, re-read only when its file
 * changes: GET /api/state and every `state` broadcast total costs, Usage
 * totals turns per agent, and the ⌘K palette searches on every keystroke. Each
 * used to parse every transcript in full, on the event loop.
 */
const indexCache = new Map();
function runIndex(f) {
  const file = path.join(RUNS_DIR, f);
  const stamp = stampOf(file);
  const hit = indexCache.get(f);
  if (hit && hit.stamp === stamp) return hit.index;
  const run = readJson(file, null);
  const messages = (run && Array.isArray(run.messages) && run.messages) || [];
  const index = {
    runId: (run && run.runId) || "",
    who: run ? run.who : "",
    kind: (run && run.kind) || "slack",
    updatedAt: (run && run.updatedAt) || 0,
    sessionId: (run && run.sessionId) || "",
    agentSessions: (run && run.agentSessions) || {},
    imported: (run && run.imported) || null,
    costs: [],
    turns: [],
    fields: run && run.runId && run.text ? [{ text: String(run.text), lower: String(run.text).toLowerCase(), role: "thread", ts: run.createdAt }] : [],
  };
  for (const m of messages) {
    if (!m) continue;
    const c = Number(m.cost) || 0;
    if (c) index.costs.push([Number(m.ts) || 0, c]);
    if (m.role === "assistant" && m.ts) {
      const u = m.usage || {};
      index.turns.push({ ts: m.ts, agent: m.agent, tokens: (u.input || 0) + (u.output || 0) + (u.cacheRead || 0) + (u.cacheWrite || 0), cost: c, acu: Number(m.acu) || 0 });
    }
    if (m.text) index.fields.push({ text: String(m.text), lower: String(m.text).toLowerCase(), role: m.role, ts: m.ts || m.at });
  }
  indexCache.set(f, { stamp, index });
  return index;
}

/** Every run's index, dropping the cache entries of deleted runs. */
function runIndexes() {
  ensureRunsDir();
  const seen = new Set();
  const out = [];
  for (const f of fs.readdirSync(RUNS_DIR)) {
    if (!f.endsWith(".json") || f.includes(".tmp-")) continue;
    seen.add(f);
    out.push(runIndex(f));
  }
  for (const f of indexCache.keys()) if (!seen.has(f)) indexCache.delete(f);
  return out;
}

/** Turns, tokens, cost and ACUs per agent over the last week and month (Usage's local counts). */
function summariseUsage() {
  const now = Date.now() / 1000;
  const out = {};
  const bucket = () => ({ turns: 0, tokens: 0, cost: 0, acu: 0 });
  for (const idx of runIndexes()) {
    for (const t of idx.turns) {
      out[t.agent] = out[t.agent] || { week: bucket(), month: bucket() };
      for (const [k, days] of [["week", 7], ["month", 30]]) {
        if (now - t.ts > days * 86400) continue;
        const b = out[t.agent][k];
        b.turns++;
        b.tokens += t.tokens;
        b.cost += t.cost;
        b.acu += t.acu;
      }
    }
  }
  return out;
}

function summariseCost() {
  ensureRunsDir();
  const midnight = new Date();
  midnight.setHours(0, 0, 0, 0);
  const startOfDay = midnight.getTime() / 1000;
  const dayKey = (ts) => {
    const d = new Date(ts * 1000);
    d.setHours(0, 0, 0, 0);
    return d.getTime() / 1000;
  };
  const horizon = dayKey(Date.now() / 1000) - 13 * 86400;

  let today = 0,
    todayJobs = 0,
    jobs = 0,
    total = 0;
  const days = new Map();
  for (const idx of runIndexes()) {
    for (const [ts, c] of idx.costs) {
      jobs++;
      total += c;
      if (ts >= startOfDay) {
        today += c;
        todayJobs++;
      }
      const k = dayKey(ts);
      if (k >= horizon) {
        const row = days.get(k) || { day: k, poll: 0, work: 0, ticks: 0 };
        row.work += c;
        row.ticks++;
        days.set(k, row);
      }
    }
  }

  // Quiet days stay in the series as zero rather than closing the gap. `poll`
  // is always 0 (nothing runs idle any more) and `ticks` counts jobs; the
  // shape is kept so the chart reads the same fields it always has.
  const series = [];
  for (let k = horizon; k <= dayKey(Date.now() / 1000); k += 86400) {
    series.push(days.get(k) || { day: k, poll: 0, work: 0, ticks: 0 });
  }
  return { today, todayJobs, jobs, total, series };
}

/* -------------------------------------------------------------------- runs */

// runId is a Slack ts ("1784560120.179279"). Never trust it as a filename —
// it arrives over HTTP from emit.sh and from the browser.
function safeId(runId) {
  const id = String(runId || "").trim();
  return /^[A-Za-z0-9._-]{1,80}$/.test(id) && !id.startsWith(".") ? id : null;
}

function runPath(id) {
  return path.join(RUNS_DIR, `${id}.json`);
}

function ensureRunsDir() {
  fs.mkdirSync(RUNS_DIR, { recursive: true });
}

function blankRun(id, seed = {}) {
  return {
    runId: id,
    createdAt: seed.createdAt || Math.floor(Date.now() / 1000),
    updatedAt: Math.floor(Date.now() / 1000),
    who: seed.who || "someone",
    channel: seed.channel || "",
    channelId: seed.channelId || "",
    threadTs: seed.threadTs || id,
    // The ts of the message that *opened* this chat. Everything after it is a
    // later message in the same thread, and must not be allowed to rewrite who
    // asked or what they asked for — see upsertMention.
    rootTs: seed.rootTs || "",
    userId: seed.userId || "",
    text: seed.text || "",
    permalink: seed.permalink || "",
    // pending  added from a Slack link, no job has touched it yet
    // running  a pipeline or a follow-up is in flight
    // acted / skipped / error  terminal, as reported by the pipeline
    action: seed.action || "pending",
    // Legacy triage fields from the poller days; kept so old run files and the
    // sidebar still agree on their shape.
    triage: seed.triage || "",
    triageReason: seed.triageReason || "",
    startedBy: seed.startedBy || "", // dashboard | terminal | ""
    outcome: seed.outcome || "",
    prUrl: seed.prUrl || "",
    linearUrl: seed.linearUrl || "",
    phase: seed.phase || "queued",
    // The uuid the follow-up sessions resume. Minted on the first follow-up so
    // the second one continues the same conversation instead of re-reading the
    // whole thread from scratch.
    sessionId: null,
    // This chat's overrides of the Settings job defaults, written by the
    // composer. Sparse on purpose: a key that isn't here follows the default,
    // so changing a default still moves chats you never tuned.
    opts: {},
    cost: 0,
    seenAt: 0, // when you last opened this chat — drives the unread dot
    messages: [],
  };
}

function loadRun(id) {
  const safe = safeId(id);
  if (!safe) return null;
  const run = readJson(runPath(safe), null);
  if (!run) return null;
  run.messages = Array.isArray(run.messages) ? run.messages : [];
  return run;
}

const BOARD_COLUMNS = ["backlog", "doing", "needs", "review", "done"];

/** Pin a chat to a board column ("" hands it back to automatic placement).
 *  Written without saveRun's updatedAt bump: moving a card isn't activity,
 *  and must not light the unread dot or reorder the sidebar. */
function setBoard(id, column) {
  const run = loadRun(id);
  if (!run) throw new Error("no such run");
  const col = String(column || "");
  if (col && !BOARD_COLUMNS.includes(col)) throw new Error(`unknown column: ${col}`);
  if (col) run.board = { column: col, at: Date.now() };
  else delete run.board;
  writeRun(run);
  return run.board || null;
}

/** Pin a chat to the top of its project, or unpin it. Not activity either. */
function setPinned(id, pinned) {
  const run = loadRun(id);
  if (!run) throw new Error("no such run");
  if (pinned) run.pinned = true;
  else delete run.pinned;
  writeRun(run);
  return !!run.pinned;
}

/** Archive a chat (out of the sidebar, board and roster) or bring it back. Not activity. */
function setArchived(id, archived) {
  const run = loadRun(id);
  if (!run) throw new Error("no such run");
  if (archived) run.archivedAt = run.archivedAt || Math.floor(Date.now() / 1000);
  else delete run.archivedAt;
  writeRun(run);
  return !!run.archivedAt;
}

/** Move a chat to another project. A chat that has never run also takes the
 *  project's checkout as its workdir; one that has keeps its session's. */
function setProject(id, project) {
  const run = loadRun(id);
  if (!run) throw new Error("no such run");
  const p = require("./projects").get(project);
  if (!p) throw new Error(`no such project: ${project}`);
  run.project = p.id;
  if (!run.sessionId) run.opts = { ...run.opts, workdir: p.path };
  writeRun(run);
  return p.id;
}

function saveRun(run) {
  ensureRunsDir();
  run.updatedAt = Math.floor(Date.now() / 1000);
  writeRun(run);
  return run;
}

/**
 * Drop every pending permission prompt, at boot.
 *
 * An ask is a question a *live child process* is blocked on, and those children
 * are ours — they die with the server. So a `pendingAsk` still on disk when we
 * start up belongs to a session that no longer exists, and leaving it there
 * gives you a sidebar full of Allow buttons that answer nothing and an
 * "awaiting you" badge that never clears.
 *
 * The step is marked `cancelled` rather than deleted, because it did happen:
 * the transcript should still show that the run stopped to ask and never got an
 * answer, which is usually the explanation for whatever it did next.
 */
function clearPendingAsks() {
  ensureRunsDir();
  let swept = 0;
  for (const f of fs.readdirSync(RUNS_DIR)) {
    if (!f.endsWith(".json") || f.includes(".tmp-")) continue;
    const run = readJson(path.join(RUNS_DIR, f), null);
    if (!run || !run.runId || !run.pendingAsk) continue;
    delete run.pendingAsk;
    for (const m of Array.isArray(run.messages) ? run.messages : []) {
      for (const s of Array.isArray(m.steps) ? m.steps : []) {
        if (s.ask && s.ask.state === "pending") s.ask.state = "cancelled";
      }
    }
    // Not saveRun(): bumping updatedAt here would mark every swept chat unread
    // on every restart.
    writeRun(run);
    swept++;
  }
  return swept;
}

/**
 * Every chat, newest first, as the sidebar needs them.
 *
 * Summarised rather than whole: a thread carrying a 40-minute pipeline run is
 * megabytes of transcript, and the sidebar draws one line from it. The two
 * halves are never wanted apart — every caller (the SSE seed, GET /api/runs,
 * and the four `runs` broadcasts) wants exactly this — so they are one call.
 */
function listRunSummaries() {
  ensureRunsDir();
  const out = [];
  const seen = new Set();
  const projectsStamp = stampOf(require("./projects").FILE);
  for (const f of fs.readdirSync(RUNS_DIR)) {
    if (!f.endsWith(".json") || f.includes(".tmp-")) continue;
    seen.add(f);
    const summary = cachedSummary(f, projectsStamp);
    if (summary) out.push(summary);
  }
  for (const f of summaryCache.keys()) if (!seen.has(f)) summaryCache.delete(f);
  return out.sort((a, b) => (b.updatedAt || 0) - (a.updatedAt || 0));
}

/**
 * Summaries, cached by what's on disk.
 *
 * Every `runs` broadcast used to read and parse every run file in full (a
 * long chat is megabytes), synchronously, on the event loop: a dozen times a
 * turn with a few hundred chats, which stalled streaming for everyone. A
 * summary only changes when its run file, its task's meta.json or the project
 * list does, so a stat of each is enough to know whether to re-read. Any
 * writer (this module, imports, a hand edit) changes the stamp.
 */
const summaryCache = new Map();

function stampOf(file) {
  try {
    const st = fs.statSync(file);
    return `${st.ino}:${st.size}:${st.mtimeMs}`;
  } catch {
    return "";
  }
}

function cachedSummary(f, projectsStamp = stampOf(require("./projects").FILE)) {
  const file = path.join(RUNS_DIR, f);
  const runStamp = stampOf(file);
  if (!runStamp) return null;
  const id = f.slice(0, -5);
  const stamp = `${runStamp}|${stampOf(path.join(DATA_DIR, "tasks", id, "meta.json"))}|${projectsStamp}`;
  const hit = summaryCache.get(f);
  if (hit && hit.stamp === stamp) return hit.summary;
  const run = readJson(file, null);
  const summary = run && run.runId ? summariseRun(run) : null;
  summaryCache.set(f, { stamp, summary });
  return summary;
}

/** One chat's summary (its title, who and text) without parsing its transcript again. */
function runSummary(id) {
  const safe = safeId(id);
  return safe ? cachedSummary(`${safe}.json`) : null;
}

/** Which agent sessions each chat holds (server/history.js: what's already imported). */
function listRunSessions() {
  return runIndexes()
    .filter((i) => i.runId)
    .map(({ runId, sessionId, agentSessions, imported }) => ({ runId, sessionId, agentSessions, imported }));
}

function summariseRun(run) {
  // Read straight off disk by listRunSummaries(), so it has not been through
  // loadRun()'s normalisation — a run file written before `messages` existed,
  // or a truncated one, would otherwise take the sidebar down with it.
  const messages = Array.isArray(run.messages) ? run.messages : [];
  const last = messages[messages.length - 1] || null;
  let task = null;
  let meta = {};
  try {
    meta = JSON.parse(fs.readFileSync(path.join(DATA_DIR, "tasks", run.runId, "meta.json"), "utf8"));
    task = { status: meta.status || "", phase: meta.phase || "", branch: meta.branch || "", declared: meta.declared || null, prUrl: meta.prUrl || "", title: require("./tasks").shownTitle(meta.title, run.text), worktree: meta.worktree || "", plan: Array.isArray(meta.plan) ? meta.plan : [] };
  } catch {}
  return {
    runId: run.runId,
    kind: run.kind || "slack",
    task,
    createdAt: run.createdAt,
    updatedAt: run.updatedAt,
    who: run.who,
    channel: run.channel,
    channelId: run.channelId,
    text: run.text,
    action: run.action,
    triage: run.triage || "",
    triageReason: run.triageReason || "",
    startedBy: run.startedBy || "",
    started: run.action !== "pending" || !!run.sessionId,
    // Has a job actually *run* against this thread? Drives the sidebar's Start
    // button.
    worked: hasWorked(run),
    phase: run.phase,
    outcome: run.outcome,
    prUrl: run.prUrl || (task && task.prUrl) || "",
    linearUrl: run.linearUrl,
    board: run.board ? run.board.column : "",
    pinned: !!run.pinned,
    archived: !!run.archivedAt,
    archivedAt: run.archivedAt || 0,
    project: require("./projects").of(run, meta),
    workdir: (run.opts && run.opts.workdir) || "",
    agent: (run.opts && run.opts.agent) || "",
    permalink: run.permalink,
    cost: run.cost || 0,
    messages: messages.length,
    seenAt: run.seenAt || 0,
    unread: (run.updatedAt || 0) > (run.seenAt || 0),
    // A job blocked on you, rather than merely working. Deliberately louder
    // than `unread` in the sidebar: an unread chat is something to read when
    // you get to it, an awaiting one is a session sitting idle burning nothing
    // until you answer. Cleared by server/jobs.js the moment it is answered, and
    // swept at boot by clearPendingAsks() — the child died with the server, so
    // a pendingAsk that outlives a restart is asking on behalf of nobody.
    awaiting: !!(run.pendingAsk && run.pendingAsk.id),
    askedFor: (run.pendingAsk && run.pendingAsk.summary) || "",
    live: run.action === "running" || (last && last.state === "running") || false,
    lastRole: last ? last.role : null,
    lastText: last ? String(last.text || "").slice(0, 160) : "",
  };
}

/** Every chat whose transcript mentions `q`, newest first, with the line it
 *  matched. A linear scan of data/runs: fine at hundreds of chats. */
function searchRuns(q, limit = 30) {
  const needle = String(q || "").trim().toLowerCase();
  if (needle.length < 2) return [];
  const hits = [];
  for (const run of runIndexes()) {
    if (!run.runId) continue;
    const fields = run.fields;
    let hit = null;
    for (let i = fields.length - 1; i >= 0 && !hit; i--) if (fields[i].lower.includes(needle)) hit = fields[i];
    if (!hit) continue;
    const text = String(hit.text);
    const i = text.toLowerCase().indexOf(needle);
    const snippet = (i > 40 ? "…" : "") + text.slice(Math.max(0, i - 40), i + needle.length + 80).replace(/\s+/g, " ");
    hits.push({ runId: run.runId, who: run.who, kind: run.kind || "slack", role: hit.role, snippet, updatedAt: run.updatedAt || 0 });
  }
  return hits.sort((a, b) => b.updatedAt - a.updatedAt).slice(0, limit);
}

let seq = 0;
function newMessageId() {
  seq = (seq + 1) % 1e6;
  return `${Date.now().toString(36)}${seq.toString(36)}`;
}

function appendMessage(run, msg) {
  const full = {
    id: newMessageId(),
    ts: Math.floor(Date.now() / 1000),
    ...msg,
  };
  run.messages.push(full);
  return full;
}

/* ------------------------------------------------------- one thread, one chat */

/**
 * A run id is a Slack **thread** ts, not the ts of whichever message you
 * copied the link of. One conversation is one chat: pasting a link to a later
 * reply in a thread that already has a chat opens that chat instead of
 * starting a second, half-informed run against the same request.
 */

/** Has a pipeline or a job actually run against this thread? */
function hasWorked(run) {
  return (
    !!run.sessionId ||
    ["acted", "running", "error"].includes(run.action) ||
    !!run.prUrl ||
    !!run.linearUrl
  );
}

/**
 * Pull the channel and thread out of a Slack link.
 *
 * Accepts what "Copy link" gives you for a top-level message
 * (`…/archives/C0B34/p1784615086259089`) and for a reply in a thread
 * (`…/archives/C0B34/p1784615099123456?thread_ts=1784615086.259089&cid=C0B34`).
 * A Slack permalink carries the message's own ts with the dot stripped; the
 * `thread_ts` query parameter, when present, is the thread it lives in.
 */
function parseSlackLink(link) {
  let url;
  try {
    url = new URL(String(link || "").trim());
  } catch {
    throw new Error("that isn't a link — paste the Slack message's \"Copy link\" URL");
  }
  if (url.protocol !== "https:" || !/(^|\.)slack\.com$/i.test(url.hostname)) {
    throw new Error("not a slack.com link");
  }
  const m = /\/archives\/([A-Z0-9]+)\/p(\d{10})(\d{6})(?:\/|$)/.exec(url.pathname);
  if (!m) throw new Error("couldn't find a channel and message in that Slack link");
  const channelId = m[1];
  const messageTs = `${m[2]}.${m[3]}`;
  const thread = url.searchParams.get("thread_ts");
  const threadTs = thread && /^\d{10}\.\d{6}$/.test(thread) ? thread : messageTs;
  return {
    channelId,
    messageTs,
    threadTs,
    permalink: `${url.origin}${url.pathname}${thread ? `?thread_ts=${threadTs}&cid=${channelId}` : ""}`,
  };
}

/**
 * Open (or create) the chat for a pasted Slack link.
 *
 * Nothing is fetched here — this process holds no Slack credentials. The chat
 * starts as just the link; the pipeline reads the thread through the Slack
 * connector inside its Claude session and narrates who asked and what they
 * said back into the chat (see emit.sh's `who=`/`message=` fields).
 */
function createFromLink(link) {
  const parsed = parseSlackLink(link);
  const id = safeId(parsed.threadTs);
  if (!id) throw new Error("bad thread id in that link");
  const existing = loadRun(id);
  if (existing) return { run: existing, created: false };
  const run = blankRun(id, {
    channelId: parsed.channelId,
    threadTs: parsed.threadTs,
    rootTs: parsed.messageTs,
    permalink: parsed.permalink,
    who: "Slack thread",
    text: parsed.permalink,
    action: "pending",
  });
  saveRun(run);
  return { run, created: true };
}

/** Forget a chat, for good. The Slack thread, PR and Linear issue stay. */
function deleteRun(id) {
  const safe = safeId(id);
  if (!safe) return false;
  try {
    fs.unlinkSync(runPath(safe));
  } catch {
    // Already gone.
  }
  return true;
}

module.exports = {
  PATHS,
  sanitizeJobOpts,
  jobOpts,
  isDir,
  readConfig,
  writeConfig,
  summariseCost,
  summariseUsage,
  safeId,
  blankRun,
  loadRun,
  saveRun,
  setBoard,
  setPinned,
  setArchived,
  setProject,
  BOARD_COLUMNS,
  clearPendingAsks,
  listRunSummaries,
  runSummary,
  runStamp: (id) => (safeId(id) ? stampOf(runPath(safeId(id))) : ""),
  listRunSessions,
  searchRuns,
  appendMessage,
  parseSlackLink,
  createFromLink,
  deleteRun,
  ensureRunsDir,
};
