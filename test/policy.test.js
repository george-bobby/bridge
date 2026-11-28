const test = require("node:test");
const assert = require("node:assert");
const { spawnSync } = require("child_process");
const path = require("path");

const { check, DEFAULT_POLICY } = require("../server/policy");

const P = { policy: { ...DEFAULT_POLICY }, auto: {} };
const bash = (command) => check("Bash", { command }, P);
const verdict = (command) => (bash(command) || { decision: "pass" }).decision;

test("kill: exact PIDs pass, everything else is denied", () => {
  for (const ok of ["kill 12345", "kill -9 12345", "kill -TERM 12345 12346", "kill -s KILL 4242", "kill -l", "lsof -t -iTCP:4319"]) {
    assert.equal(verdict(ok), "pass", ok);
  }
  for (const bad of [
    "pkill -f node",
    "killall Finder",
    "kill 0",
    "kill -9 -1",
    "kill -- -4242",
    "kill $PID",
    "kill $(lsof -t -iTCP:4319)",
    "kill `cat pid`",
    "lsof -t -i:3000 | xargs kill -9",
    "sudo pkill node",
    "kill %1",
    "cd /tmp && pkill -f vite",
  ]) {
    assert.equal(verdict(bad), "deny", bad);
  }
});

test("secrets: env dumps, process argv and .env reads are denied", () => {
  for (const bad of ["env", "env | grep TOKEN", "printenv", "printenv GITHUB_TOKEN", "export -p", "set", "ps aux", "ps -ef", "ps -o pid,args", "pgrep -fl node", "cat .env", "grep KEY ../.env.local", "gh auth token", "doppler secrets"]) {
    assert.equal(verdict(bad), "deny", bad);
  }
  for (const ok of ["env FOO=1 node x.js", "echo ${#GITHUB_TOKEN}", "ps -o pid=,comm= -p 123", "pgrep node", "cat .env.example", "sed -n 's/=.*//p' .env", "GH_TOKEN=$(gh auth token --user me) gh pr view 1", "doppler secrets --only-names"]) {
    assert.equal(verdict(ok), "pass", ok);
  }
  assert.equal(check("Read", { file_path: "/x/repo/.env" }, P).decision, "deny");
  assert.equal(check("Read", { file_path: "/x/repo/.env.example" }, P), null);
  for (const bad of ["while read l; do echo $l; done <.env", "cat < .env.local", "base64 .env"]) assert.equal(verdict(bad), "deny", bad);
  assert.equal(verdict("sed -n 's/=.*//p' < .env"), "pass");
  assert.equal(check("Grep", { pattern: "TOKEN", glob: "**/.env*" }, P).decision, "deny");
  assert.equal(check("Grep", { pattern: "TOKEN", glob: ".env.example" }, P), null);
});

test("a backslash-newline doesn't split a command", () => {
  assert.equal(verdict("git push \\\n  --force origin main"), "ask");
});

test("destructive git asks; ordinary git passes", () => {
  for (const ask of ["git push --force", "git push -f origin x", "git push --force-with-lease", "git push origin +main", "git push origin :old", "git reset --hard origin/main", "git clean -fdx", "git branch -D feat", "git -C /r worktree remove --force /w", "git stash drop"]) {
    assert.equal(verdict(ask), "ask", ask);
  }
  for (const ok of ["git push -u origin feat", "git push", "git reset HEAD~1", "git branch -d merged", "git worktree remove /w", "git status", "git commit -m 'fix: kill the flake'"]) {
    assert.equal(verdict(ok), "pass", ok);
  }
});

test("destructive git inside substitutions, shells, eval and wrappers still asks", () => {
  for (const ask of ['echo "$(git push --force origin main)"', 'echo "`git reset --hard`"', 'x="$(git branch -D feat)"', 'bash -c "git push --force"', "sh -lc 'git clean -fdx'", 'eval "git stash drop"', "env FOO=1 git push --force", "xargs -n 1 git branch -D", "nice -n 5 git reset --hard"]) {
    assert.equal(verdict(ask), "ask", ask);
  }
  assert.equal(check("Bash", { command: "env FOO=1" }, P).decision, "deny", "assignments only still dump the environment");
  assert.equal(check("Bash", { command: 'bash -c "cat .env"' }, P).decision, "deny");
  for (const ok of ['git commit -m "fix (scope): $(date)"', 'echo "a; b"', "env FOO=1 node test.js"]) assert.equal(verdict(ok), "pass", ok);
});

