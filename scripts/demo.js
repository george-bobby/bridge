#!/usr/bin/env node
/**
 * `npm run demo`: a second server with a fictional team in it, so you can try
 * Bridge without GitHub, Linear or a repo. Its data lives in a temp folder and
 * is rebuilt on every start; any session you continue runs the stub agent from
 * test/, which costs nothing.
 *
 *   npm run demo                       server on :4420
 *   BRIDGE_PORT=4420 open -a Bridge    or run the app binary with BRIDGE_PORT=4420
 */

const os = require("os");
const path = require("path");

const dataDir = process.env.SB_DATA_DIR || path.join(os.tmpdir(), "bridge-demo");
Object.assign(process.env, {
  BRIDGE_DEMO: "1",
  SB_DATA_DIR: dataDir,
  BRIDGE_PORT: process.env.BRIDGE_PORT || "4420",
  BRIDGE_ENV_FILE: path.join(dataDir, "none.env"),
  CLAUDE_BIN: path.join(__dirname, "..", "test", "stub-claude.js"),
  TARGET_REPO: "/Users/you/Development/storefront",
  GITHUB_LOGIN: "alex-rivera",
  SLACK_USER_NAME: "Alex Rivera",
});

const demo = require("../lib/demo");
demo.seed(dataDir);
require("../index.js");
setTimeout(() => demo.writeSessions(dataDir), 300);
console.log(`demo data in ${dataDir}`);
console.log(`open the app against it:  BRIDGE_PORT=${process.env.BRIDGE_PORT} ~/Applications/Bridge.app/Contents/MacOS/Bridge`);
