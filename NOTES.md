# Harness notes

Decisions, mappings and quirks behind the orchestrator harness that was merged
into bridge on 2026-11-13. It is based on a harness prompt shared by a
colleague (phases 0 to 6, with interview questions). Best judgement was
used in place of the interview, so each interview question is answered below
with the choice made and why. Change any of them; most are a setting.

## The one big decision: the dashboard server is the harness

The prompt assumes interactive agent sessions in terminal tabs, watched by
scraping the screen, with a background watcher process per worker. This
machine has no tmux, and bridge already drives Claude Code headless over
the stream-json protocol with `--permission-prompt-tool stdio`. That gives
structured events instead of screen text, and permission prompts and
`AskUserQuestion` routed to the dashboard. So:

| Prompt concept | Here |
| --- | --- |
| worker tab | a dashboard chat running a headless session; **Terminal** chip resumes it in iTerm/Terminal |
| read the screen / busy-idle | the live stream-json events (`jobs.activity()`) |
| `bin/watch <id>` per worker | the server: job start/end events + a stall timer + a boot pass. No per-worker process to forget or chain untracked. |
| end-of-turn guard (stop hook) | not needed: nothing can be left un-watched, because the watcher is the process that owns the workers |
| orchestrator tab | the pinned **Orchestrator** chat; outcomes start a relay turn in it |
| `bin/followup`, `status`, `cleanup`, ... | `bin/bridge <cmd>` (talks to the dashboard's API) |
| first-run dialogs, trust prompt | none in headless `-p` mode |
| shell rc prompts eating keystrokes | not applicable: nothing is typed into a shell |
| CLAUDE.md for the orchestrator | `prompts/orchestrator.md`, appended as its system prompt |
| worker instructions | `prompts/worker.md`, appended to every worker (typed tasks and Slack pipeline runs) |
| kill-by-pattern hook in user settings | `hooks/guard.js`, loaded per session with `claude --settings`; **nothing in `~/.claude` was changed** |

Plain files remain the source of truth: `data/tasks/<id>/{brief.md, meta.json,
report.md, system.md}`, `data/tasks/{decisions.json, todos.json, events.log}`.
A restarted server rereads them (see Recovery).

## Interview answers (defaults chosen)

- **Harness repo**: this one (bridge). macOS, zsh, Node with no
  dependencies, the same as the rest of the project.
- **Repos**: any git checkout; default `TARGET_REPO` (default branch from `origin/HEAD`, else main). Worktrees go to
  `WORKTREE_ROOT` for the target repo, else `<repo>-worktrees/`.
- **Branch naming**: `<BRANCH_PREFIX>/<slug>-<4 chars>`, prefix defaulting to
  `GITHUB_LOGIN`. Slack pipeline runs keep the Linear `gitBranchName`.
- **Worktree setup**: left to the worker, following the repo's CLAUDE.md (the
  pipeline skill can document a repo's). Not scripted, because it differs
  per repo.
- **Agent / model**: Claude Code; the model comes from the chat's settings
  (Settings > Job defaults). The orchestrator is a normal chat, so its model is
  picked in its composer.
- **Permission mode for workers**: full access (`--dangerously-skip-permissions`),
  the existing default, **plus the guard hook**. The hook is what makes full
  access acceptable: rails are denied outright, and destructive git and
  outward writes come back to you as exact-payload approvals.
- **How you're told**: the Orchestrator's relay, the Inbox, browser
  notifications (opt-in, Settings), and the tab title. No phone push: the
  existing design dropped OS-level notifications deliberately.
- **Shared local resources (ports, DBs)**: no lock yet, and no worker cap:
  every task starts right away in its own worktree. Add a lock if dev
  servers start fighting.
- **Secrets**: workers use whatever the repo's setup copies (by name, never
  printed). The guard refuses env dumps, `printenv`, `.env` reads, argv
  listings, and a bare `gh auth token`.
- **Cost budget for tests**: stub agent for the suite (free). The one real
  run (haiku worker and orchestrator) cost $0.07.
- **"Done" for a worker**: the report contract with `status`, and
  verification stated as verified/assumed. Workers may commit and push their
  own branch and open PRs, which is the existing pipeline workflow.
- **Outward writes** (Settings > Harness > Write policy; `ask` = exact-payload
  card): Slack/chat, Linear and GitHub issues, Notion and Google docs, PR
  merge/close, any other connector write or outbound POST, and destructive
  git default to **ask**. PR comments and review replies default to
  **allow**, because `/resolve` posts them as part of the PR workflow.
  Opening and editing your own PR is allowed.
