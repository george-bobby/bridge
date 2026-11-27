# Contributing to Bridge

Thanks for helping. Bridge is two pieces: a zero-dependency Node server that runs Claude Code sessions, and a SwiftUI desktop app that talks to it over HTTP and server-sent events.

## Layout

```
app/        the desktop app (SwiftPM, SwiftUI); scripts/build.sh packages it
bin/        bridge, the agents' tool for the harness (spawn, status, declare, ...)
data/       runtime state (gitignored; config.example.json is the template)
docs/       Slack setup, its app manifest, screenshots
hooks/      guard.js, the safety hook every session loads
legacy/     the previous browser UI, served only with BRIDGE_LEGACY_WEB=1
prompts/    orchestrator.md, worker.md and rules.md (Common rules), the harness's instructions
scripts/    install.sh, build.sh, demo.js, lint.js, emit.sh (run narration), launchd.plist, icon.swift
server/     the Node server (stdlib only): index.js routes; jobs (sessions), harness, tasks,
            watch (Slack), slack, sources (GitHub, Linear, ports), store, policy, memory, ...
skills/     the Slack pipeline skill, rendered with values from .env (skills.local/ overrides it)
test/       npm test: policy, report parsing, end to end against stub.js
```

## Running it

```bash
npm run demo                                  # a server with a fictional team on :4420
cd app && swift build                         # debug build of the app
BRIDGE_PORT=4420 .build/debug/Bridge          # the app against the demo server
```

The demo never calls GitHub, Linear or Claude: feeds come from `server/demo.js` and sessions run `test/stub.js`.

To check UI changes without screen-recording permission, `BRIDGE_SNAPSHOT_DIR=/tmp/shots` makes the app write a PNG of every page (`BRIDGE_SNAPSHOT_CHAT=<run id>` picks the chat). The screenshots in `docs/screenshots` come from that, against the demo.

## Before a pull request

- `npm run lint` passes (syntax, JSON, no npm dependencies)
- `npm test` passes (it uses a scratch data dir and the stub agent, so it is free and touches nothing of yours)
- `cd app && swift build -c release` builds cleanly
- UI changes: include a before/after from the snapshot hook, taken against the demo

CI (`.github/workflows/ci.yml`) runs the same checks on every pull request, plus shellcheck, actionlint and the tests on several Node versions.

## Conventions

- **The server stays dependency-free.** Node's standard library only; no `npm install`.
- **The app builds with the Command Line Tools alone.** That rules out SwiftUI's `@State` (its macro plugin ships only with Xcode): keep view state in `@StateObject private var x = Box(value)`. Use `Text(verbatim:)` for interpolated numbers.
- **Follow the design system.** Colors, type, icons, rows and buttons come from `Theme.swift`; don't add one-off colors or sizes.
- **Safety rails are not optional.** Anything that writes outside the repo (Slack, Linear, GitHub issues, merges, destructive git) goes through the guard in `hooks/guard.js` and asks with the exact payload. Never log or return secrets; `LINEAR_API_KEY` stays in the server.
- **No personal data in the repo.** Paths, workspace ids and names belong in `.env` (documented in `.env.example`), never in code or templates.

## Reporting a bug

Open an issue with what you did, what you expected, what happened, and the relevant lines of `logs/dashboard.err.log`. Check that the logs contain no tokens before you paste them.
