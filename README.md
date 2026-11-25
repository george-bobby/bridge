# Bridge

A local command center for Claude Code: a native macOS app (or a browser tab)
where every session, PR, Linear issue and Slack thread you have in flight sits
on one screen. Hand it a Slack thread or a task, and a headless Claude worker
does the work in its own git worktree, opens the PR, and stops to ask you only
where a decision is yours.

- **Slack threads.** Paste a thread link. A session reads it, root-causes it,
  drafts a Linear ticket, builds, opens a PR, waits for review bots, resolves
  comments, and drafts the reply.
- **Tasks.** Type what you want. The orchestrator writes a brief and spawns a
  worker for it.
- **Overview, Board, Chats, Pull requests, Linear.** Five views in the top bar
  (`1`-`5` or `⌘1`-`⌘5`). The Board is a Kanban of every session; PRs and Linear
  are live from `gh` and your Linear API key, cross-linked to the sessions
  working on them.
- **Nothing runs on its own.** No poller, no timer, no Slack app or token.
  Slack and Linear go through the connectors your Claude session already has.

## Setup

Requires Node 18+, Claude Code with the Slack and Linear connectors, and `gh`.
No `npm install` needed.

```bash
cp .env.example .env      # fill it in (every key is described there)
npm start
open http://localhost:4319
```

For the native app, run `npm run app` once. It builds `Bridge.app` with
`swiftc` (Xcode command line tools, nothing else), copies it to
`~/Applications` and opens it. Rebuild it after moving the repo, because the
path is baked in.

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

## Workspace views

**Overview** (`1`). Tiles for running sessions, what needs you, open PRs and how
many need attention, reviews asked of you, Linear in progress, and today's
spend. Below them: what needs you, what's running, dev servers, Slack threads,
your PRs ranked by attention, and your Linear issues.

**Board** (`2`). Every session as a card in **Backlog**, **In progress**,
**Needs you**, **In review** and **Done**. A card follows its session: running
means In progress, a question or a stalled worker means Needs you, an open PR
means In review, and a merged or closed PR means Done. Drag a card to pin it to
a column; the card shows **pinned**, and clicking that, or dropping the card back
where it would land on its own, lets it follow the session again. Moving a
card isn't activity, so it never marks a chat unread. The box at the top of
Backlog starts a new task directly (`⌘↵`).

**Pull requests** (`4`). Your open PRs (failing checks, changes requested and
conflicts first), reviews requested of you, and what merged in the last 14
days, with check and review state, diff size, linked Linear key and any dev
server running in the PR's worktree. **Fix CI**, **Resolve comments**, **Fix
conflicts** and **Review** ask the orchestrator to spawn a worker for it.

**Linear** (`5`). Issues assigned to you, grouped by state, with their PRs.
**Start session** spawns a worker on the issue in a worktree on Linear's branch
name, with the issue text as its brief. Needs `LINEAR_API_KEY` in `.env`. The
key stays in the server and is removed from the environment sessions inherit.

**Dev servers.** Ports your processes listen on (node, python, bun and the
like) are matched to the worktree they run in, and appear as `:3000` chips on
the session's card and the PR's row.

**Search** (`⌘K`). Commands, views, chats, and full-text search across every
transcript.

**`.worktreeinclude`.** A file at the target repo's root, in .gitignore
syntax, listing untracked files a new worktree should get from the main
checkout (`.env`, local certs). Each worker's worktree gets copies.

## The native app

`Bridge.app` is a WKWebView around the dashboard, plus:

- a hidden title bar, so the top bar is the window chrome and drags it
- a Dock badge counting sessions waiting on you
- native notifications for asks and outcomes (click to jump to the chat)
- a menu bar: `⌘1`-`⌘5` views, `⌘N` new task, `⌘L` paste a Slack thread,
  `⌘K` search, `⌘O` orchestrator, `⌘⇧I` inbox, `⌘,` settings, `⌘R` reload
- external links open in your browser

The server stays under launchd, so closing or quitting the app never stops a
worker. If the dashboard isn't running, the app starts it with `npm start`.

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

**Terminal** reopens the session in Terminal or iTerm (set by `TERMINAL_APP`).

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
native/macos/       Bridge.swift, the native app (scripts/build-app.sh builds it)
bin/sb              harness CLI
harness/            worker.md, orchestrator.md, hooks/guard.js
templates/          the pipeline skill, rendered with values from .env
public/             dashboard UI: app.js (chats), harness.js (inbox, tasks), workspace.js
                    (overview, board, PRs, Linear); vendored Milkdown editor in vendor/
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
