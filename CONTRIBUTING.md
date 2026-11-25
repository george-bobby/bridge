# Contributing to Bridge

Thanks for helping. Bridge is two pieces: a zero-dependency Node server that runs Claude Code sessions, and a SwiftUI desktop app that talks to it over HTTP and server-sent events.

## Layout

```
index.js, lib/       the server: sessions (jobs.js), the harness (harness.js, tasks.js),
                     GitHub/Linear/dev-server feeds (sources.js), demo data (demo.js)
harness/             worker and orchestrator prompts, and the guard hook every session loads
native/macos/        the desktop app (SwiftPM). Theme.swift holds the design system
templates/           the Slack pipeline skill, rendered with values from .env
legacy/              the previous browser UI, kept as it was
test/                node:test suites and a stub agent
```

## Running it

```bash
npm run demo                                  # a server with a fictional team on :4420
cd native/macos && swift build                # debug build of the app
BRIDGE_PORT=4420 .build/debug/Bridge          # the app against the demo server
```

The demo never calls GitHub, Linear or Claude: feeds come from `lib/demo.js` and sessions run `test/stub-claude.js`.

To check UI changes without screen-recording permission, `BRIDGE_SNAPSHOT_DIR=/tmp/shots` makes the app write a PNG of every page (`BRIDGE_SNAPSHOT_CHAT=<run id>` picks the chat). The screenshots in `docs/screenshots` come from that, against the demo.

## Before a pull request

- `npm run lint` passes (syntax, JSON, no npm dependencies)
- `npm test` passes (it uses a scratch data dir and the stub agent, so it is free and touches nothing of yours)
- `cd native/macos && swift build -c release` builds cleanly
- UI changes: include a before/after from the snapshot hook, taken against the demo

CI (`.github/workflows/ci.yml`) runs the same checks on every pull request, plus shellcheck, actionlint and the tests on several Node versions.

## Conventions

- **The server stays dependency-free.** Node's standard library only; no `npm install`.
- **The app builds with the Command Line Tools alone.** That rules out SwiftUI's `@State` (its macro plugin ships only with Xcode): keep view state in `@StateObject private var x = Box(value)`. Use `Text(verbatim:)` for interpolated numbers.
- **Follow the design system.** Colors, type, icons, rows and buttons come from `Theme.swift`; don't add one-off colors or sizes.
- **Safety rails are not optional.** Anything that writes outside the repo (Slack, Linear, GitHub issues, merges, destructive git) goes through the guard in `harness/hooks/guard.js` and asks with the exact payload. Never log or return secrets; `LINEAR_API_KEY` stays in the server.
- **No personal data in the repo.** Paths, workspace ids and names belong in `.env` (documented in `.env.example`), never in code or templates.

## Reporting a bug

Open an issue with what you did, what you expected, what happened, and the relevant lines of `logs/dashboard.err.log`. Check that the logs contain no tokens before you paste them.
