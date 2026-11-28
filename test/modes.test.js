/**
 * The relay modes as pure decisions (server/modes.js), and the guard asking
 * them (server/policy.js): what each mode asks you, what it takes itself,
 * and the hard limits that hold in away.
 */

const test = require("node:test");
const assert = require("node:assert");

const modes = require("../server/modes");
const { check, DEFAULT_POLICY } = require("../server/policy");

const opts = (mode, branch = "feature/x") => ({ policy: { ...DEFAULT_POLICY }, auto: {}, mode, branchAt: () => branch });
const guard = (mode, command, branch) => (check("Bash", { command }, opts(mode, branch)) || { decision: "pass" }).decision;
const mcp = (mode, tool) => (check(tool, {}, opts(mode)) || { decision: "pass" }).decision;

test("normal asks exactly as before, whatever the call", () => {
  for (const c of ["git push --force origin main", "git reset --hard", "gh pr merge 5 --merge", "gh issue create -t x"]) {
    assert.equal(guard("normal", c), "ask", c);
  }
  assert.equal(mcp("normal", "mcp__slack__slack_send_message"), "ask");
});

test("quiet: a rebase's lease push to your own branch passes (as in every mode); everything risky still asks", () => {
  assert.equal(guard("quiet", "git push --force-with-lease"), "pass", "bare push from a feature branch");
  assert.equal(guard("quiet", "git push --force-with-lease origin feature/x"), "pass");
  assert.equal(guard("quiet", "git push --force-with-lease origin HEAD"), "pass");
  assert.equal(guard("quiet", "git push --force-with-lease", "main"), "ask", "a lease push from main is still a push to main");
  assert.equal(guard("quiet", "git push --force-with-lease origin main"), "ask");
  assert.equal(guard("quiet", "git push --force origin feature/x"), "ask", "a plain --force isn't a lease");
  assert.equal(guard("quiet", "git push --force-with-lease", ""), "ask", "unknown branch");
  for (const c of ["git reset --hard", "git branch -D old", "git clean -fd", "gh pr merge 5 --merge", "gh issue comment 3 -b hi"]) assert.equal(guard("quiet", c), "ask", c);
  assert.equal(mcp("quiet", "mcp__slack__slack_send_message"), "ask");
  assert.equal(mcp("quiet", "mcp__linear__linear_save_issue"), "ask");
});

test("away: hard limits are refused outright, with a reason the worker can act on", () => {
  assert.equal(guard("away", "git push --force-with-lease"), "pass");
  for (const c of ["git push --force origin main", "git push --force-with-lease origin master", "git push origin +main", "gh pr merge 5 --merge", "gh issue create -t x"]) {
    assert.equal(guard("away", c), "deny", c);
  }
  for (const t of ["mcp__slack__slack_send_message", "mcp__mercor-mcp__slack_send_message", "mcp__linear__linear_save_comment", "mcp__linear__linear_save_issue", "mcp__github__github_merge_pull_request", "mcp__notion__notion-create-pages"]) {
    assert.equal(mcp("away", t), "deny", t);
  }
  const merge = check("Bash", { command: "gh pr merge 5" }, opts("away"));
  assert.match(merge.reason, /bridge merge/);
  const slack = check("mcp__slack__slack_send_message", {}, opts("away"));
  assert.match(slack.reason, /Action requests/);
  // Not a hard limit: still waits for you rather than being taken.
  assert.equal(guard("away", "git reset --hard"), "ask");
  assert.equal(guard("away", "git push --force origin feature/x"), "ask", "a plain force to your own branch isn't a hard limit");
  assert.equal(guard("away", "git push --force-with-lease", "main"), "deny", "a bare lease push from main reaches main");
  assert.equal(guard("away", "curl -X POST https://api.example.com/x"), "ask");
  // Reads and drafts are untouched in every mode; the safety rails too.
  assert.equal(mcp("away", "mcp__slack__slack_read_thread"), "pass");
  assert.equal(guard("away", "pkill node"), "deny");
});

test("a policy relaxed to allow stays allowed in every mode", () => {
  const relaxed = { ...DEFAULT_POLICY, chat: "allow" };
  assert.equal(check("mcp__slack__slack_send_message", {}, { ...opts("away"), policy: relaxed }), null);
  // A project with auto-merge on (Settings › Projects) merges itself in every mode.
  assert.equal(check("Bash", { command: "gh pr merge 5 --merge" }, { ...opts("away"), auto: { merge: true } }), null);
});

test("questions: only quiet and away take the single recommended option", () => {
  const ask = { options: [{ key: "A", label: "Per user" }, { key: "B", label: "Per IP", recommended: true }] };
  assert.equal(modes.autoAnswer("normal", "question", ask), null);
  assert.equal(modes.autoAnswer("quiet", "question", ask), "B) Per IP");
  assert.equal(modes.autoAnswer("away", "question", ask), "B) Per IP");
  assert.equal(modes.autoAnswer("away", "action", ask), null, "an action request is never auto-approved by the server");
  assert.equal(modes.autoAnswer("away", "question", { options: [{ key: "A", label: "x" }] }), null, "no recommendation");
  assert.equal(modes.autoAnswer("away", "question", { options: [{ key: "A", label: "x", recommended: true }, { key: "B", label: "y", recommended: true }] }), null, "two recommendations");
});