- **Who merges**: you (`prMerge: ask`).
- **Caps**: none. Every spawn starts right away, however many workers are
  already running.
- **Stall**: 15 minutes of silence; 4x that for a declared wait.
- **Quiet / away**: quiet relays only what needs you; away holds every relay
  and sends one catch-up turn when you switch back.

## Outcomes

`report` · `idle-without-report` (one automatic nudge first) ·
`worker-stalled` · `worker-gone` (crashed, or the server restarted mid-turn) ·
`usage-limit`. Each one goes to `events.log`, the task's chat, the Inbox
(questions and action requests become decisions, a ready report becomes a
review to-do), a browser notification if it needs you, and a relay turn
(depending on mode).

## Recovery

At boot: pending asks are swept (as before); a task still marked `working`
becomes `worker-gone` with a **Resume** decision; any report written while
the server was down is caught up. Workers are
children of the server and die with it, so **resume is a relaunch** (`--resume
<session>` with a note to check git state), not a reattach.

## Quirks found while building

- **Long argv kills node on this machine.** Any `node script.js <arg>` with an
  argument over about 1000 characters is SIGKILLed instantly, inside the tool
  sandbox and outside it (probably endpoint security). `node -e` and native
  binaries are fine, and `claude` is a native binary. The appended system
  prompt therefore goes by file (`--append-system-prompt-file`, which also
  leaves `data/tasks/<id>/system.md` to inspect), and `.js` agent binaries are
  run as `node <file>` instead of through `#!/usr/bin/env node`, which
  resolves to a mise shim.
- **A hook's `ask` reaches the dashboard even under full access.** Verified
  with a real session: a `PreToolUse` hook returning
  `permissionDecision: "ask"` produces a `can_use_tool` control request on
  stdio despite `--dangerously-skip-permissions`, and `deny` blocks the call
  with the reason shown to the model. The write policy rests on this.
- Workers write `pr: none (...)`, and bullets like "None. (aside)". The parser
  treats only URLs as PRs and treats a leading "None" as none.

## Not built (optional phases, say if you want them)

- PR merge/deploy tracking as watcher outcomes (`pr-merged`,
  `deploy-failed`): phase 6 optional; deploy signals would need
  defining per repo.
- An independent verifier subagent per worker.
- Phone notifications, a chat watcher, multi-account usage routing.
- `bin/stow` (memory checklist before a reset). The existing memory panel and
  run proposals cover most of it; workers get the repo's memory inlined into
  their system prompt, since a worktree's cwd has no memory of its own.

## Tests

`npm test` runs the policy unit tests, report parsing, and the end-to-end
suite: a real dashboard process on a random port, a scratch repo with a bare
origin, and `test/stub.js` forcing every outcome. Nothing touches
`data/`, your repos, or usage.

## Workspace views and the native app (2026-11-25)

- **Board columns** are derived on the page from the run, its task status and the
  PR's live state; only a manual placement is stored (`run.board`), written
  without bumping `updatedAt`, so a drag never marks a chat unread. Manual wins
  until unpinned. A run whose PR isn't among your open PRs (once loaded) counts as Done.
- **Feeds** (`server/sources.js`): one `gh api graphql` call for your open, review-requested
  and recently merged PRs; Linear's GraphQL API with `LINEAR_API_KEY`. Each is cached
  for 60s and fetched once at a time. They're GETs but private, so they take the
  same loopback-origin check as writes.
- **PR actions go through the orchestrator** rather than spawning directly, because
  they work on an existing branch, which a fresh worktree can't check out if it's
  checked out elsewhere. Linear's **Start session** spawns directly on Linear's branch name,
  and falls back to a generated name if that branch exists.
- **Ideas from Orca and Paseo**: dev-server ports tied to worktrees (Orca's `orca ports`),
  `.worktreeinclude` (Paseo), full-text transcript search, a status line on each card, and
  attention badges. Not built yet: Claude plan-usage meters (would need the Claude Code
  OAuth token from the keychain), remote and phone access, and typed agent-to-agent mail.
- **Bridge.app** never owns the server. It starts it through `install.sh start`
  (launchd) if it's down, so quitting the window never kills a worker.
  WKWebView has no web Notification API, so a user script injected at document
  start stands in for it and posts to `UNUserNotificationCenter`. The Dock badge
  comes from the page title `(n) Needs you`.
