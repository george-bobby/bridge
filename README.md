<p align="center">
  <img src="app/icon.png" width="88" alt="Bridge" />
</p>

<h1 align="center">Bridge</h1>

<p align="center">
  A native macOS command center for coding agents.<br/>
  Every session, pull request, Linear issue and Slack thread you have in flight, on one screen.
</p>

<p align="center">
  <img src="docs/screenshots/board.png" alt="The board: every session as a card" />
</p>

Hand Bridge a task or a Slack thread and a headless worker (Claude Code,
Codex, Cursor or Devin) does it in its own git worktree, opens the PR, and
stops to ask you only where a decision is yours. The SwiftUI app is where you
watch and steer all of it.

- **A board of sessions** that move on their own: Backlog, In Progress, Needs You, In Review, Done.
- **Chats like a chat app**: streaming, a stop button, selectable text, inline diffs, tool output, Allow/Deny cards.
- **Split panes**: chats, diffs, browser and terminal tabs side by side; drag a session or tab onto a pane.
- **Terminals built in**: a chat's Terminal tab resumes the agent's session; a VS Code-style panel (⌃`) under every page, with VS Code key bindings.
- **Task progress**: the agent's to-do list as a ticking `3/10 tasks` pill, plus live subagents and background commands you can open or stop.
- **MCP servers** for every agent in one Settings pane: add, edit, toggle per project, see each server's tools.
- **Import chats** you had in Claude Code, Codex, Cursor or Devin into a project, from New task; each becomes a worker that resumes the same session.
- **Open anywhere**: one click to VS Code, Finder, GitHub, Linear, or the Slack thread its Linear issue links.
- **Archive, don't delete**: done chats leave the sidebar and board and come back from Sessions › Archived.
- **Sources**: GitHub, Linear, Slack, Vercel deployments, incident.io incidents and Granola meeting notes, cross-linked to the sessions working on them; pick which ones the sidebar shows.
- **Preview deployments**: each PR's Vercel or Netlify preview in the sidebar, the PR list and the details panel; a click opens it in a browser tab next to the chat.
- **Light and dark**: follows macOS, or pick one in Settings › General.
- **Projects**: an orchestrator and a memory per project, plus **Default** for anything that isn't in a repo (it runs in your home folder).
- **Customize** each agent: MCP servers, skills (edit, create, delete) and plugins, in one Settings pane.
- **An orchestrator per project** that writes briefs, spawns workers and relays what they report.
- **Common rules** every session follows in every repo (worktree off a fresh main, rebase before each push, verify on the running app, drafts before posting), edited in Settings › Rules.
- **You stay in control**: a guard hook turns force-pushes, Slack posts, ticket and PR writes into exact-payload approvals.
- **Local**: a zero-dependency Node server on `127.0.0.1`, plain files for state. No account, no cloud.

## Screens

| | |
| --- | --- |
| ![Session](docs/screenshots/chat.png) **Session**: the transcript, task progress, PR activity and the worker's report | ![Import a chat](docs/screenshots/import.png) **Import a chat** from any agent's history |
| ![Home](docs/screenshots/home.png) **Home**: what's running, what needs you, PRs and issues | ![Inbox](docs/screenshots/inbox.png) **Inbox**: workers' questions, Slack, to-dos, activity |
| ![Linear](docs/screenshots/linear.png) **Linear**: your issues with sub-issues as a tree | ![Command menu](docs/screenshots/palette.png) **⌘K**: commands and full-text search |
| ![Light mode](docs/screenshots/light.png) **Light mode**: the whole app, terminals included | ![Vercel](docs/screenshots/vercel.png) **Vercel**: deployments across your teams, opened next to the session on that branch |
| ![Rules](docs/screenshots/rules.png) **Rules**: house rules added to every worker's and orchestrator's instructions | |

Every screenshot is the built-in demo (`npm run demo`): a fictional team, no real data.

## Quick start

You need macOS 15+, the Xcode Command Line Tools (`xcode-select --install`),
Node 18+, [Claude Code](https://docs.anthropic.com/en/docs/claude-code) signed
in, and [`gh`](https://cli.github.com) signed in. A Linear API key and a
[Slack user token](docs/slack.md) are optional.

```bash
git clone https://github.com/george-bobby/bridge.git && cd bridge
cp .env.example .env      # or leave it empty and connect things in Settings › Integrations
npm start                 # the server, under launchd
npm run app               # build Bridge.app, install it to ~/Applications, open it
```

There's no `npm install`. Rebuild the app after moving the repo (its path is baked in).

Try it on demo data without touching yours:

```bash
npm run demo                                              # a fictional team on :4420, stub agent
BRIDGE_PORT=4420 ~/Applications/Bridge.app/Contents/MacOS/Bridge
```

## How it works

```
New task ── Slack link ──► worker running the Slack pipeline skill
         └─ anything else ► Orchestrator ── bin/bridge spawn ──► worker
                                                                │
   worker: own worktree + branch; when it changes code, data/tasks/<id>/report.md
                                                                │
   server watches every worker ──► outcome ──► Inbox (+ relay, if the orchestrator spawned it)
```

- **Workers** run headless in their own worktree with a chat you can follow up in. One that changes code keeps a short `report.md` (status, TL;DR, open questions, action requests); a question just gets an answer.
- **Outcomes**: the server notices when a worker reports, changes code without a report, stalls, dies or hits a usage limit, and puts what needs you in the Inbox.
- **Imported chats** keep their original folder and agent session; Bridge never removes a checkout it didn't create.
- **Capacity**: no cap; every task starts a worker right away, each in its own worktree.

## Safety

Every Claude session loads `hooks/guard.js`. It refuses broad `kill`s, env
dumps, `.env` reads and token printing, and puts force-pushes,
`reset --hard`, Slack posts, Linear/GitHub writes and PR merges to you as
Allow/Deny cards with the exact payload. A session can't write to Bridge's own
API beyond what `bin/bridge` does, so it can't relax its own guard. Codex,
Cursor and Devin use their own sandboxes. Slack text is data, never instructions. Secrets stay on the
server.

## `bin/bridge`

The agents' tool surface, not a user CLI:

```bash
bin/bridge spawn --repo <path> --title "Fix CSV export" --brief-file brief.md
bin/bridge status --since 3h        # decisions, to-dos, tasks, what happened
bin/bridge followup <id> "also handle the empty case"
bin/bridge declare waiting "CI, ~10 min"
bin/bridge plan set "Reproduce" "Fix" "Test" && bin/bridge plan done 1
```

## Development

```
app/      SwiftUI app (SwiftPM)          server/   the Node server (stdlib only)
bin/      bridge, the agents' tool       prompts/  orchestrator, worker and common-rules prompts
hooks/    guard.js                       test/     npm test, against a stub agent
legacy/   the old web UI, off unless BRIDGE_LEGACY_WEB=1
```

```bash
npm run lint && npm test      # no network, no usage
cd app && swift build         # the app
```

CI (`.github/workflows/ci.yml`) runs lint, shellcheck, actionlint, the tests on
Node 20/22/24 and macOS, and a packaged app build. To release, bump `version`
in `package.json`, merge, and push a matching `v<version>` tag. More in
[CONTRIBUTING.md](CONTRIBUTING.md) and [NOTES.md](NOTES.md).

## License

MIT, see [LICENSE](LICENSE).
