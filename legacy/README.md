# Legacy web client

The original browser UI, kept as it was when the desktop app replaced it.

- `web/`: the dashboard page the server still serves at http://localhost:4319
- `webview-app/`: the first desktop wrapper (a WKWebView around `web/`); `./legacy/webview-app/build.sh` builds `Bridge Web.app`
- `vendor-milkdown.js`: re-vendors the memory editor into `web/vendor/`

The main client is the native app in `native/macos`.
