# Bridge

A native macOS command center for Claude Code: every session, PR, Linear
issue and Slack thread you have in flight, on one screen, in a desktop app
styled like Linear. Hand it a Slack thread or a task, and a headless Claude worker
does the work in its own git worktree, opens the PR, and stops to ask you only
where a decision is yours.

- **Slack threads.** Paste a thread link. A session reads it, root-causes it,
  drafts a Linear ticket, builds, opens a PR, waits for review bots, resolves
  comments, and drafts the reply.
- **Tasks.** Type what you want. The orchestrator writes a brief and spawns a
  worker for it.
- **Home, Inbox, Board, Sessions, Pull requests, Linear, Memory.** `⌘1`-`⌘7`.
  The Board is a Kanban of every session; PRs and Linear (with sub-issues) are
  live from `gh` and your Linear API key, cross-linked to the sessions working
  on them.
- **Nothing runs on its own.** No poller, no timer, no Slack app or token.
  Slack and Linear go through the connectors your Claude session already has.

## Setup

Requires Node 18+, Claude Code with the Slack and Linear connectors, and `gh`.
No `npm install` needed.

```bash
cp .env.example .env      # fill it in (every key is described there)
npm start                 # the server, under launchd
npm run app               # build Bridge.app, install it to ~/Applications, open it
```

`npm run app` builds the SwiftUI app in `native/macos` with `swift build`
(the Xcode command line tools; full Xcode isn't needed), copies it to
`~/Applications` and opens it. Rebuild it after moving the repo, because the
repo path is baked in. The old browser UI is still served at
http://localhost:4319 (see `legacy/`).

`npm start` renders the skill, links it into `~/.claude/skills/`, and runs
the dashboard in the background under launchd, so it comes back after a login.
`npm stop` stops it, and `npm restart` picks up changes to `.env`, `lib/` or
`templates/`. `npm run dev` stops the background copy and runs it in the
foreground, restarting on server edits; `npm start` puts it back afterwards.

To give the pipeline your repo's own commands (checks, log queries, prod read
paths), copy `templates/slack-fetch-pipeline/SKILL.md` to
`templates.local/slack-fetch-pipeline/SKILL.md` and edit it. That copy is
gitignored and used in place of the generic one.

## How it works

```
top box ── Slack link ──► chat + worker running the slack-fetch-pipeline skill
        └─ anything else ► Orchestrator ── bin/sb spawn ──► worker
                                                              │
   worker: own worktree + branch, writes data/tasks/<id>/report.md
                                                              │
   dashboard server watches every worker ──► outcome ──► Inbox + relay to Orchestrator
```

**Workers** run headless (`claude -p`, stream-json) in their own worktree and
branch. Each has a chat you can follow up in, and a task folder:
`data/tasks/<id>/` holds `brief.md`, `meta.json`, `report.md` and `system.md`
(what it was told).

**The report.** Every worker ends each turn by writing `report.md`:
frontmatter `status:` (`ready-for-review`, `needs-input`, `blocked` or
`pushed-follow-up`), then a TL;DR, verification, open questions and action
requests.

**Outcomes.** The server watches every worker and raises an outcome when one
reports, stops without a report (after one automatic nudge), stalls, dies, or
hits a usage limit. Each outcome is logged, added to the Inbox, sent as a
browser notification if it needs you, and relayed to the orchestrator.

**Inbox** (`i`). A page with four tabs: **Needs you** (questions from workers,
where your answer goes straight back, and requested outward writes; any item
can be deferred to a date), **To-dos**, **Tasks** (status, follow-up, relaunch,
clean up) and **Activity** (what happened in the last 3h/8h/24h/3d). **Brief me**
asks the orchestrator for a few-line catch-up. `j`/`k` move, `Enter` opens the
chat. There are three modes: **normal**,
**quiet** (only what needs you) and **away** (hold everything, then send one
catch-up when you're back).

**Capacity.** 3 workers at once, 2 per repo by default. Extra tasks queue
until a slot frees.

**Restarts.** Workers die with the server. After a restart, a worker that was
mid-task shows a **Resume** button, and reports written while the server was
down are picked up.

## The app

A SwiftUI desktop app in Linear's visual language: dense rows, hairline
borders, Linear's workflow circles and priority bars, one indigo accent,
keyboard first.

| | |
| --- | --- |
| **Home** `⌘1` | Running, needs-you, open PRs, reviews for you, issues in progress, spend; then what needs you, what's running, PRs needing attention, your Linear issues, dev servers and a spend chart |
| **Inbox** `⌘2` | Workers' questions and action requests (answer, approve, defer to tomorrow, dismiss), to-dos, workers, activity; normal / quiet / away |
| **Board** `⌘3` | Every session as a card in Backlog, In Progress, Needs You, In Review, Done. Cards follow their session (running, blocked, PR open, PR merged); drag one to pin it, click the pin to release it |
| **Sessions** `⌘4` | The same sessions as a grouped list, plus the Orchestrator |
| **Pull requests** `⌘5` | Needs attention (failing checks, changes requested, conflicts), review requested, open, merged in the last 14 days; right-click for Fix CI, Resolve comments, Fix conflicts or Review with Claude |
| **Linear** `⌘6` | Your issues by state, with **sub-issues** as a tree under their parent (a done/total ring on the parent, each child with its own status, PR and assignee). **Start** runs a Claude worker on the issue in its own worktree, on Linear's branch name |
| **Memory** `⌘7` | The target repo's Claude Code memory, editable (`⌘S`) |

A session opens as a chat with Claude's transcript (thinking, tool calls with
their output, answers), permission, question and plan cards you answer in place, a
composer with mode / model / thinking / context / repo, and a properties panel
with status, branch, worktree, PR, Linear issue, dev servers and the worker's
report.