test("Bridge's own API: a session writes only what bin/bridge sends; reads pass", () => {
  const port = require("../server/env").port;
  const at = (p) => `http://127.0.0.1:${port}${p}`;
  for (const p of ["/api/config", "/api/env", "/api/restart", "/api/slack/reply", "/api/runs/x/answer", "/api/tasks/../config"]) {
    for (const c of [`curl -X POST ${at(p)} -d '{}'`, `curl --json '{}' "$BRIDGE_URL${p}"`, `wget --post-data=x localhost:${port}${p}`, `http POST :${port}${p} a=b`, `node -e "fetch('${at(p)}', { method: 'POST' })"`, `python3 -c "urlopen('${at(p)}', data=b'x')"`, `bash -c "curl -XPOST [::1]:${port}${p}"`]) {
      assert.equal(verdict(c), "deny", c);
    }
  }
  assert.equal(verdict(`printf 'POST /api/config' | nc 127.0.0.1 ${port}`), "deny");
  assert.equal(verdict(`exec 3<>/dev/tcp/127.0.0.1/${port}`), "deny");
  // Every route bin/bridge writes to (bin/bridge `call("POST", …)`), plus emit.sh's event.
  for (const p of ["/api/tasks", "/api/runs", "/api/runs/t-1/followup", "/api/runs/t-1/event", "/api/runs/t-1/agent", "/api/tasks/t-1/relaunch", "/api/tasks/t-1/declare", "/api/tasks/t-1/plan", "/api/tasks/t-1/cleanup", "/api/decisions/d-1", "/api/slack/watch/s-1", "/api/todos", "/api/todos/done"]) {
    assert.equal(verdict(`curl -X POST ${at(p)} -d '{}'`), "pass", p);
  }
  for (const p of ["/api/config", "/api/env", "/api/state"]) assert.equal(verdict(`curl -s ${at(p)}`), "pass", `GET ${p}`);
  assert.equal(verdict(`${path.join(__dirname, "..", "bin", "bridge")} spawn --repo . --title x --brief "POST the form"`), "pass");
  assert.equal(verdict(`nc -z localhost ${port}`), "pass");
  assert.equal(verdict("curl -X POST http://localhost:39999/login -d x"), "pass", "another local server's non-API route");
  assert.equal(verdict("curl -X POST http://localhost:39999/api/login -d x"), "ask", "another local server's API asks");
});

test("archive, stop and rename (bridge archive|unarchive|stop|rename) are an orchestrator's writes only", () => {
  const port = require("../server/env").port;
  const as = (role, p) => (check("Bash", { command: `curl -X POST http://127.0.0.1:${port}${p} -d '{}'` }, { ...P, role }) || { decision: "pass" }).decision;
  for (const p of ["/api/runs/t-1/archive", "/api/runs/t-1/stop", "/api/runs/t-1/title"]) {
    assert.equal(as("orchestrator", p), "pass", `orchestrator ${p}`);
    assert.equal(as("task", p), "deny", `worker ${p}`);
    assert.equal(as("", p), "deny", `no role ${p}`);
  }
  assert.equal(as("orchestrator", "/api/runs/t-1/answer"), "deny", "the rest of the API stays the app's");
});

test("gh: PR workflow passes, merges and issue writes ask, review replies follow policy", () => {
  for (const ok of ["gh pr create --fill", "gh pr edit 12 --body x", "gh pr view 12", "gh api repos/o/r/pulls/12", "gh pr comment 12 -b hi", "gh api -X POST repos/o/r/pulls/12/comments/9/replies -f body=x"]) {
    assert.equal(verdict(ok), "pass", ok);
  }
  for (const ask of ["gh pr merge 12 --squash", "gh pr close 12", "gh issue create -t x", "gh api -X PATCH repos/o/r/issues/3 -f state=closed", "gh api graphql -f query=x", "curl -X POST https://hooks.slack.com/x -d '{}'"]) {
    assert.equal(verdict(ask), "ask", ask);
  }
  assert.equal(verdict("curl -s http://127.0.0.1:4319/api/state"), "pass");
});

test("a project with auto-merge on merges without asking; admin merges and closes still ask", () => {
  const on = { policy: { ...DEFAULT_POLICY }, auto: { merge: true } };
  const v = (command, o) => (check("Bash", { command }, o) || { decision: "pass" }).decision;
  for (const cmd of ["gh pr merge 12 --merge", "gh pr merge --squash --delete-branch", "cd x && gh pr merge 3 --auto --merge"]) {
    assert.equal(v(cmd, on), "pass", cmd);
    assert.equal(v(cmd, P), "ask", `${cmd} (auto-merge off)`);
  }
  for (const cmd of ["gh pr merge 12 --admin --merge", "gh pr close 12", "gh api -X PUT repos/o/r/pulls/12/merge"]) assert.equal(v(cmd, on), "ask", cmd);
  assert.equal(v("gh pr merge 12", { ...on, auto: { merge: false, review: true } }), "ask");
});

