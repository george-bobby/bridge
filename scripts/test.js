#!/usr/bin/env node
// `npm test`: every test file under a throwaway HOME, so no test (or a server
// it starts) can reach your real ~/.claude, ~/.codex or ~/.cursor, guard or no guard.
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync, execFileSync } = require("child_process");

const home = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "bridge-test-home-")));
const git = (k) => {
  try {
    return execFileSync("git", ["config", "--global", k], { encoding: "utf8" }).trim();
  } catch {
    return "";
  }
};
// Keep a commit identity: tests commit in scratch repos.
fs.writeFileSync(path.join(home, ".gitconfig"), `[user]\n\tname = ${git("user.name") || "Bridge Test"}\n\temail = ${git("user.email") || "test@example.com"}\n[commit]\n\tgpgsign = false\n`);

const env = { ...process.env, HOME: home };
for (const k of ["BRIDGE_WRITE_HOME", "BRIDGE_MCP_HOME", "CLAUDE_CONFIG_DIR", "CODEX_HOME", "GIT_CONFIG_GLOBAL"]) delete env[k];
const dir = path.join(__dirname, "..", "test");
const files = fs.readdirSync(dir).filter((f) => f.endsWith(".test.js")).sort().map((f) => path.join(dir, f));
const r = spawnSync(process.execPath, ["--test", "--test-concurrency=1", ...process.argv.slice(2), ...files], { env, stdio: "inherit" });
fs.rmSync(home, { recursive: true, force: true });
process.exit(r.status == null ? 1 : r.status);
