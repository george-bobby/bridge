/**
 * Settings › Tokens: what the agents on this Mac actually spent, and the
 * token savers that can be switched on for them.
 *
 * Spend comes from CodeBurn (github.com/getagentseal/codeburn), which reads
 * each agent's local session logs and prices them. Bridge shells out to
 * `codeburn status --format menubar-json` and keeps a compact summary; its
 * first run on a big history takes a minute or more, so results are cached.
 *
 * Savers, each switched with the commands its own project documents:
 *   RTK      github.com/rtk-ai/rtk            `rtk init -g` hooks (Claude, Codex, Cursor)
 *   Caveman  github.com/JuliusBrussee/caveman  Claude Code plugin caveman@caveman
 *   Ponytail github.com/DietrichGebert/ponytail Claude Code plugin ponytail@ponytail
 * Status is read from the files those commands change, so it is cheap.
 *
 * BRIDGE_MCP_HOME points this at a scratch home in tests; the demo has fixtures.
 */

const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFile } = require("child_process");
const env = require("./env");

const home = () => process.env.BRIDGE_MCP_HOME || os.homedir();
const claudeDir = () => process.env.CLAUDE_CONFIG_DIR || path.join(home(), ".claude");
const codexDir = () => process.env.CODEX_HOME || path.join(home(), ".codex");
const cursorDir = () => path.join(home(), ".cursor");

const cliPath = () => `${env.extraPath}:${process.env.PATH || "/usr/bin:/bin"}`;
const cliEnv = () => {
  const e = { ...process.env, PATH: cliPath() };
  delete e.ACP_BACKEND;
  return e;
};

/** Runs a command with stdin closed, so a CLI that would prompt gets EOF instead of hanging. */
const sh = (cmd, args, timeout = 120000) =>
  new Promise((resolve) => {
    const child = execFile(cmd, args, { cwd: home(), timeout, maxBuffer: 64e6, env: cliEnv() }, (err, out, errOut) =>
      resolve({ ok: !err, out: String(out || ""), err: String(errOut || (err && err.message) || "").trim() }),
    );
    child.stdin && child.stdin.end();
  });

function which(bin) {
  for (const dir of cliPath().split(":")) {
    const p = path.join(dir, bin);
    try {
      fs.accessSync(p, fs.constants.X_OK);
      return p;
    } catch {}
  }
  return "";
}

const readText = (p) => {
  try {
    return fs.readFileSync(p, "utf8");
  } catch {
    return "";
  }
};
const readJson = (p) => {
  try {
    return JSON.parse(fs.readFileSync(p, "utf8"));
  } catch {
    return null;
  }
};

/* ------------------------------------------------------------- CodeBurn */

const PERIODS = { today: "Today", week: "7 days", "30days": "30 days", month: "This month" };
const CB_TTL = 5 * 60_000;
const cbCache = new Map(); // period -> { at, data }
const cbRunning = new Map(); // period -> Promise

const top = (rows, n, map) => (Array.isArray(rows) ? rows.slice(0, n).map(map) : []);
const num = (v) => Math.round((Number(v) || 0) * 100) / 100;

/** The menubar JSON is large (every PR, branch, day); keep what the pane shows. */
function summarize(j, period) {
  const c = j.current || {};
  const totals = {};
  for (const [k, v] of Object.entries(j.periodTotals || {})) if (PERIODS[k]) totals[k] = { cost: num(v.cost), calls: v.calls || 0 };
  return {
    period,
    label: c.label || PERIODS[period],
    generated: j.generated || "",
    currency: (j.currency && j.currency.symbol) || "$",
    cost: num(c.cost),
    calls: c.calls || 0,
    sessions: c.sessions || 0,
    tokens: { input: c.inputTokens || 0, output: c.outputTokens || 0, cacheRead: c.cacheReadTokens || 0, cacheWrite: c.cacheWriteTokens || 0 },
    cacheHit: Math.round(Number(c.cacheHitPercent) || 0),
    oneShot: Math.round((Number(c.oneShotRate) || 0) * 100),
    totals,
    providers: top(
      (c.providerDetails || []).filter((p) => p.hasUsage !== false && (p.cost || p.calls)).sort((a, b) => (b.cost || 0) - (a.cost || 0)),
      8,
      (p) => ({ name: p.label || p.id, cost: num(p.cost), calls: p.calls || 0 }),
    ),
    models: top(c.topModels, 6, (m) => ({ name: m.name, cost: num(m.cost), calls: m.calls || 0 })),
    projects: top(c.topProjects, 6, (p) => ({ name: p.name, cost: num(p.cost), sessions: p.sessions || 0 })),
    activities: top(c.topActivities, 6, (a) => ({ name: a.name, cost: num(a.cost), turns: a.turns || 0 })),
  };
}

