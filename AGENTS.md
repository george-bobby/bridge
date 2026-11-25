# Bridge

Zero-dependency Node dashboard (no `npm install`) plus a Swift WKWebView shell.

- `npm run lint`: `node --check` on every server script, JSON parse, and fails on any non-builtin `require` (zero-dependency rule)
- CI (`.github/workflows/ci.yml`): lint + shellcheck + actionlint, `npm test` on Node 20/22/24 Linux and 22 macOS, `scripts/build-app.sh` on macos-15. The runner's Swift type-checker is slower than a local Mac: keep SwiftUI `body`s split into small computed views or it times out there while building fine locally
- Releases: bump `package.json` version, merge, push tag `v<version>`; `release.yml` reruns CI, checks the tag matches and creates the GitHub release
- `npm test`: policy, report parsing, end-to-end harness and workspace tests (stub agent, scratch data dir; never touches `data/`)
- After every change, apply it to the installed app before calling the task done: Swift edits (`native/macos`) → `npm run app`; server edits (`index.js`, `lib/`, `.env`, `templates/`) → `npm restart` (skip if `npm run dev` is running and only `index.js`/`lib/` changed; it reloads those on save)
- `npm run dev`: server in the foreground, restarting on `index.js`/`lib/` saves (stops the launchd server first; `npm start` to go back). No watcher exists for the Swift app
- `npm restart`: pick up server edits (`index.js`, `lib/`, `.env`). `public/` is read from disk per request, so UI edits need only a reload
- `npm run app`: rebuild `dist/Bridge.app` and install it to `~/Applications` (rebuild after moving the repo; its path is baked in)
- Try UI changes against scratch data: `SB_DATA_DIR=/tmp/x PORT=4400 node index.js`
- `LINEAR_API_KEY` lives in `.env` only; `lib/env.js` deletes it from `process.env` so sessions never inherit it
- UI layers wrap app.js globals in load order: `app.js` → `harness.js` → `workspace.js`


## Native app (native/macos)

