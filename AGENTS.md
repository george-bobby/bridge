# Bridge

Zero-dependency Node dashboard (no `npm install`) plus a Swift WKWebView shell.

- `npm test`: policy, report parsing, end-to-end harness and workspace tests (stub agent, scratch data dir; never touches `data/`)
- `npm restart`: pick up server edits (`index.js`, `lib/`, `.env`). `public/` is read from disk per request, so UI edits need only a reload
- `npm run app`: rebuild `dist/Bridge.app` and install it to `~/Applications` (rebuild after moving the repo; its path is baked in)
- Try UI changes against scratch data: `SB_DATA_DIR=/tmp/x PORT=4400 node index.js`
- `LINEAR_API_KEY` lives in `.env` only; `lib/env.js` deletes it from `process.env` so sessions never inherit it
- UI layers wrap app.js globals in load order: `app.js` → `harness.js` → `workspace.js`

## Status: native app rewrite (in progress, 2026-11-25)

The user wants a real native desktop app styled like Linear (not the vibe-coded web look), with Linear sub-issues shown as a tree.
The old web UI is kept untouched in `legacy/` (server still serves `legacy/web` at :4319).

Done:
- `native/macos/` SwiftPM app (SwiftUI, macOS 15, no Xcode needed): Core (JSON/API/SSE), Theme (Linear palette, status/priority icons),
  Model (AppModel, board-column logic), App (window, sidebar, commands, menu-bar extra), Lists (Home, Board drag-drop, Sessions, PRs, Linear tree),
  Chat (transcript, tool steps, ask cards, composer, properties), Panels (Inbox, Memory, Settings, ⌘K, New task)
- `lib/sources.js` Linear feed now returns `parent` and `children` (sub-issues with assignee/state)
- `scripts/build-app.sh` builds the SwiftPM app into dist/Bridge.app (`npm run app` installs to ~/Applications)
- `@State` is unavailable with Command Line Tools (macro plugin missing): use `@StateObject private var x = Box(value)`
- Snapshot every page without screen-recording permission: `BRIDGE_SNAPSHOT_DIR=/tmp/shots native/macos/.build/release/Bridge`

Next:
1. `npm restart` the server (new sources.js), re-snapshot, check the Linear sub-issue tree and number formatting (`Text(verbatim:)` fix applied)
2. Verify Board/Sessions/Chat with demo data: `SB_DATA_DIR=/tmp/bridge-demo PORT=4400 node index.js` + `BRIDGE_PORT=4400` for the app
3. `npm run app` to install the native app; run `npm test`; update README (native app, legacy/)
4. Rename the GitHub repo to `bridge` (user approved): `gh repo rename bridge` + update the origin remote
