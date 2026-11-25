# Bridge

Zero-dependency Node dashboard (no `npm install`) plus a Swift WKWebView shell.

- `npm test`: policy, report parsing, end-to-end harness and workspace tests (stub agent, scratch data dir; never touches `data/`)
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
- The old web UI is kept, untouched, in `legacy/`
- "Open in cmux" goes through cmux's AppleScript dictionary: its CLI socket only accepts processes started inside cmux

## Server pieces added with the native app

- `lib/projects.js`: projects (data/projects.json), session-to-project inference, per-project orchestrator ids (`orchestrator` for the default, `orchestrator-<id>` otherwise)
- `lib/envfile.js`: `.env` read/write for Settings, schema from `.env.example`; secrets are write-only
- `lib/slack.js`: native Slack connector on a user token (`SLACK_USER_TOKEN`); `lib/demo.js` has a fixture Slack for `npm run demo`
- `POST /api/restart` exits the server; launchd (KeepAlive) restarts it after re-rendering the skill
- `lib/agents.js`: Codex/Cursor/Devin adapters into Claude's stream-json, handoff briefings, the model catalog (`codex debug models`, `cursor-agent --list-models`, `devin models list --format json`); spawn agents with `ACP_BACKEND` removed or Devin says "Not logged in"
- `lib/usage.js`: plan usage (Claude oauth/usage, Codex wham/usage + session-log fallback, Cursor dashboard API); never stores or refreshes tokens
- `lib/changes.js`: per-session git status/diff/commit/push/`gh pr create`