- SwiftPM + SwiftUI, macOS 15, built with the Command Line Tools: `cd native/macos && swift build -c release`; `npm run app` packages and installs it
- `@State` is unavailable without full Xcode (its macro plugin isn't shipped): keep view state in `@StateObject private var x = Box(value)`
- Use `Text(verbatim:)` for interpolated numbers (plain `Text("\(n)")` adds locale grouping: "#35,749")
- Check the UI without screen-recording permission: `BRIDGE_SNAPSHOT_DIR=/tmp/shots native/macos/.build/release/Bridge` writes a PNG per page
- Demo data: `npm run demo` (fictional team on :4420, fixture feeds from lib/demo.js, stub agent), then run the app with `BRIDGE_PORT=4420`
- README screenshots: `BRIDGE_PORT=4420 BRIDGE_SNAPSHOT_CHAT=1732530001.000100 BRIDGE_SNAPSHOT_DIR=/tmp/shots .build/release/Bridge`, then copy into docs/screenshots (never screenshot real data)
- Styling lives in `Theme.swift` (Linear palette, StatusIcon, PriorityIcon, Chip, HoverRow); follow it rather than adding ad-hoc colors
- Motion lives there too: curves in `M` (hover, snappy, page, pop), `.hoverBox(box)` for eased hover, `Pressable`, `SlidingTabs`, `.rise(i)`, `.shimmer()`, `.floatingPanel()`; native pieces `VisualEffect` (vibrancy) and `SearchField` (NSSearchField). Use these instead of bare `onHover`/ad-hoc animations
- Sidebar order and ⌘1…⌘9 both come from `navOrder` in App.swift; the sidebar's selection pill is a `matchedGeometryEffect` shared through `\.navNS`
- Don't use SwiftUI `.inspector` in the chat: with the hidden title bar it re-adds the title-bar safe area inconsistently (expanded vs collapsed sidebar). The details panel is a plain animated trailing column
- Snapshots include a `collapsed` page (sidebar hidden) to check the traffic-light inset; `BRIDGE_SNAPSHOT_PAGES=chat,browser` limits the run to those pages, `BRIDGE_SNAPSHOT_URL=http://localhost:4420` adds a `browser` page (a browser tab in the chat)
- Keep `.scrollIndicators(.never)` on the chat transcript: with always-visible scroll bars, wrapped text near the fold makes the scroller appear/disappear forever and hangs the main thread in layout
- Sidebar groups: actions (New task, Search), Overview (Home, Inbox, Sessions), Sources (Slack, PRs, Linear), Pinned, Projects; Memory/Usage/Settings live in the footer. Board and list are one "Sessions" page (`model.sessionsRoute` remembers the layout; use `model.navigate(.sessions)`)
- Chat container: prev/next chat follows `model.chatOrder` (sidebar order); tabs are Chat, Changes and browser tabs (`Browser.swift`, live `WKWebView`s kept in `model.web`); drafts and attachments are per chat in the model. Pasted images/files and big pastes become attachment chips, saved under `~/Library/Application Support/Bridge/attachments` and sent as paths in the message text
- Split panes (`Panes.swift`): the chat page is a row of `model.panes` (session + tab each); the focused pane is the route's session and `model.chatTab`, so header, tab strip and details follow focus. No two panes show the same (session, tab); use `model.showTab`/`dropInPane`/`vacate` rather than setting tabs by hand. Drags (sidebar session ids, `bridge-tab:<run>\t<tab>` from tabs and pane headers) arm `DropCatcher` NSViews over each pane (drag sources must be `.onDrag` on a non-Button view: a SwiftUI `Button` swallows the drag and it never starts); ⌥-click / "Open to the Side" go through `model.openToSide`; read a pane's run with `model.runData(id)`, not `openRun`. ⌘\ split, ⌘⇧W close pane, ⌥⌘←/→ focus
- Details panel (`Details.swift`): properties (Status follows a linked Linear issue unless moved by hand; `model.linkedIssue`, `statusDisplay`), links with copy, PR activity from `GET /api/runs/:id/pr` (`changes.activity`: `gh pr view` + inline review comments, cached 45s; demo fixture in `lib/demo.js` `prActivity`), the report folded with callouts. One pane: trailing column; split: `DetailsDrawer` under the focused pane. Cost isn't shown anywhere in the app (plan usage instead); the `drop` snapshot page shows the drag highlight
- Terminal tab (`Terminal.swift`): SwiftTerm `LocalProcessTerminalView`, one per session in `model.terms`, running `GET /api/runs/:id/terminal`'s command in the login shell. SwiftTerm is pinned to 1.11.2: 1.12+ ships a Metal shader that the Command Line Tools can't compile
- Composer pieces live in `Composer.swift`: `AgentModelPicker` (agent + model + thinking in one popover), `AccessPicker`, `ContextButton` (compact), `PromptEditor` (`@` files, `#` sessions, `/` skills; keys go through a local key monitor so the text view keeps focus) and the New task `ComposeSheet`. `BRIDGE_SNAPSHOT_COMPOSER=/tmp/dir` (with a chat open) writes PNGs of the menus, popovers and the sheet
- The old web UI is kept, untouched, in `legacy/`
- The only terminal is the in-app Terminal tab: no external-terminal hand-off

## Server pieces added with the native app

- `lib/projects.js`: projects (data/projects.json), session-to-project inference, per-project orchestrator ids (`orchestrator` for the default, `orchestrator-<id>` otherwise)
- `lib/envfile.js`: `.env` read/write for Settings, schema from `.env.example`; secrets are write-only
- `lib/slack.js`: native Slack connector on a user token (`SLACK_USER_TOKEN`); `lib/demo.js` has a fixture Slack for `npm run demo`
- `POST /api/restart` exits the server; launchd (KeepAlive) restarts it after re-rendering the skill
- `lib/agents.js`: Codex/Cursor/Devin adapters into Claude's stream-json, handoff briefings, the model catalog (`codex debug models`, `cursor-agent --list-models`, `devin models list --format json`); spawn agents with `ACP_BACKEND` removed or Devin says "Not logged in"
- `lib/usage.js`: plan usage (Claude oauth/usage, Codex wham/usage + session-log fallback, Cursor dashboard API); never stores or refreshes tokens
- `lib/changes.js`: per-session git status/diff/commit/push/`gh pr create`
- Claude's models and slash commands come from its stream-json `initialize` handshake (`agents.claudeProbe`, no tokens spent) plus the Anthropic models API with Claude Code's login; `/api/commands` merges that with skill folders on disk
- `jobs.compact`: `/compact` on the resumed Claude session; other agents get a self-handoff (`run.compactBrief`, their session dropped). `/compact` typed in the composer goes there too
- `lib/files.js`: `git ls-files` (or a bounded walk) for the `@` picker: `GET /api/runs/:id/files`, `GET /api/files?project=`; `GET /api/runs/:id/reference` writes a session briefing for `#`