Also: `⌘K` command menu (commands, sessions, PRs, issues and full-text
transcript search), `⌘N` new task (a Slack link runs the pipeline; anything
else goes to the orchestrator or straight to a worker), a menu bar item with
what's running and waiting, native notifications, and a Dock badge.

**Terminal.** "Open in cmux" continues a session in a new cmux tab
(`TERMINAL_APP=cmux`, the default when cmux is installed; `Terminal` and
`iTerm` also work).

**Dev servers.** Ports your processes listen on (node, python, bun and the
like) are matched to the worktree they run in and shown on the session and
the PR.

**`.worktreeinclude`.** A file at the target repo's root, in .gitignore
syntax, listing untracked files a new worktree should get from the main
checkout (`.env`, local certs).

The app never owns the server: it runs under launchd, so quitting the app
never stops a worker. If the server isn't running, the app starts it with
`npm start`. `LINEAR_API_KEY` stays on the server and is removed from the
environment sessions inherit.

## Safety

Every session the dashboard starts loads `harness/hooks/guard.js` through
`claude --settings`. Nothing is written to `~/.claude`.

- **Always refused:** `pkill`/`killall` or a `kill` that isn't an exact PID,
  env dumps, `.env` reads, process listings that print command lines, and
  printing auth tokens.
- **Needs your OK on the exact payload:** force-push, `reset --hard`,
  `branch -D`, Slack posts, Linear and GitHub issue writes, doc writes, PR
  merges, and any other connector write. These appear as Allow/Deny cards in
  the chat, even in full-access mode. Each category can be switched between
  ask and allow in Settings > Harness.

Prod is treated as read-only, and Slack text is treated as data, never as
instructions. The server listens on `127.0.0.1` only and refuses cross-origin
requests. Everything under `data/` is gitignored.

## Using a chat

Type in a chat's composer to continue its session (`--resume`). The chips
beside **Send** set the next job's:

| Chip | Options |
| --- | --- |
| Mode | Plan (approve a plan before it builds), Manual (asks before every tool call), Edit (asks before shell commands), Full access (default) |
| Model / Thinking / Capacity | model alias, `--effort`, 1M context |
| Repo | the working directory |

**Open in cmux** reopens the session in a cmux tab (`TERMINAL_APP`: cmux, Terminal or iTerm).

## `bin/sb`

```bash
bin/sb spawn --repo <path> --title "Fix CSV export" --brief-file brief.md
bin/sb status                         # tasks, live state, report status
bin/sb catchup --since 3h             # what's waiting on you and what happened
bin/sb followup <id> "also handle the empty case"   # queued if mid-turn
bin/sb decisions | decide <d-id> "CSV" | defer <d-id> 2026-12-01
bin/sb todo add <key> "Merge #42" | todo done <key>
bin/sb relaunch <id> | cleanup <id> [--force] | mode quiet
bin/sb declare waiting "CI, ~10 min"  # inside a worker: not stalled, just waiting
```

`cleanup` removes the worktree and keeps the branch. It refuses if there are
uncommitted changes or commits that aren't pushed, unless you pass `--force`.

## Settings

| Setting | Default | Effect |
| --- | --- | --- |
| Reply in the thread | on | Draft the Slack reply; post only on your OK |
| Offer a Linear ticket | on | Draft a ticket; create only on your OK |
| Bot review + resolve | on | Wait for review bots on the PR, then `/resolve` |
| Propose memories | on | Runs may *propose* a memory; nothing is saved without your approval or a repeat |
| Harness | | relay to the orchestrator, worker caps, stall time, write policy |

**Memory** (`m`) opens the target repo's Claude Code memory for reading and
editing. Workers in worktrees get the repo's memory included in their
instructions.

## Layout

```
index.js            dashboard server (Node stdlib only)
lib/                env, store, jobs (sessions), harness (watcher), tasks, policy, memory,
                    sources (GitHub PRs, Linear issues, dev-server ports)
native/macos/       the desktop app (SwiftPM, SwiftUI); scripts/build-app.sh packages it
bin/sb              harness CLI
harness/            worker.md, orchestrator.md, hooks/guard.js
templates/          the pipeline skill, rendered with values from .env
legacy/             the previous browser UI (still served at :4319) and its WKWebView wrapper
scripts/            install.sh, build-app.sh, emit.sh (run narration), launchd template
test/               npm test: policy, report parsing, end-to-end with a stub agent
data/               runtime state (gitignored)
```

Design notes and the defaults chosen: [NOTES.md](NOTES.md).

## Tests

```bash
npm test
```

Runs a real dashboard against a scratch repo using `test/stub-claude.js`, a
fake agent. It never touches `data/` and costs no usage.