async function codeburnRun(period) {
  const bin = which("codeburn");
  if (!bin) return { ok: true, installed: false, install: "brew install codeburn" };
  const [v, r] = await Promise.all([
    sh(bin, ["--version"], 20000),
    sh(bin, ["status", "--format", "menubar-json", "--period", period, "--no-optimize", "--no-timeline"], 300000),
  ]);
  if (!r.ok) return { ok: false, installed: true, version: v.out.trim(), error: r.err.split("\n").filter(Boolean).slice(-1)[0] || "codeburn failed" };
  let j;
  try {
    j = JSON.parse(r.out);
  } catch {
    return { ok: false, installed: true, version: v.out.trim(), error: "couldn't read codeburn's JSON" };
  }
  return { ok: true, installed: true, version: v.out.trim(), ...summarize(j, period) };
}

async function codeburn({ period = "30days", refresh = false } = {}) {
  if (!PERIODS[period]) period = "30days";
  if (env.demo) return require("./demo").tokens().codeburn(period);
  const hit = cbCache.get(period);
  if (!refresh && hit && Date.now() - hit.at < CB_TTL) return { ...hit.data, cached: true };
  if (!cbRunning.has(period)) {
    cbRunning.set(
      period,
      codeburnRun(period)
        .then((data) => {
          if (data.ok) cbCache.set(period, { at: Date.now(), data });
          return data;
        })
        .finally(() => cbRunning.delete(period)),
    );
  }
  return cbRunning.get(period);
}

/* --------------------------------------------------------------- savers */

const PLUGINS = {
  caveman: { id: "caveman@caveman", repo: "JuliusBrussee/caveman" },
  ponytail: { id: "ponytail@ponytail", repo: "DietrichGebert/ponytail" },
};

function pluginState(key) {
  const { id } = PLUGINS[key];
  const dir = claudeDir();
  const installed = !!((readJson(path.join(dir, "plugins", "installed_plugins.json")) || {}).plugins || {})[id];
  const marketplace = !!(readJson(path.join(dir, "plugins", "known_marketplaces.json")) || {})[id.split("@")[1]];
  const enabled = installed && ((readJson(path.join(dir, "settings.json")) || {}).enabledPlugins || {})[id] === true;
  return { installed, marketplace, enabled };
}

function pluginSaver(key, name, blurb) {
  const { id, repo } = PLUGINS[key];
  const s = pluginState(key);
  const claude = path.basename(env.claudeBin);
  const enable = [];
  if (!s.marketplace) enable.push([claude, "plugin", "marketplace", "add", repo]);
  enable.push(s.installed ? [claude, "plugin", "enable", id] : [claude, "plugin", "install", id, "--scope", "user"]);
  return {
    id: key,
    name,
    blurb,
    url: `https://github.com/${repo}`,
    installed: s.installed,
    enabled: s.enabled,
    agents: [{ agent: "Claude", on: s.enabled }],
    changes: "On installs the plugin for Claude Code (user scope) and sets it in enabledPlugins in ~/.claude/settings.json. Off disables it and leaves it installed. New sessions pick it up.",
    enable,
    disable: [[claude, "plugin", "disable", id]],
  };
}

