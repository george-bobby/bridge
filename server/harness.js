/**
 * The harness: spawn, watch, relay, recover, clean up.
 *
 * The dashboard server *is* the watcher. Every worker is a child of this
 * process, so "is it busy, idle, stalled, gone" is read off the live stream
 * rather than scraped from a terminal, and there is no background watcher per
 * worker that can be forgotten, chained untracked, or left un-armed: one
 * process sees every job start and end (server/jobs.js `events`), plus a timer
 * for stalls and a boot pass for whatever happened while it was down.
 *
 * An outcome is the unit of "this needs attention":
 *
 *   report               a worker wrote or changed report.md
 *   idle-without-report  it changed code but ended without one (after one automatic nudge)
 *   worker-stalled       no activity for N minutes, not declared waiting
 *   worker-gone          it died, or the dashboard restarted under it
 *   usage-limit          the agent hit a usage limit
 *
 * Each outcome goes to events.log, the task's chat, the Inbox (decisions and
 * to-dos), a browser notification when it needs you, and, for work the
 * orchestrator started and mode allowing, a relay turn in the orchestrator chat.
 */

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const env = require("./env");
const store = require("./store");
const jobs = require("./jobs");
const tasks = require("./tasks");
const bus = require("./bus");
const projects = require("./projects");
const failover = require("./failover");

const ROOT = path.join(__dirname, "..");
const ORCH = "orchestrator";
const USER = env.slackUserName;
const now = () => Math.floor(Date.now() / 1000);
const AWAY_QUEUE = path.join(tasks.DIR, "away-queue.json");

const cfg = () => store.readConfig().harness;

/* --------------------------------------------------------- orchestrator */

/** A project's orchestrator chat. Created on first use; never deleted by the
 *  harness. Default's (the root folder) keeps the original `orchestrator` id. */
function ensureOrchestrator(projectId = projects.DEFAULT) {
  const id = projects.orchestratorId(projectId);
  let run = store.loadRun(id);
  // It works in its project's checkout ("this repo" means the project), with
  // Bridge added as a directory. A chat that already has a session keeps the
  // folder it was minted in, or --resume would no longer find it.
  const p = projects.get(projectId);
  const home = p && p.path && fs.existsSync(p.path) ? p.path : ROOT;
  if (run && run.kind === "orchestrator") {
    const fix = run.project !== projectId || (!run.sessionId && (run.opts || {}).workdir !== home);
    if (fix) {
      run.project = projectId;
      if (!run.sessionId) run.opts = { ...run.opts, workdir: home };
      store.saveRun(run);
    }
    return run;
  }
  run = run || store.blankRun(id, { who: "Orchestrator", action: "acted", phase: "idle" });
  run.kind = "orchestrator";
  run.who = "Orchestrator";
  run.project = projectId;
  run.text = "Your second-in-command. Hand it work; it spawns workers and tells you what happened.";
  run.opts = { ...run.opts, workdir: home };
  store.saveRun(run);
  return run;
}

/** The orchestrator a task's outcomes go to: the one for its project. */
function orchestratorFor(taskId) {
  const run = store.loadRun(taskId);
  return ensureOrchestrator(run ? projects.of(run, tasks.readMeta(taskId) || {}) : projects.DEFAULT).runId;
}

/* ---------------------------------------------------------------- titles */

function titleOf(taskId) {
  const meta = tasks.readMeta(taskId) || {};
  // The cached summary carries who/text/permalink: no need to parse a
  // transcript that can run to megabytes for its title (the Inbox asks per row).
  const run = store.runSummary(taskId);
  return String(meta.title || (run && (run.who !== "Slack thread" ? `${run.who}: ${run.text}` : run.permalink)) || taskId).slice(0, 90);
}

/* -------------------------------------------------------------- outcomes */

const NEEDS_YOU = new Set(["needs-input", "blocked", "idle-without-report", "worker-stalled", "worker-gone", "usage-limit"]);

/** Status written to meta.json for each outcome. */
function statusFor(name, parsed) {
  if (name === "report") return parsed ? parsed.status : "unknown";
  return name;
}

