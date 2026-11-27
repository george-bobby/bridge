# Legacy web client

The original browser UI, kept as it was when the desktop app replaced it. Nothing here runs by default.

- `web/`: the old dashboard page. The server serves it only when started with `BRIDGE_LEGACY_WEB=1` (for example `BRIDGE_LEGACY_WEB=1 node server`), at http://localhost:4319; otherwise every non-API path answers 404
- `webview-app/`: the first desktop wrapper (a WKWebView around `web/`); `./legacy/webview-app/build.sh` builds `Bridge Web.app`, which needs the server started as above
- `vendor-milkdown.js`: re-vendors the memory editor into `web/vendor/`

The main client is the native app in `app/`.