test("the hook reads the session's project (BRIDGE_PROJECT) for auto-merge", () => {
  const os = require("os");
  const fs = require("fs");
  const data = fs.mkdtempSync(path.join(os.tmpdir(), "bridge-auto-"));
  fs.writeFileSync(path.join(data, "projects.json"), JSON.stringify([{ id: "web", name: "web", path: data, auto: { merge: true } }, { id: "api", name: "api", path: data }]));
  const hook = path.join(__dirname, "..", "hooks", "guard.js");
  const input = JSON.stringify({ tool_name: "Bash", tool_input: { command: "gh pr merge 7 --merge" } });
  const run = (project) => {
    const r = spawnSync(process.execPath, [hook], { input, encoding: "utf8", env: { ...process.env, BRIDGE_DATA_DIR: data, BRIDGE_ENV_FILE: path.join(data, "none.env"), BRIDGE_PROJECT: project } });
    return r.stdout ? JSON.parse(r.stdout).hookSpecificOutput.permissionDecision : "pass";
  };
  assert.equal(run("web"), "pass");
  assert.equal(run("api"), "ask");
  assert.equal(run("default"), "ask");
  assert.equal(run(""), "ask");
  fs.rmSync(data, { recursive: true, force: true });
});

test("policy overrides relax a category without touching the rails", () => {
  const relaxed = { policy: { ...DEFAULT_POLICY, prComments: "ask", chat: "allow" } };
  assert.equal(check("Bash", { command: "gh pr comment 1 -b x" }, relaxed).decision, "ask");
  assert.equal(check("mcp__acme__slack_send_message", { text: "hi" }, relaxed), null);
  assert.equal(check("Bash", { command: "pkill node" }, relaxed).decision, "deny");
});

test("mcp: reads pass, outward writes ask, local servers pass", () => {
  const ask = (n) => (check(n, {}, P) || { decision: "pass" }).decision;
  for (const n of ["mcp__acme__slack_send_message", "mcp__acme__slack_add_reaction", "mcp__acme__linear_save_issue", "mcp__acme__linear_save_comment", "mcp__acme__github_merge_pull_request", "mcp__acme__notion_notion-update-page", "mcp__acme__create_campaign", "mcp__mcp-modal__deploy_modal_app", "mcp__acme__send_slack_dm_as_bot"]) {
    assert.equal(ask(n), "ask", n);
  }
  for (const n of ["mcp__acme__slack_read_thread", "mcp__acme__slack_search_public_and_private", "mcp__acme__linear_get_issue", "mcp__acme__linear_list_issues", "mcp__acme__github_get_file_contents", "mcp__acme__github_create_pull_request", "mcp__datadog__search_datadog_logs", "mcp__acme__execute_sql", "mcp__chrome-devtools__click", "mcp__acme__slack_create-message-draft", "mcp__acme__get_project"]) {
    assert.equal(ask(n), "pass", n);
  }
});

test("the hook script speaks the PreToolUse protocol and fails open", () => {
  const hook = path.join(__dirname, "..", "hooks", "guard.js");
  const run = (stdin) => spawnSync(process.execPath, [hook], { input: stdin, encoding: "utf8" });

  const denied = run(JSON.stringify({ tool_name: "Bash", tool_input: { command: "pkill -f node" } }));
  assert.equal(denied.status, 0);
  const out = JSON.parse(denied.stdout).hookSpecificOutput;
  assert.equal(out.hookEventName, "PreToolUse");
  assert.equal(out.permissionDecision, "deny");

  const passed = run(JSON.stringify({ tool_name: "Bash", tool_input: { command: "kill 4242" } }));
  assert.equal(passed.status, 0);
  assert.equal(passed.stdout, "");

  const garbage = run("not json");
  assert.equal(garbage.status, 0);
  assert.equal(garbage.stdout, "");
  assert.equal(run("null").status, 0);

  const broken = spawnSync(process.execPath, [hook], { input: JSON.stringify({ tool_name: "Bash", tool_input: { command: "pkill node" } }), encoding: "utf8", env: { ...process.env, MCP_READ_PREFIXES: "docs_,(" } });
  assert.equal(JSON.parse(broken.stdout).hookSpecificOutput.permissionDecision, "deny");
});
