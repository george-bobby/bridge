/**
 * What each relay mode lets Bridge do without asking you. Pure: the guard,
 * the harness and the tests all ask the same functions.
 *
 *   normal  every approval, question and merge waits for you (policy gates as set)
 *   quiet   routine things are taken with the recommended option (questions
 *           with one, safe local prompts, green merges where the project
 *           allows); risky or outward things
 *           still reach you, batched in one Inbox digest, no routine notifications
 *   away    the orchestrator runs things: every outcome goes to it, it answers,
 *           merges green PRs, relaunches stalled workers, fails over on limits,
 *           and logs what it decided to the digest. No notifications.
 *
 * Hard limits hold in every mode: nothing here ever auto-approves a Slack or
 * Linear write, a new thread, a force-push to main, a merge on red CI, or
 * removing a worktree with unpushed work. In away they are refused outright
 * (nobody is there to approve), so the worker lists them for you instead.
 */

const MODES = ["normal", "quiet", "away"];
const mode = (m) => (MODES.includes(m) ? m : "normal");

/** Policy categories that are never auto-taken: Slack, Linear/issues, docs. */
const HARD = new Set(["chat", "tickets", "docs"]);
const MAIN = /^(main|master|trunk|develop|production|release)$/;

/**
 * The guard's `ask`, adjusted for the mode: "ask" | "deny". `toMain` marks a
 * force-push that reaches main. (A lease push to your own branch already
 * passes in every mode, in policy.js.)
 */
function gate(m, { category, toMain = false } = {}) {
  if (mode(m) !== "away") return "ask";
  if (HARD.has(category) || category === "prMerge" || (category === "destructiveGit" && toMain)) return "deny";
  return "ask";
}

/** Why the guard refused in away mode, for the model to act on. */
function denyReason(category, user = "the user") {
  if (category === "prMerge") return `away mode: merge with \`bridge merge <task-id>\` instead; it merges only when CI is green.`;
  if (category === "destructiveGit") return `away mode: a force-push to main is a hard limit. Push to your own branch with --force-with-lease, or list it under Action requests for ${user}.`;
  return `away mode: ${user} is away and Slack, Linear and doc writes are a hard limit. Draft it and list it under Action requests in your report; ${user} sees it when back.`;
}

/** The recommended option of a parsed ask ({options}), or null. */
function recommended(ask) {
  const opts = (ask && ask.options) || [];
  const rec = opts.filter((o) => o.recommended);
  return rec.length === 1 ? rec[0] : null;
}

/** Whether Bridge answers a report's question itself, and with what ("B) label"). */
function autoAnswer(m, kind, ask) {
  if (mode(m) === "normal" || kind !== "question") return null;
  const r = recommended(ask);
  return r ? `${r.key}) ${r.label}` : null;
}

/**
 * A live AskUserQuestion: answers for every question when each has exactly one
 * option labelled "(Recommended)", else null. Shape: { [question]: label }.
 */
function autoQuestions(m, questions) {
  if (mode(m) === "normal" || !Array.isArray(questions) || !questions.length) return null;
  const out = {};
  for (const q of questions) {
    if (q.multiSelect) return null;
    const rec = (q.options || []).filter((o) => /\(recommended\)/i.test(String(o.label || "")));
    if (rec.length !== 1) return null;
    out[String(q.question || "")] = String(rec[0].label);
  }
  return out;
}

