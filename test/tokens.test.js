// Settings › Tokens: CodeBurn's JSON is summarized, each saver's state is
// read from the files its own commands change, and a toggle runs exactly the
// commands it listed (stub CLIs in a scratch home, nothing real is touched).
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");

const tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "bridge-tokens-")));
const HOME = path.join(tmp, "home");
const BIN = path.join(tmp, "bin");
const LOG = path.join(tmp, "calls.log");
fs.mkdirSync(path.join(HOME, ".claude", "plugins"), { recursive: true });
fs.mkdirSync(path.join(HOME, ".codex"), { recursive: true });
fs.mkdirSync(BIN);
const stub = (name, body = "") => fs.writeFileSync(path.join(BIN, name), `#!/bin/sh\necho "${name} $*" >> "${LOG}"\n${body}\n`, { mode: 0o755 });

const menubar = {
  generated: "2026-11-28T00:00:00Z",
  currency: { symbol: "$" },
  current: {
    label: "Last 30 Days",
    cost: 123.456,
    calls: 900,
    sessions: 12,
    inputTokens: 10,
    outputTokens: 20,
    cacheReadTokens: 30,
    cacheWriteTokens: 40,
    cacheHitPercent: 97.6,
    oneShotRate: 0.912,
    providerDetails: [
      { id: "codex", label: "Codex", cost: 3, calls: 4, hasUsage: true },
      { id: "claude", label: "Claude", cost: 120, calls: 890, hasUsage: true },
      { id: "copilot", label: "Copilot", cost: 0, calls: 0, hasUsage: false },
    ],
    topModels: [{ name: "Opus 5.5", cost: 120, calls: 890 }],
    topProjects: [{ name: "bridge", cost: 100, sessions: 9 }],
    topActivities: [{ name: "Coding", cost: 80, turns: 50 }],
  },
  periodTotals: { today: { cost: 1.234, calls: 5 }, week: { cost: 50, calls: 300 }, "30days": { cost: 123.456, calls: 900 }, month: { cost: 100, calls: 700 }, all: { cost: 999 } },
};
fs.writeFileSync(path.join(tmp, "menubar.json"), JSON.stringify(menubar));
stub("codeburn", `[ "$1" = "--version" ] && echo 0.9.28 && exit 0\ncat "${path.join(tmp, "menubar.json")}"`);
stub("rtk", `[ "$1" = "gain" ] && echo '{"summary":{"total_commands":3,"total_saved":4500,"avg_savings_pct":81.2}}'\n[ "$1" = "init" ] && [ "$4" != "--uninstall" ] && [ "$3" = "--auto-patch" ] && echo '{"hooks":{"PreToolUse":[{"hooks":[{"command":"rtk hook claude"}]}]}}' > "${path.join(HOME, ".claude", "settings.json")}"\nexit 0`);
stub("claude", "exit 0");

process.env.BRIDGE_MCP_HOME = HOME;
process.env.CLAUDE_CONFIG_DIR = path.join(HOME, ".claude");
delete process.env.CODEX_HOME;
process.env.EXTRA_PATH = BIN;
process.env.CLAUDE_BIN = path.join(BIN, "claude");
process.env.BRIDGE_DATA_DIR = path.join(tmp, "data");
process.env.BRIDGE_ENV_FILE = path.join(tmp, "none.env");
const t = require("../server/tokens");

test("summarizes CodeBurn's menubar JSON", async () => {
  const d = await t.codeburn({ period: "30days" });
  assert.equal(d.ok, true);
  assert.equal(d.version, "0.9.28");
  assert.equal(d.cost, 123.46);
  assert.equal(d.cacheHit, 98);
  assert.equal(d.oneShot, 91);
  assert.deepEqual(d.providers.map((p) => p.name), ["Claude", "Codex"]);
  assert.deepEqual(Object.keys(d.totals), ["today", "week", "30days", "month"]);
  assert.equal(d.totals.today.cost, 1.23);
  // cached: a second call doesn't run codeburn again
  const before = fs.readFileSync(LOG, "utf8").split("\n").filter((l) => l.startsWith("codeburn status")).length;
  assert.equal((await t.codeburn({ period: "30days" })).cached, true);
  assert.equal(fs.readFileSync(LOG, "utf8").split("\n").filter((l) => l.startsWith("codeburn status")).length, before);
});

test("savers read their state from the agents' config", async () => {
  fs.writeFileSync(path.join(HOME, ".claude", "settings.json"), JSON.stringify({ enabledPlugins: { "ponytail@ponytail": true } }));
  fs.writeFileSync(path.join(HOME, ".claude", "plugins", "installed_plugins.json"), JSON.stringify({ version: 2, plugins: { "ponytail@ponytail": [{}] } }));
  fs.writeFileSync(path.join(HOME, ".claude", "plugins", "known_marketplaces.json"), JSON.stringify({ ponytail: {} }));
  fs.writeFileSync(path.join(HOME, ".codex", "hooks.json"), JSON.stringify({ hooks: { PreToolUse: [{ hooks: [{ command: "rtk hook codex" }] }] } }));
  const s = Object.fromEntries((await t.savers()).map((x) => [x.id, x]));
  assert.deepEqual(s.rtk.agents, [{ agent: "Claude", on: false }, { agent: "Codex", on: true }]); // no ~/.cursor: no Cursor row
  assert.equal(s.rtk.enabled, true);
  assert.match(s.rtk.stats, /3 commands, 4,500 tokens saved \(81%\)/);
  assert.equal(s.ponytail.enabled, true);
  assert.deepEqual(s.ponytail.enable, [["claude", "plugin", "enable", "ponytail@ponytail"]]);
  assert.equal(s.caveman.installed, false);
  assert.deepEqual(s.caveman.enable[0], ["claude", "plugin", "marketplace", "add", "JuliusBrussee/caveman"]);
});

test("a toggle runs exactly the commands it showed", async () => {
  fs.writeFileSync(LOG, "");
  const r = await t.toggle("rtk", true);
  assert.deepEqual(fs.readFileSync(LOG, "utf8").trim().split("\n").filter((l) => !l.startsWith("rtk gain")), ["rtk init -g --auto-patch", "rtk init -g --codex"]);
  assert.equal(r.saver.agents[0].on, true);
  fs.writeFileSync(LOG, "");
  await t.toggle("caveman", false);
  assert.deepEqual(fs.readFileSync(LOG, "utf8").trim().split("\n").filter((l) => !l.startsWith("rtk gain")), ["claude plugin disable caveman@caveman"]);
  await assert.rejects(t.toggle("nope", true), /unknown saver/);
});

test.after(() => fs.rmSync(tmp, { recursive: true, force: true }));