function rtkSaver() {
  const bin = which("rtk");
  const hooked = (file, needle) => readText(file).includes(needle);
  const agents = [{ agent: "Claude", on: hooked(path.join(claudeDir(), "settings.json"), "rtk hook claude") || hooked(path.join(claudeDir(), "settings.json"), "rtk-rewrite") }];
  const codex = fs.existsSync(codexDir());
  const cursor = fs.existsSync(cursorDir());
  if (codex) agents.push({ agent: "Codex", on: hooked(path.join(codexDir(), "hooks.json"), "rtk hook codex") });
  if (cursor) agents.push({ agent: "Cursor", on: hooked(path.join(cursorDir(), "hooks.json"), "rtk hook cursor") });
  const enable = [];
  if (!bin) enable.push(["brew", "install", "rtk"]);
  enable.push(["rtk", "init", "-g", "--auto-patch"]);
  if (codex) enable.push(["rtk", "init", "-g", "--codex"]);
  if (cursor) enable.push(["rtk", "init", "-g", "--agent", "cursor", "--auto-patch"]);
  const disable = [["rtk", "init", "-g", "--uninstall"]];
  if (codex) disable.push(["rtk", "init", "-g", "--codex", "--uninstall"]);
  return {
    id: "rtk",
    name: "RTK",
    blurb: "Compresses shell output (tests, git, builds, logs) before the agent reads it, through a hook that rewrites commands to `rtk …`.",
    url: "https://github.com/rtk-ai/rtk",
    installed: !!bin,
    enabled: agents.some((a) => a.on),
    agents,
    changes: "On adds RTK's PreToolUse hook to ~/.claude/settings.json" + (codex ? ", ~/.codex/hooks.json" : "") + (cursor ? ", ~/.cursor/hooks.json" : "") + " and an RTK.md referenced from CLAUDE.md" + (codex ? "/AGENTS.md" : "") + " (backups as .bak). Off runs RTK's uninstall, which removes only its own entries. New sessions pick it up.",
    enable,
    disable,
  };
}

async function rtkGain(s) {
  if (!s.installed) return s;
  const r = await sh(which("rtk"), ["gain", "--format", "json"], 15000);
  try {
    const g = JSON.parse(r.out).summary || {};
    if (g.total_commands) s.stats = `${g.total_commands} commands, ${Number(g.total_saved || 0).toLocaleString("en-US")} tokens saved (${Math.round(g.avg_savings_pct || 0)}%)`;
  } catch {}
  return s;
}

async function savers() {
  if (env.demo) return require("./demo").tokens().savers();
  return [
    await rtkGain(rtkSaver()),
    pluginSaver("caveman", "Caveman", "Makes the agent's replies terse: drops filler, keeps code, commands and exact errors. Starts with every Claude Code session."),
    pluginSaver("ponytail", "Ponytail", "Pushes the agent to the smallest change that works: reuse what exists, standard library first, no unrequested abstractions."),
  ];
}

/** Switches one saver on or off by running the commands its status lists. */
async function toggle(id, on) {
  if (env.demo) return require("./demo").tokens().toggle(id, on);
  const s = (await savers()).find((x) => x.id === id);
  if (!s) throw new Error(`unknown saver: ${id}`);
  const log = [];
  for (const [cmd, ...args] of on ? s.enable : s.disable) {
    const bin = cmd === "claude" || cmd === path.basename(env.claudeBin) ? env.claudeBin : which(cmd) || cmd;
    const r = await sh(bin, args, 300000);
    log.push(`$ ${[cmd, ...args].join(" ")}\n${(r.out + (r.err ? `\n${r.err}` : "")).trim()}`.trim());
    if (!r.ok) throw new Error(`${[cmd, ...args].join(" ")} failed: ${r.err.split("\n").filter(Boolean).slice(-1)[0] || "error"}`);
  }
  return { saver: (await savers()).find((x) => x.id === id), log: log.join("\n\n").slice(-4000) };
}

module.exports = { codeburn, savers, toggle, summarize, PERIODS };