test("live AskUserQuestion: answered only when every question has one (Recommended)", () => {
  const qs = [{ question: "Which store?", options: [{ label: "Redis (Recommended)" }, { label: "Postgres" }] }];
  assert.equal(modes.autoQuestions("normal", qs), null);
  assert.deepEqual(modes.autoQuestions("quiet", qs), { "Which store?": "Redis (Recommended)" });
  assert.equal(modes.autoQuestions("away", [...qs, { question: "Name?", options: [{ label: "a" }, { label: "b" }] }]), null);
  assert.equal(modes.autoQuestions("away", [{ ...qs[0], multiSelect: true }]), null);
});

test("local permission prompts: taken in quiet/away unless guarded or deleting data", () => {
  assert.equal(modes.autoAllow("normal", { tool: "Bash", input: { command: "npm test" } }), false);
  assert.equal(modes.autoAllow("quiet", { tool: "Bash", input: { command: "npm test" } }), true);
  assert.equal(modes.autoAllow("away", { tool: "Edit", input: { file_path: "/x" } }), true);
  assert.equal(modes.autoAllow("away", { tool: "Bash", input: { command: "git push --force" }, guarded: true }), false);
  for (const c of ["rm -rf build", "rm -f a.txt", "psql -c 'drop table users'", "git reset --hard HEAD~1", "git branch -D x"]) {
    assert.equal(modes.autoAllow("away", { tool: "Bash", input: { command: c } }), false, c);
  }
  assert.equal(modes.autoAllow("away", { tool: "mcp__slack__slack_send_message" }), false, "not a local tool");
  assert.equal(modes.autoAllow("away", { tool: "ExitPlanMode" }), false);
});

test("merge: never on red, pending or missing CI; only where the mode allows", () => {
  const green = [{ __typename: "CheckRun", status: "COMPLETED", conclusion: "SUCCESS" }, { __typename: "StatusContext", state: "SUCCESS" }, { status: "COMPLETED", conclusion: "SKIPPED" }];
  const pr = { state: "OPEN", isDraft: false, mergeable: "MERGEABLE", headRefName: "feature/x", statusCheckRollup: green };
  assert.equal(modes.ciGreen(green), true);
  assert.equal(modes.ciGreen([]), false, "no checks is not green");
  assert.equal(modes.ciGreen([...green, { status: "IN_PROGRESS", conclusion: "" }]), false);
  assert.equal(modes.ciGreen([...green, { status: "COMPLETED", conclusion: "FAILURE" }]), false);
  assert.equal(modes.ciGreen([{ __typename: "StatusContext", state: "PENDING" }]), false);

  assert.match(modes.mergeRefusal("normal", { pr }), /normal mode/);
  assert.match(modes.mergeRefusal("quiet", { pr, project: { auto: { merge: false } } }), /quiet mode/);
  assert.equal(modes.mergeRefusal("quiet", { pr, project: { auto: { merge: true } } }), null);
  assert.equal(modes.mergeRefusal("away", { pr }), null);
  assert.equal(modes.mergeRefusal("away", { pr, project: { auto: { merge: false } } }), null, "away is the switch itself");
  assert.match(modes.mergeRefusal("away", { pr: { ...pr, statusCheckRollup: [{ status: "COMPLETED", conclusion: "FAILURE" }] } }), /never merge red CI/);
  assert.match(modes.mergeRefusal("away", { pr: { ...pr, mergeable: "CONFLICTING" } }), /conflicts/);
  assert.match(modes.mergeRefusal("away", { pr: { ...pr, isDraft: true } }), /draft/);
  assert.match(modes.mergeRefusal("away", { pr: { ...pr, state: "MERGED" } }), /merged/);
  assert.match(modes.mergeRefusal("away", { pr: null }), /no PR/);
});

test("notifications and relays per mode", () => {
  assert.equal(modes.notify("normal", { kind: "outcome" }), true);
  assert.equal(modes.notify("quiet", { kind: "outcome", needsYou: false }), false, "no routine notifications in quiet");
  assert.equal(modes.notify("quiet", { kind: "outcome", needsYou: true }), true);
  assert.equal(modes.notify("quiet", { kind: "ask" }), true);
  assert.equal(modes.notify("away", { kind: "ask" }), false);
  assert.equal(modes.notify("away", { kind: "outcome", needsYou: true }), false);
  assert.equal(modes.relays("normal", false), true);
  assert.equal(modes.relays("quiet", false), false);
  assert.equal(modes.relays("quiet", true), true);
  assert.equal(modes.relays("away", false), true, "away: the orchestrator hears everything");
  assert.equal(modes.runsThings("away"), true);
  assert.equal(modes.runsThings("quiet"), false);
});

test("orchestrator lines: only the active mode's, short and stable", () => {
  const all = Object.fromEntries(modes.MODES.map((m) => [m, modes.orchestratorLines(m, { user: "Alex", bridge: "/b/bridge" })]));
  for (const [m, text] of Object.entries(all)) {
    assert.ok(text.startsWith(`Mode: ${m}.`), m);
    for (const other of modes.MODES.filter((o) => o !== m)) assert.ok(!text.includes(`Mode: ${other}`), `${m} has no ${other} lines`);
    assert.ok(text.split("\n").length <= 4, `${m}: at most 4 lines`);
    assert.ok(text.length / 4 < 160, `${m}: ~${Math.round(text.length / 4)} tokens`);
    assert.equal(modes.orchestratorLines(m, { user: "Alex", bridge: "/b/bridge" }), text, "same text every turn");
  }
  for (const limit of ["Slack or Linear", "force-push to main", "red CI", "unpushed"]) assert.ok(all.away.includes(limit), limit);
  assert.equal(modes.orchestratorLines("bogus"), modes.orchestratorLines("normal"));
});