function outcome(taskId, name, info = {}) {
  const parsed = info.parsed || null;
  const status = statusFor(name, parsed);
  const title = titleOf(taskId);
  const text =
    name === "report"
      ? `${status}: ${(parsed && parsed.tldr) || "(no TL;DR)"}`.slice(0, 600)
      : String(info.text || name).slice(0, 600);

  tasks.writeMeta(taskId, { status, lastOutcome: name, lastOutcomeAt: now() });
  tasks.appendEvent({ taskId, name, status, text });

  // The Inbox. One ask is one item: a rewritten report keeps what it still
  // asks (answered or dismissed ones stay closed) and drops what it no longer does.
  const created = [];
  if (name === "report" && parsed) {
    const mine = new Set(parsed.yours.map(tasks.askText));
    const asks = [...parsed.questions.map((t) => ["question", t]), ...parsed.actions.map((t) => ["action", t])].filter(([, t]) => !mine.has(tasks.askText(t)));
    if ((status === "needs-input" || status === "blocked") && !asks.length && !parsed.yours.length) asks.push(["question", `${status}: ${parsed.tldr || "see the report"}`]);
    const still = new Set(asks.map(([k, t]) => `${k}:${tasks.askText(t)}`));
    tasks.closeTaskDecisions(taskId, ["question", "action", "resume"], "superseded", (d) => still.has(`${d.kind}:${tasks.askText(d.text)}`));
    for (const [kind, t] of asks) {
      const r = tasks.addDecision({ taskId, kind, text: t, fromReport: true });
      if (!r.duplicate) created.push(r.decision);
    }
    // "For you": things only the user can do, as to-dos. Ticked off stays ticked off.
    const yours = parsed.yours.map((y) => ({ key: `you:${taskId}:${tasks.hash(tasks.askText(y)).slice(0, 8)}`, text: y }));
    tasks.closeTaskTodos(taskId, `you:${taskId}:`, new Set(yours.map((y) => y.key)));
    for (const y of yours) tasks.addTodo({ ...y, taskId, once: true });
    // Workers write `pr: none` too; only a URL is a PR. The chat shows it; no review to-do.
    if (/^https?:\/\//.test(parsed.fields.pr || "")) tasks.writeMeta(taskId, { prUrl: parsed.fields.pr });
  } else if (NEEDS_YOU.has(name)) {
    tasks.closeTaskDecisions(taskId, ["resume"]);
    created.push(tasks.addDecision({ taskId, kind: "resume", text: `${name}: ${text}` }).decision);
  }

  // The chat.
  const run = store.loadRun(taskId);
  if (run) {
    const said = name === "report" ? `Report: ${(parsed && parsed.tldr) || status}` : `**${name}** · ${text}`;
    const msg = store.appendMessage(run, { role: "event", phase: "outcome", text: said.slice(0, 600) });
    store.saveRun(run);
    bus.broadcast("message", { runId: taskId, message: msg });
  }

  const needsYou = NEEDS_YOU.has(name) || NEEDS_YOU.has(status) || (parsed && (parsed.actions.length > 0 || parsed.yours.length > 0));
  bus.broadcast("outcome", { taskId, name, status, text, title, needsYou });
  bus.broadcast("inbox", inbox());
  bus.broadcast("runs", { runs: store.listRunSummaries() });

  relay(taskId, name, { status, text, title, parsed, needsYou, decisions: created });
}

/** Apply automatic failover before a run's next turn. Usage.all() keeps the
 * existing provider cache and rate-limit backoff, so this adds no new polling. */
async function autoFailover(runId) {
  const run = store.loadRun(runId);
  if (!run) return null;
  const config = store.readConfig();
  if (!config.harness.failover) return null;
  const currentAgent = store.jobOpts(config, run).agent || "claude";
  if (currentAgent !== "claude") return null;
  const [usage, catalog] = await Promise.all([require("./usage").all(), require("./agents").catalog()]);
  const pick = failover.decide({
    usage,
    harness: config.harness,
    currentAgent,
    orchestrator: projects.isOrchestrator(runId),
    installed: catalog.agents.filter((a) => a.installed).map((a) => a.id),
  });
  if (!pick) return null;
  run.opts = { ...run.opts, agent: pick.agent };
  delete run.opts.agentModel;
  const label = { devin: "Devin", codex: "Codex", cursor: "Cursor" }[pick.agent];
  const text = `Automatically switched from Claude to ${label}: Claude ${pick.window} usage is ${Math.round(pick.usedPct)}% (${pick.threshold}% threshold)`;
  const msg = store.appendMessage(run, { role: "event", phase: "failover", text });
  store.saveRun(run);
  tasks.appendEvent({ taskId: runId, name: "agent-failover", text });
  bus.broadcast("message", { runId, message: msg });
  bus.broadcast("run-updated", { runId });
  return pick;
}

/* ----------------------------------------------------------------- relay */

function relayText(taskId, name, { status, text, title, parsed, decisions }) {
  const lines = [`[harness] OUTCOME ${name} · task ${taskId} · "${title}"`, `status: ${status}`, text];
  if (parsed) {
    if (/^https?:\/\//.test(parsed.fields.pr || "")) lines.push(`PR: ${parsed.fields.pr}`);
    if (parsed.questions.length) lines.push(`open questions: ${parsed.questions.length}`);
    if (parsed.actions.length) lines.push(`action requests: ${parsed.actions.length}`);
    if (parsed.yours.length) lines.push(`for ${USER} to do: ${parsed.yours.length} (in To-dos)`);
  }
  if (decisions && decisions.length) lines.push(`Inbox: ${decisions.map((d) => `${d.id} (${d.kind})`).join(", ")}`);
  lines.push(`Report: ${tasks.paths(taskId).report}`);
  lines.push(`Relay this to ${USER} in 1-3 lines, leading with anything they need to do.`);
  return lines.join("\n");
}

function relay(taskId, name, info) {
  if (projects.isOrchestrator(taskId)) return;
  // Only work the orchestrator started goes back to it. A chat you started
  // yourself is already in front of you, and every relay is a whole
  // orchestrator turn (its instructions and roster included).
  const meta = tasks.readMeta(taskId) || {};
  if (meta.by !== "orchestrator") return;
  // A report rewritten with the same status, TL;DR and asks says nothing new,
  // and relaying it re-reads the orchestrator's whole context for a no-op.
  const key = relayKey(name, info);
  if (meta.lastRelay === key) return;
  tasks.writeMeta(taskId, { lastRelay: key });
  send(orchestratorFor(taskId), relayText(taskId, name, info), info.needsYou);
}

/** What a relay says, minus Inbox ids (new on every report even when the asks are the same). */
function relayKey(name, { status, text, parsed }) {
  const p = parsed || { fields: {}, questions: [], actions: [], yours: [] };
  const raw = [name, status, text, p.fields.pr || "", p.questions.join("\n"), p.actions.join("\n"), (p.yours || []).join("\n")].join("\u0001");
  return crypto.createHash("sha1").update(raw).digest("hex").slice(0, 16);
}

/** A relay turn, mode allowing: quiet keeps only what needs you, away holds it for the catch-up. */
function send(orch, text, needsYou) {
  const c = cfg();
  if (!c.relay) return;
  if (c.mode === "quiet" && !needsYou) return;
  if (c.mode === "away") {
    const q = readJson(AWAY_QUEUE, []);
    q.push({ at: now(), text });
    writeJson(AWAY_QUEUE, q.slice(-200));
    return;
  }
  try {
    jobs.startFollowup(orch, text, { config: store.readConfig(), role: "relay", label: "relay", queue: true });
  } catch (e) {
    tasks.appendEvent({ taskId: ORCH, name: "relay-failed", text: e.message });
  }
}

/** Something for the default orchestrator that isn't a worker's outcome (a Slack mention). */
function note(text, { needsYou = true } = {}) {
  send(ensureOrchestrator().runId, text, needsYou);
}

/** Leaving away mode: one catch-up turn with everything that was held back. */
function setMode(mode) {
  if (!["normal", "quiet", "away"].includes(mode)) throw new Error("mode is normal, quiet or away");
  const before = cfg().mode;
  store.writeConfig({ harness: { mode } });
  if (before === "away" && mode !== "away") {
    const held = readJson(AWAY_QUEUE, []);
    writeJson(AWAY_QUEUE, []);
    if (held.length && cfg().relay) {
      ensureOrchestrator();
      const text = `[harness] ${USER} is back (mode: ${mode}). While away, ${held.length} outcome(s) were held:\n\n${held
        .map((h) => h.text.replace(/\nRelay this to .*$/m, ""))
        .join("\n\n")}\n\nBrief ${USER}: what needs them first, then the rest in a few lines.`;
      jobs.startFollowup(ORCH, text, { config: store.readConfig(), role: "relay", label: "catch-up", queue: true });
    }
  }
  bus.broadcast("inbox", inbox());
  return cfg();
}

/* ------------------------------------------------------------- job ends */

const LIMIT = /(usage limit|rate[ -]?limit(ed)?|limit reached|quota exceeded|credit balance is too low|out of (extra )?usage|5-hour limit|weekly limit)/i;

async function onJobEnd(e) {
  const { runId, role, why, result, stderr, reportHashBefore } = e;

  if (role === "orchestrator" || e.kind === "compact") {
    await drain(runId);
    return;
  }
  const meta = tasks.readMeta(runId) || {};

  if (why === "stopped") {
    tasks.writeMeta(runId, { status: "stopped" });
    tasks.appendEvent({ taskId: runId, name: "stopped", text: "stopped from the dashboard" });
    bus.broadcast("inbox", inbox());
    // A stop with a message behind it (interrupt and send) starts that next.
    drain(runId);
    return;
  }

  const said = `${(result && result.text) || ""}\n${stderr || ""}`;
  if (LIMIT.test(said) && (!result || result.failed || why !== "closed")) {
    outcome(runId, "usage-limit", { text: (said.match(new RegExp(`.{0,120}${LIMIT.source}.{0,120}`, "i")) || [said.trim().slice(-200)])[0] });
    return;
  }

  // A queued follow-up goes in before judging this turn: the worker is about
  // to get another turn, and it will report at the end of that one.
  if (await drain(runId)) return;

  const r = tasks.readReport(runId);
  const changedThisTurn = r && r.hash !== reportHashBefore;
  if (r && r.hash !== meta.reportHash) {
    tasks.writeMeta(runId, { reportHash: r.hash, nudged: false, stallFlagged: false });
    outcome(runId, "report", { parsed: r.parsed });
  } else if (!changedThisTurn) {
    const crashed = !result && why !== "closed";
    const work = !crashed && !meta.imported && !r && (await hasWork(meta));
    if (jobs.isRunning(runId)) return;
    if (crashed) {
      outcome(runId, "worker-gone", { text: `the session ended without a result (${why}). ${String(stderr || "").trim().split("\n").slice(-2).join(" ")}`.trim() });
    } else if (!work) {
      // A turn that answered a question, or a follow-up on a chat that already
      // has a report, ends like any chat's: no nudge (a nudge is a whole extra
      // turn), no outcome. An imported chat never took on the report contract.
      // The status goes back to what the report says (a turn sets "working").
      tasks.writeMeta(runId, { status: r ? statusFor("report", r.parsed) : "idle" });
    } else if (!meta.nudged) {
      // Work in the worktree and no report: one automatic nudge, then it's yours.
      tasks.writeMeta(runId, { nudged: true });
      tasks.appendEvent({ taskId: runId, name: "nudged", text: "ended a turn without a report" });
      try {
        await autoFailover(runId);
        jobs.startFollowup(
          runId,
          `[harness] You changed code but haven't written ${tasks.paths(runId).report}. Write a short one now (status frontmatter, TL;DR, what changed, how you verified it), then stop.`,
          { config: store.readConfig(), role: "harness", label: "nudge" }
        );
        return;
      } catch {}
    } else {
      outcome(runId, "idle-without-report", { text: "changed code but ended without a report, even after a nudge" });
    }
  }
}

/** Whether a task's checkout holds work worth a report: uncommitted changes or commits on its branch. */
async function hasWork(meta) {
  const dir = meta.worktree;
  if (!dir || !fs.existsSync(dir)) return false;
  const git = (args) =>
    new Promise((resolve) => require("child_process").execFile("git", ["-C", dir, ...args], { encoding: "utf8", timeout: 5000 }, (err, out) => resolve(err ? "" : String(out).trim())));
  if (await git(["status", "--porcelain"])) return true;
  const base = meta.from || meta.base;
  return !!base && Number(await git(["rev-list", "--count", `${base}..HEAD`])) > 0;
}

/** Start one queued follow-up for a chat, if any. True when one started. */
async function drain(runId) {
  const next = jobs.takePending(runId);
  if (!next) return false;
  try {
    await autoFailover(runId);
    jobs.startFollowup(runId, next.text, { config: store.readConfig(), role: next.role, label: next.label });
    return true;
  } catch (e) {
    tasks.appendEvent({ taskId: runId, name: "followup-failed", text: e.message });
    return false;
  }
}

/* --------------------------------------------------------------- stalls */

function checkStalls() {
  const c = cfg();
  for (const runId of jobs.runningIds()) {
    const act = jobs.activity(runId);
    if (!act || projects.isOrchestrator(runId)) continue;
    const meta = tasks.readMeta(runId) || {};
    const idleSec = (Date.now() - act.lastEventAt) / 1000;
    if (meta.stallFlagged && idleSec < 60) {
      tasks.writeMeta(runId, { stallFlagged: false, status: "working" });
      continue;
    }
    if (act.awaiting) continue; // blocked on you; the ask card covers it
    // BRIDGE_STALL_SEC is the tests' override; minutes are too slow to wait on.
    const budget = Number(process.env.BRIDGE_STALL_SEC) || c.stallMinutes * 60;
    if (meta.declared && meta.declared.state === "waiting") {
      // A declared wait gets four times the budget, not forever.
      if (idleSec < budget * 4) continue;
    }
    if (idleSec > budget && !meta.stallFlagged) {
      tasks.writeMeta(runId, { stallFlagged: true });
      outcome(runId, "worker-stalled", {
        text: `no activity for ${Math.round(idleSec / 60)} min${act.tool ? ` (inside a ${act.tool} call)` : ""}${meta.declared && meta.declared.state === "waiting" ? `, declared waiting on: ${meta.declared.text}` : ""}`,
      });
    }
  }
}

/* -------------------------------------------------------------- capacity */

// No cap on parallel workers: every task starts right away.
function workingCount() {
  let total = 0;
  for (const id of jobs.runningIds()) {
    if (projects.isOrchestrator(id)) continue;
    const meta = tasks.readMeta(id) || {};
    if (meta.declared && meta.declared.state === "waiting") continue; // waiting doesn't count
    total++;
  }
  return { total };
}

/* ----------------------------------------------------------------- spawn */

/**
 * A worker from a brief: validate, worktree, chat, task folder, then start.
 * Returns the task id.
 */
async function spawnTask({ repo, title, brief, branch, base = "", workspace = "", opts = {}, start = true, by = "" }) {
  const text = String(brief || "").trim();
  if (!text) throw new Error("a task needs a brief");
  if (text.length > 60000) throw new Error("brief too long");
  const repoPath = path.resolve(String(repo || projects.rootDir()));
  const t = title ? String(title).replace(/^#+\s*/, "").slice(0, 80).trim() : tasks.titleFrom(text);
  const id = tasks.newTaskId(t);
  // A short time-based suffix keeps two tasks with the same title apart.
  const br = branch || `${env.branchPrefix}/${tasks.slugify(t) || "task"}-${Date.now().toString(36).slice(-4)}`;

  // Where it works: a fresh worktree (the default), the main checkout
  // ("local"), or an existing worktree of this repo (its path). Bridge never
  // removes a checkout it didn't create.
  let wt;
  const ws = String(workspace || "").trim();
  // Not a git checkout (Default's root folder): the session just runs there.
  const plain = !fs.existsSync(path.join(repoPath, ".git"));
  if (plain) wt = { worktree: repoPath, branch: "", base: "", from: "", copied: 0, adopted: "folder" };
  else if (!ws || ws === "worktree") wt = await tasks.createWorktree({ repo: repoPath, branch: br, from: base });
  else {
    const info = await tasks.branches(repoPath);
    const dir = ws === "local" ? info.worktrees.find((w) => w.main) : info.worktrees.find((w) => path.resolve(w.path) === path.resolve(ws));
    if (!dir) throw new Error(ws === "local" ? "can't find the main checkout" : `not a worktree of ${repoPath}: ${ws}`);
    wt = { worktree: dir.path, branch: dir.branch || dir.head, base: info.default, from: "", copied: 0, adopted: ws === "local" ? "local" : "worktree" };
  }

  const p = tasks.paths(id);
  tasks.writeBrief(id, `# ${t}\n\n${text}\n`);
  tasks.writeMeta(id, { kind: "task", title: t, repo: repoPath, worktree: wt.worktree, branch: wt.branch, base: wt.base, from: wt.from, status: "new", ...(wt.adopted ? { adopted: wt.adopted } : {}), ...(by === "orchestrator" ? { by } : {}) });

  const run = store.blankRun(id, { who: t, text: text.slice(0, 400), action: "pending", phase: "queued" });
  run.kind = "task";
  run.opts = { ...store.sanitizeJobOpts(opts), workdir: wt.worktree };
  store.appendMessage(run, { role: "user", text });
  store.saveRun(run);
  if (!opts.agent) await autoFailover(id);
  tasks.appendEvent({ taskId: id, name: "spawned", text: `${t} · ${wt.branch} in ${wt.worktree}${wt.copied ? ` · ${wt.copied} file(s) from .worktreeinclude` : ""}` });

  let state = "created";
  if (start) {
    jobs.startTask(id, { config: store.readConfig() });
    state = "started";
  }
  bus.broadcast("runs", { runs: store.listRunSummaries() });
  bus.broadcast("inbox", inbox());
  return { taskId: id, state, worktree: wt.worktree, branch: wt.branch, brief: p.brief };
}

/**
 * A chat you had with Claude Code, Codex, Cursor or Devin outside Bridge,
 * as a worker: its transcript, in the folder it ran in, carrying on in the
 * same agent session on your next message. The folder is adopted, never
 * removed by cleanup. Importing the same chat again opens the first import.
 */
async function importChat({ agent, id, project = "", history = require("./history") }) {
  if (!history.AGENTS.includes(agent)) throw new Error(`unknown agent: ${agent}`);
  if (!id) throw new Error("which chat?");
  const known = () => history.known(store.listRunSessions()).get(`${agent}:${id}`);
  if (known()) return { taskId: known(), existing: true };
  const opts = { agents: [agent], runs: store.listRunSessions() };
  const [list, t] = await Promise.all([history.listAsync ? history.listAsync(opts) : history.list(opts), history.readAsync ? history.readAsync(agent, id) : history.read(agent, id)]);
  const chat = list.chats.find((c) => c.id === id) || {};
  if (!t.messages.length) throw new Error("that chat has nothing to import");
  // Its session only makes sense in the folder it ran in: never carry it on elsewhere.
  if (!env.demo && (!t.cwd || !fs.existsSync(t.cwd))) throw new Error(`the folder this chat ran in is gone${t.cwd ? ` (${t.cwd})` : ""}, so it can't carry on`);
  const cwd = t.cwd;
  const git = (args) =>
    new Promise((resolve) => require("child_process").execFile("git", ["-C", cwd, ...args], { encoding: "utf8", timeout: 5000 }, (err, out) => resolve(err ? "" : String(out).trim())));
  const [branch, common] = cwd ? await Promise.all([git(["rev-parse", "--abbrev-ref", "HEAD"]), git(["rev-parse", "--path-format=absolute", "--git-common-dir"])]) : ["", ""];
  if (known()) return { taskId: known(), existing: true };
  const repo = common ? path.dirname(common) : cwd;
  const label = { claude: "Claude Code", codex: "Codex", cursor: "Cursor", devin: "Devin" }[agent];
  const title = String(chat.title || (t.messages.find((m) => m.role === "user") || {}).text || `${label} chat`)
    .replace(/\s+/g, " ")
    .slice(0, 80)
    .trim();
  const taskId = tasks.newTaskId(title);
  tasks.writeBrief(taskId, `# ${title}\n\nImported from ${label} (session \`${id}\`${cwd ? ` in ${cwd}` : ""}). The transcript is the chat itself; carry on from where it left off.\n`);
  tasks.writeMeta(taskId, { kind: "task", title, repo, worktree: cwd, branch, base: "", from: "", status: "imported", adopted: "import", imported: { agent, id } });

  const run = store.blankRun(taskId, { who: title, text: String(chat.prompt || title).slice(0, 400), action: "pending", phase: "idle" });
  run.kind = "task";
  run.imported = { agent, id, at: now() };
  run.opts = { ...run.opts, agent, workdir: cwd, ...(t.model && agent !== "claude" ? { agentModel: t.model } : {}) };
  // The agent resumes its own session: Claude by the chat's session id, the
  // others through agentSessions (see jobs.launchAgent).
  if (agent === "claude") run.sessionId = id;
  else run.agentSessions = { [agent]: id };
  for (const m of t.messages) store.appendMessage(run, m);
  store.appendMessage(run, { role: "event", phase: "imported", text: `Imported from **${label}**: ${t.messages.length} messages${cwd ? ` in \`${cwd}\`` : ""}. Your next message continues the same ${label} session.` });
  run.createdAt = Math.min(...t.messages.map((m) => m.ts || now())) || now();
  // The project it belongs to: the one it was imported into, else the one its
  // folder is in. Set directly: store.setProject would also move a chat
  // without a Claude session id into the project's checkout.
  run.project = (project && projects.get(project) ? project : "") || projects.of(run, tasks.readMeta(taskId) || {}) || "";
  store.saveRun(run);
  tasks.appendEvent({ taskId, name: "imported", text: `${label} session ${id}${cwd ? ` in ${cwd}` : ""}` });
  bus.broadcast("runs", { runs: store.listRunSummaries() });
  return { taskId, existing: false };
}

/** Pipeline start for a Slack chat. */
function startSlack(runId) {
  const run = store.loadRun(runId);
  if (!run) throw new Error("unknown run");
  // The chat's project (Hand to Claude in a project) decides the repo.
  const repo = jobs.resolveWorkdir(store.readConfig(), run);
  tasks.writeMeta(runId, { kind: "slack", repo, title: run.text || run.permalink || runId });
  jobs.startPipeline(runId, { config: store.readConfig() });
  return { state: "started" };
}

/* -------------------------------------------------------------- relaunch */

async function relaunch(taskId, note = "") {
  if (jobs.isRunning(taskId)) throw new Error("that worker is running; send a follow-up instead");
  const run = store.loadRun(taskId);
  if (!run) throw new Error("unknown task");
  tasks.closeTaskDecisions(taskId, ["resume"], "answered");
  tasks.writeMeta(taskId, { nudged: false, stallFlagged: false });
  tasks.appendEvent({ taskId, name: "relaunched", text: note || "" });
  await autoFailover(taskId);
  if (!run.sessionId) {
    if (run.kind === "task") return jobs.startTask(taskId, { config: store.readConfig(), note: "Relaunched." });
    return jobs.startPipeline(taskId, { config: store.readConfig() });
  }
  const meta = tasks.readMeta(taskId) || {};
  return jobs.startFollowup(
    taskId,
    `[harness] You were interrupted (last state: ${meta.status || "unknown"}). Pick up where you left off: check the worktree's git status and your report, then continue toward the definition of done. ${note}`.trim(),
    { config: store.readConfig(), role: "harness", label: "relaunch" }
  );
}

/* --------------------------------------------------------------- declare */

function declare(taskId, state, text = "") {
  if (!tasks.exists(taskId)) throw new Error(`no such task: ${taskId}`);
  if (!["waiting", "resumed", "phase"].includes(state)) throw new Error("declare waiting | resumed | phase");
  const patch = { declared: { state: state === "phase" ? (tasks.readMeta(taskId).declared || {}).state || "working" : state === "resumed" ? "working" : state, text, at: now() } };
  if (state === "phase") patch.phase = text;
  tasks.writeMeta(taskId, patch);
  const run = store.loadRun(taskId);
  if (run) {
    const msg = store.appendMessage(run, { role: "event", phase: state === "phase" ? "phase" : state, text: text || state });
    store.saveRun(run);
    bus.broadcast("message", { runId: taskId, message: msg });
  }
  bus.broadcast("runs", { runs: store.listRunSummaries() });
  return tasks.readMeta(taskId);
}

/* --------------------------------------------------------------- answers */

/**
 * A worker's task list, for agents without a to-do tool of their own
 * (`bridge plan`): set replaces it, add appends, start/done/skip mark item n
 * (1-based), clear removes it. Stored on the task; the app shows it as the
 * Tasks progress, like a TodoWrite list.
 */
function plan(taskId, op, args = []) {
  if (!tasks.exists(taskId)) throw new Error(`no such task: ${taskId}`);
  const meta = tasks.readMeta(taskId) || {};
  let items = Array.isArray(meta.plan) ? meta.plan.map((x) => ({ ...x })) : [];
  const texts = args.map((a) => String(a || "").replace(/\s+/g, " ").trim().slice(0, 300)).filter(Boolean);
  const at = (n) => {
    const i = Number(n) - 1;
    if (!Number.isInteger(i) || i < 0 || i >= items.length) throw new Error(`no item ${n}: the list has ${items.length}`);
    return i;
  };
  if (op === "set") {
    if (!texts.length) throw new Error('plan set "<item>" "<item>" …');
    items = texts.slice(0, 50).map((text) => ({ text, status: "pending" }));
  } else if (op === "add") {
    if (!texts.length) throw new Error('plan add "<item>"');
    items.push(...texts.map((text) => ({ text, status: "pending" })));
  } else if (op === "start" || op === "done" || op === "skip") {
    if (!args.length) throw new Error(`plan ${op} <n>`);
    for (const n of args) {
      const i = at(n);
      if (op === "start") items.forEach((x, j) => j !== i && x.status === "in_progress" && (x.status = "pending"));
      items[i].status = op === "start" ? "in_progress" : op === "done" ? "completed" : "cancelled";
    }
  } else if (op === "clear") items = [];
  else throw new Error("plan set|add|start|done|skip|clear");
  items = items.slice(0, 50);
  tasks.writeMeta(taskId, { plan: items, planAt: now() });
  bus.broadcast("runs", { runs: store.listRunSummaries() });
  return items;
}

/**
 * Answer a decision. A question's answer goes back to its worker as a
 * follow-up in your words; "do it" on an action sends the worker to make
 * the call, which the guard then puts to you as an exact-payload approval.
 */
async function decide(id, { answer = "", action = "answer" } = {}) {
  const d = tasks.decisions().find((x) => x.id === id);
  if (!d) throw new Error(`no such decision: ${id}`);
  if (action === "dismiss") return tasks.updateDecision(id, { state: "dismissed" });
  if (action === "defer") {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(answer)) throw new Error("defer takes a date: YYYY-MM-DD");
    return tasks.updateDecision(id, { state: "deferred", deferUntil: answer });
  }
  if (d.kind === "resume") {
    await relaunch(d.taskId, answer);
    return tasks.updateDecision(id, { state: "answered", answer: answer || "resumed" });
  }
  const msg =
    d.kind === "action"
      ? `[harness] ${USER} approved your action request:\n"""\n${d.text}\n"""\n${answer ? `${USER} adds: ${answer}\n` : ""}Make exactly this write now (the harness will show ${USER} the exact payload once more), then update your report.`
      : `[harness] ${USER} answered your open question:\n"""\n${d.text}\n"""\nAnswer, in ${USER}'s words: ${answer}\n\nContinue, then update your report.`;
  if (d.kind === "question" && !String(answer).trim()) throw new Error("an answer needs words");
  await autoFailover(d.taskId);
  const out = jobs.startFollowup(d.taskId, msg, { config: store.readConfig(), role: "harness", label: d.kind === "action" ? "approved" : "answer", queue: true });
  const rec = tasks.updateDecision(id, { state: "answered", answer: answer || "approved", deliveredAs: out && out.queued ? "queued" : "started" });
  tasks.appendEvent({ taskId: d.taskId, name: "decided", text: `${d.kind}: ${answer || "approved"}`.slice(0, 300) });
  bus.broadcast("inbox", inbox());
  return rec;
}

/* --------------------------------------------------------------- cleanup */

async function cleanup(taskId, { force = false } = {}) {
  if (jobs.isRunning(taskId)) throw new Error("stop the worker before cleaning up its worktree");
  const meta = tasks.readMeta(taskId);
  if (!meta) throw new Error(`no such task: ${taskId}`);
  // Another live task working in this checkout (it adopted it): leave it be.
  const borrower = meta.worktree && !meta.adopted ? tasks.list().find((t) => t.id !== taskId && t.adopted && t.worktree && path.resolve(t.worktree) === path.resolve(meta.worktree) && !["cleaned", "deleted"].includes(t.status)) : null;
  if (borrower) {
    const err = new Error(`refusing: ${borrower.id} is working in ${meta.worktree}. Clean that task up first.`);
    err.refused = true;
    throw err;
  }
  if (!meta.worktree || meta.adopted) {
    tasks.writeMeta(taskId, { status: "cleaned", cleanedAt: now() });
    closeInbox(taskId);
    return { removed: false, note: meta.adopted ? `${meta.adopted === "local" ? "the main checkout" : "an existing worktree"} isn't Bridge's to remove: left in place` : "no worktree recorded" };
  }
  const insp = await tasks.inspectWorktree(meta.worktree);
  if (insp.exists && (insp.dirty || insp.unpushed) && !force) {
    const why = [insp.dirty ? `${insp.dirtyFiles} uncommitted change(s)` : "", insp.unpushed ? `${insp.unpushed} unpushed commit(s)` : ""].filter(Boolean).join(" and ");
    const err = new Error(`refusing: ${meta.worktree} has ${why}. Push or commit first, or clean up with force.`);
    err.refused = true;
    throw err;
  }
  const killed = [];
  if (insp.exists) {
    for (const pid of await tasks.pidsInside(meta.worktree)) {
      try {
        process.kill(pid, "SIGTERM"); // exact PID, never a group or pattern
        killed.push(pid);
      } catch {}
    }
    await tasks.removeWorktree({ repo: meta.repo, worktree: meta.worktree, force: force && (insp.dirty || insp.unpushed > 0) });
  }
  tasks.writeMeta(taskId, { status: "cleaned", cleanedAt: now() });
  closeInbox(taskId);
  tasks.appendEvent({ taskId, name: "cleaned", text: `${meta.worktree} removed; branch ${meta.branch || "?"} kept${killed.length ? `; stopped pids ${killed.join(", ")}` : ""}` });
  bus.broadcast("runs", { runs: store.listRunSummaries() });
  return { removed: insp.exists, killed, branch: meta.branch };
}

/** A cleaned-up or deleted task has nothing left to ask: its open decisions and to-dos close. */
function closeInbox(taskId) {
  const decisions = tasks.closeTaskDecisions(taskId, null, "dismissed");
  const todos = tasks.closeTaskTodos(taskId);
  if (decisions || todos) bus.broadcast("inbox", inbox());
  return { decisions, todos };
}

/**
 * A deleted chat takes its task out of the Inbox and the roster: open
 * decisions and to-dos close, the task is marked `deleted`. The worktree and
 * branch stay on disk (`bridge cleanup` is still the way to remove those).
 */
function discard(taskId) {
  if (tasks.exists(taskId)) {
    tasks.writeMeta(taskId, { status: "deleted", deletedAt: now() });
    tasks.appendEvent({ taskId, name: "deleted", text: "chat deleted; its open decisions and to-dos were dismissed" });
  }
  return closeInbox(taskId);
}

/**
 * Archiving a chat puts it away without losing it: its open decisions and
 * to-dos close and it leaves the sidebar, board, Workers and the roster.
 * Unarchiving brings the chat back as it was; the closed Inbox items stay closed.
 */
function archive(id, on = true) {
  if (on && jobs.isRunning(id)) throw new Error("stop the running job first");
  const archived = store.setArchived(id, on);
  if (tasks.exists(id)) {
    tasks.writeMeta(id, { archived });
    tasks.appendEvent({ taskId: id, name: archived ? "archived" : "unarchived", text: archived ? "chat archived; its open decisions and to-dos were dismissed" : "chat unarchived" });
  }
  if (archived) closeInbox(id);
  bus.broadcast("runs", { runs: store.listRunSummaries() });
  return { archived };
}

/**
 * Settings › Sessions "Auto-archive merged chats": archive a chat once its PR
 * has been merged for `autoArchiveDays` (0 = off). Takes the pulls feed
 * (sources.pulls()); a chat that is running or was unarchived by hand is left
 * alone. Worktrees stay on disk. Returns the ids it archived.
 */
function autoArchive(pulls, nowMs = Date.now()) {
  const days = cfg().autoArchiveDays;
  if (!days || !pulls || !Array.isArray(pulls.merged)) return [];
  const norm = (u) => String(u || "").split(/[?#]/)[0].replace(/\/+$/, "").toLowerCase();
  const mergedAt = new Map();
  for (const p of pulls.merged) if (p && p.url && p.mergedAt) mergedAt.set(norm(p.url), Date.parse(p.mergedAt));
  if (!mergedAt.size) return [];
  const done = [];
  for (const s of store.listRunSummaries()) {
    if (s.archived || s.kind === "orchestrator" || projects.isOrchestrator(s.runId) || !s.prUrl) continue;
    const at = mergedAt.get(norm(s.prUrl));
    if (!at || nowMs - at < days * 86400_000 || jobs.isRunning(s.runId)) continue;
    const run = store.loadRun(s.runId);
    if (!run || run.unarchivedAt) continue;
    try {
      archive(s.runId, true);
      if (tasks.exists(s.runId)) tasks.appendEvent({ taskId: s.runId, name: "auto-archived", text: `PR merged ${days} day${days === 1 ? "" : "s"} ago` });
      done.push(s.runId);
    } catch (err) {
      console.error(`harness: auto-archive of ${s.runId} failed:`, err.message);
    }
  }
  return done;
}

/* -------------------------------------------------------- status/catchup */

const GONE = new Set(["cleaned", "deleted"]);

function status() {
  return tasks.list().filter((m) => m.status !== "deleted" && !m.archived).map((m) => {
    const live = jobs.isRunning(m.id);
    const act = jobs.activity(m.id);
    const r = tasks.readReport(m.id);
    const notes = [];
    if (m.status === "working" && !live) notes.push("meta says working but no live job (lost?)");
    if (live && !["working", "worker-stalled"].includes(m.status)) notes.push(`a job is live but status is ${m.status}`);
    return {
      id: m.id,
      kind: m.kind || "task",
      title: m.title || m.id,
      status: m.status,
      live,
      awaiting: !!(act && act.awaiting),
      idleSec: act ? Math.round((Date.now() - act.lastEventAt) / 1000) : null,
      tool: act ? act.tool : "",
      phase: m.phase || "",
      declared: m.declared || null,
      reportStatus: r ? r.parsed.status : "",
      tldr: r ? r.parsed.tldr.slice(0, 300) : "",
      pr: [r && r.parsed.fields.pr, m.prUrl].find((u) => /^https?:\/\//.test(u || "")) || "",
      repo: m.repo || "",
      worktree: m.worktree || "",
      branch: m.branch || "",
      queuedFollowups: jobs.pendingCount(m.id),
      notes,
      createdAt: m.createdAt,
      updatedAt: m.updatedAt,
    };
  });
}

function inbox() {
  const c = cfg();
  const titles = new Map();
  const t = (id) => {
    if (!titles.has(id)) titles.set(id, titleOf(id));
    return titles.get(id);
  };
  const decisions = tasks.openDecisions().map((d) => ({ ...d, ...tasks.parseAsk(d.text), title: t(d.taskId) }));
  const todos = tasks.todos().filter((x) => !x.done).map((x) => ({ ...x, title: x.taskId ? t(x.taskId) : "" }));
  // Required here, not at the top: watch.js starts pipelines through this module.
  const slack = require("./watch").open();
  return { mode: c.mode, decisions, todos, slack, counts: { decisions: decisions.length, todos: todos.length, slack: slack.filter((i) => i.verdict !== "skip").length } };
}

function catchup(since) {
  const from = typeof since === "number" ? since : tasks.parseSince(since);
  return { since: from, ...inbox(), tasks: status().filter((s) => !GONE.has(s.status)), events: tasks.readEvents({ since: from }) };
}

/* ----------------------------------------------------------------- brief */

const SINCE = /^\d{1,3}[mhd]$/;
const one = (t, n = 200) => String(t || "").replace(/\s+/g, " ").trim().slice(0, n);
const ago = (t) => {
  const s = now() - (t || 0);
  return s < 5400 ? `${Math.max(1, Math.round(s / 60))}m` : s < 172800 ? `${Math.round(s / 3600)}h` : `${Math.round(s / 86400)}d`;
};

/**
 * "Brief me": the catch-up, gathered here and handed to the orchestrator in
 * one turn, so it summarises what's already in front of it instead of
 * querying the harness first. Returns its id, and whether the turn queued
 * behind one already running.
 */
function brief({ since = "8h", orchestrator = "" } = {}) {
  if (!SINCE.test(since)) throw new Error("since is like 3h, 45m or 2d");
  const orch = orchestrator && projects.isOrchestrator(orchestrator) && store.loadRun(orchestrator) ? orchestrator : ensureOrchestrator().runId;
  const c = catchup(since);
  const section = (title, rows) => (rows.length ? [`## ${title}`, ...rows, ""] : [`## ${title}`, "none", ""]);
  const text = [
    `[harness] BRIEF ${USER} asked for a catch-up on the last ${since} (mode: ${c.mode}). This is the current state; answer from it.`,
    "",
    ...section("Waiting on you", c.decisions.map((d) => `- ${d.id} (${d.kind}) ${one(d.title, 80)}: ${one(d.text)}`)),
    ...section("Slack, not started", c.slack.map((i) => `- ${i.id} ${i.who} in ${i.channel || "Slack"}${i.verdict ? ` [triage: ${i.verdict}${i.reason ? `, ${one(i.reason, 80)}` : ""}]` : ""}: ${one(i.text)}`)),
    ...section("To-dos", c.todos.map((t) => `- ${t.key}: ${one(t.text)}${t.url ? ` ${t.url}` : ""}`)),
    ...section("Workers", c.tasks.map((t) => `- ${t.id} [${t.status || "?"}${t.live ? ", live" : ""}] ${one(t.title, 80)}${t.pr ? ` ${t.pr}` : ""}${t.tldr ? `: ${one(t.tldr)}` : ""}`)),
    ...section(`What happened (last ${since})`, c.events.slice(-40).map((e) => `- ${ago(e.at)} ago ${e.name} ${e.taskId}: ${one(e.text, 160)}`)),
    `Brief ${USER} in a few lines: what needs them first (name the Inbox item or chat), then what moved. Skip what they can't act on.`,
  ].join("\n");
  const out = jobs.startFollowup(orch, text, { config: store.readConfig(), role: "relay", label: "brief", queue: true });
  return { runId: orch, queued: !!(out && out.queued) };
}

/* ---------------------------------------------------------------- boot */

/**
 * After a restart. Every child died with the old process, so a task still
 * marked `working` was lost mid-turn, and a report written while nobody
 * watched is caught up on.
 */
function recover() {
  ensureOrchestrator();
  tasks.closeTodos("review:"); // "Review the PR" to-dos are no longer made; clear what's left
  for (const m of tasks.list()) {
    if (GONE.has(m.status) || m.archived) continue;
    const r = tasks.readReport(m.id);
    if (r && r.hash !== m.reportHash) {
      tasks.writeMeta(m.id, { reportHash: r.hash, nudged: false });
      outcome(m.id, "report", { parsed: r.parsed });
      continue;
    }
    if (m.status === "working" || m.status === "worker-stalled") {
      tasks.writeMeta(m.id, { stallFlagged: false });
      outcome(m.id, "worker-gone", { text: "the dashboard restarted while this worker was mid-turn; resume it to continue" });
    }
  }
  // Runs left "running" in the chat file died too.
  for (const s of store.listRunSummaries()) {
    if (s.action === "running") {
      const run = store.loadRun(s.runId);
      run.action = "error";
      run.phase = "interrupted";
      store.saveRun(run);
    }
  }
}

/* -------------------------------------------------------------- wiring */

function readJson(f, fb) {
  try {
    return JSON.parse(fs.readFileSync(f, "utf8"));
  } catch {
    return fb;
  }
}
function writeJson(f, v) {
  fs.mkdirSync(path.dirname(f), { recursive: true });
  fs.writeFileSync(f, JSON.stringify(v, null, 2) + "\n");
}

let started = false;
function start() {
  if (started) return;
  started = true;
  fs.mkdirSync(tasks.DIR, { recursive: true });
  jobs.events.on("end", (e) => onJobEnd(e).catch((err) => console.error("harness: job end handling failed:", err)));
  recover();
  const tick = Number(process.env.BRIDGE_TICK_MS) || 30000;
  let archivedAt = 0;
  setInterval(() => {
    try {
      checkStalls();
    } catch (err) {
      console.error("harness: stall check failed:", err);
    }
    // Merged PRs move slowly: look every ten minutes, off the feed's cache.
    if (cfg().autoArchiveDays && Date.now() - archivedAt > 600_000) {
      archivedAt = Date.now();
      require("./sources")
        .pulls()
        .then((p) => autoArchive(p))
        .catch(() => {}); // no gh login or offline: try again next round
    }
  }, tick).unref();
}

module.exports = {
  ORCH,
  start,
  ensureOrchestrator,
  importChat,
  plan,
  spawnTask,
  startSlack,
  relaunch,
  declare,
  decide,
  cleanup,
  discard,
  archive,
  autoArchive,
  status,
  inbox,
  catchup,
  brief,
  setMode,
  note,
  outcome,
  workingCount,
  autoFailover,
};