const SAFE_TOOLS = new Set(["Bash", "Read", "Grep", "Glob", "LS", "Edit", "Write", "MultiEdit", "NotebookEdit", "WebFetch", "WebSearch", "TodoWrite"]);
// Deleting data still reaches you: rm -r/-f, SQL drops, dropping a database.
const RISKY = /(^|[;&|\s(])rm\s+-[a-zA-Z]*[rRf]|\b(drop|truncate)\s+(table|database|schema)\b|\bdropdb\b|\bdelete\s+from\b|\bgit\s+(reset|clean|branch\s+-D|stash\s+(drop|clear)|worktree\s+remove)\b/i;

/**
 * A permission prompt from the session's own permission mode (not the guard,
 * whose asks `guarded` is true for): taken in quiet and away when the tool is
 * local and the call doesn't delete data. Plan approvals always wait for you.
 */
function autoAllow(m, { tool, input = {}, guarded = false } = {}) {
  if (mode(m) === "normal" || guarded || !SAFE_TOOLS.has(tool)) return false;
  if (tool === "Bash" && RISKY.test(String(input.command || ""))) return false;
  return true;
}

/** Green CI from `gh pr view --json statusCheckRollup`: at least one check, none failing or pending. */
function ciGreen(rollup) {
  const checks = Array.isArray(rollup) ? rollup : [];
  if (!checks.length) return false;
  return checks.every((c) => {
    if (c.__typename === "StatusContext" || (c.state && !c.conclusion)) return String(c.state).toUpperCase() === "SUCCESS";
    return String(c.status).toUpperCase() === "COMPLETED" && ["SUCCESS", "NEUTRAL", "SKIPPED"].includes(String(c.conclusion).toUpperCase());
  });
}

/**
 * The mode half of mergeRefusal: null when this mode may merge in this
 * project. Quiet needs the project's auto-merge toggle (`project.auto.merge`,
 * Settings › Projects); away is the switch itself and merges anywhere.
 */
function modeMergeRefusal(m, project) {
  m = mode(m);
  if (m === "normal") return "normal mode: merges wait for the user; ask in your report";
  if (m === "quiet" && !(project && project.auto && project.auto.merge === true)) return "quiet mode merges only where the project allows auto-merge; ask in your report";
  return null;
}

/**
 * Whether `bridge merge` may merge: away always, quiet only where the
 * project allows auto-merge, normal never; and in every mode only on green CI.
 * Returns null when allowed, else the reason.
 */
function mergeRefusal(m, { pr, project } = {}) {
  const why = modeMergeRefusal(m, project);
  if (why) return why;
  if (!pr) return "no PR";
  if (pr.state && pr.state !== "OPEN") return `the PR is ${String(pr.state).toLowerCase()}`;
  if (pr.isDraft) return "the PR is a draft";
  if (MAIN.test(String(pr.headRefName || ""))) return "the PR's head is a main branch";
  if (pr.mergeable === "CONFLICTING") return "the PR has conflicts: rebase it first";
  if (!ciGreen(pr.statusCheckRollup)) return "CI isn't green (failing, pending or no checks): never merge red CI";
  return null;
}

/**
 * Whether an outcome or ask raises a desktop notification. Normal leaves it
 * to the app's own filter (true); quiet only what needs you; away nothing.
 */
function notify(m, { kind, needsYou = false } = {}) {
  m = mode(m);
  if (m === "normal") return true;
  if (m === "away") return false;
  return kind === "ask" || !!needsYou;
}

/** Whether an outcome goes to the orchestrator as a relay turn. */
function relays(m, needsYou) {
  m = mode(m);
  return m !== "quiet" || !!needsYou;
}

/** Whether the harness acts on its own: relaunch a stalled/lost worker, fail over on a limit. */
const runsThings = (m) => mode(m) === "away";

/**
 * The orchestrator's mode lines: only the active mode's, a few lines, the
 * same text until the mode changes (cache-friendly).
 */
function orchestratorLines(m, { user = "the user", bridge = "bridge" } = {}) {
  m = mode(m);
  if (m === "normal") return `Mode: normal. ${user} decides every question, approval and merge; relay and recommend.`;
  if (m === "quiet") {
    return [
      `Mode: quiet. ${user} wants few interruptions. Bridge already takes questions with a recommended option and safe local prompts.`,
      `Relay only what needs ${user}, one line each; log anything you decide with \`${bridge} log "<line>"\`.`,
    ].join("\n");
  }
  return [
    `Mode: away. ${user} is away: you run things and don't message them. With ${bridge}: answer workers' questions with the recommended option (\`decide\`), merge green PRs in dependency order (\`merge <id>\`, which archives it), relaunch stalled workers.`,
    `Log each decision as one line (\`log "<line>"\`): it is ${user}'s digest when back.`,
    `Never: Slack or Linear writes, new threads, force-push to main, merging red CI, cleanup --force on unpushed work; leave those in the Inbox.`,
  ].join("\n");
}

module.exports = { MODES, HARD, mode, gate, denyReason, recommended, autoAnswer, autoQuestions, autoAllow, ciGreen, mergeRefusal, modeMergeRefusal, notify, relays, runsThings, orchestratorLines };
