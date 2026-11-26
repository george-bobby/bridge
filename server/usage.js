/**
 * Plan usage for the four agents, for the status bar and the Usage page.
 *
 *   Claude   api.anthropic.com/api/oauth/usage with Claude Code's own login
 *            (macOS Keychain "Claude Code-credentials", or ~/.claude/.credentials.json)
 *   Codex    chatgpt.com/backend-api/wham/usage with ~/.codex/auth.json, falling
 *            back to the rate limits Codex writes into its own session logs
 *   Cursor   Cursor's dashboard API with the CLI's keychain login (then the
 *            editor's); team plans read the member's spend vs its limit
 *   Devin    no public usage endpoint: ACUs from Devin turns Bridge ran
 *
 * Plus, for every agent, what Bridge itself ran on it this week and month:
 * turns, tokens, cost (or ACUs).
 *
 * Credentials are read here, used for one request, and never returned,
 * logged or cached beyond the process. Nothing is refreshed: each CLI owns
 * its own login, and refreshing behind its back would rotate its tokens.
 */

const fs = require("fs");
const os = require("os");
const path = require("path");
const crypto = require("crypto");
const { execFile } = require("child_process");
const env = require("./env");

const HOME = os.homedir();
const TTL = 4 * 60_000; // Claude's endpoint 429s if polled hard
const cache = new Map();
const blockedUntil = new Map();

const run = (bin, args, timeout = 4000) =>
  new Promise((resolve) => execFile(bin, args, { timeout, maxBuffer: 4e6 }, (err, out) => resolve(err ? "" : String(out).trim())));

const readJson = (f) => {
  try {
    return JSON.parse(fs.readFileSync(f, "utf8"));
  } catch {
    return null;
  }
};

async function getJson(url, { headers = {}, method = "GET", body } = {}) {
  const res = await fetch(url, { method, headers: { Accept: "application/json", ...headers }, body, signal: AbortSignal.timeout(15_000) });
  const text = await res.text();
  if (res.status === 401 || res.status === 403) return { status: res.status, rejected: true };
  if (res.status === 429) return { status: 429, retryAfter: res.headers.get("retry-after") };
  if (!res.ok) return { status: res.status, error: `${new URL(url).host} answered ${res.status}` };
  if (text.trim().startsWith("<")) return { status: res.status, error: "got a web page instead of usage data" };
  try {
    return { status: res.status, json: JSON.parse(text) };
  } catch {
    return { status: res.status, error: "unreadable usage response" };
  }
}

const unavailable = (reason) => ({ status: "unavailable", reason });
const rejected = (who) => ({ status: "unavailable", reason: `${who}: login rejected. Sign in again.` });
const pct = (v) => (v == null || Number.isNaN(Number(v)) ? null : Math.max(0, Math.min(100, Number(v))));
const ms = (t) => (t == null ? null : typeof t === "number" ? (t < 1e11 ? t * 1000 : t) : Date.parse(t) || null);

function jwtClaims(token) {
  try {
    return JSON.parse(Buffer.from(String(token).split(".")[1], "base64url").toString("utf8"));
  } catch {
    return {};
  }
}

/* --------------------------------------------------------------- Claude */

async function claudeCreds() {
  const dir = process.env.CLAUDE_CONFIG_DIR;
  const service = dir ? `Claude Code-credentials-${crypto.createHash("sha256").update(path.resolve(dir).normalize("NFC")).digest("hex").slice(0, 8)}` : "Claude Code-credentials";
  let raw = "";
  if (process.platform === "darwin") {
    const user = /^[a-zA-Z0-9._-]+$/.test(os.userInfo().username) ? os.userInfo().username : "claude-code-user";
    raw = (await run("/usr/bin/security", ["find-generic-password", "-a", user, "-w", "-s", service])) || (await run("/usr/bin/security", ["find-generic-password", "-w", "-s", service]));
  }
  let creds = null;
  try {
    creds = raw ? JSON.parse(raw) : readJson(path.join(dir || path.join(HOME, ".claude"), ".credentials.json"));
  } catch {}
  return creds && creds.claudeAiOauth;
}

async function claude() {
  const c = await claudeCreds();
  if (!c || !c.accessToken) return unavailable("Not signed in to Claude Code");
  if (c.expiresAt && c.expiresAt <= Date.now()) return unavailable("Claude Code's login has expired: run claude once to refresh it");
  const headers = { Authorization: `Bearer ${c.accessToken}`, "anthropic-beta": "oauth-2025-04-20" };
  const [u, p] = await Promise.all([getJson("https://api.anthropic.com/api/oauth/usage", { headers }), getJson("https://api.anthropic.com/api/oauth/profile", { headers })]);
  if (u.rejected) return rejected("Claude");
  if (u.status === 429) {
    const secs = Number(u.retryAfter) || Math.max(60, (Date.parse(u.retryAfter) - Date.now()) / 1000) || 600;
    blockedUntil.set("claude", Date.now() + secs * 1000);
    throw new Error(`Rate limited by Claude; trying again in ${Math.ceil(secs / 60)}m`);
  }
  if (u.error) throw new Error(u.error);
  const j = u.json;
  const windows = [];
  const add = (id, label, short, w, duration) => w && windows.push({ id, label, short, usedPct: pct(w.utilization ?? w.percent), resetsAt: ms(w.resets_at), duration });
  add("session", "Session", "5h", j.five_hour, 18000);
  add("weekly", "Weekly", "wk", j.seven_day, 604800);
  const scoped = new Map();
  for (const [key, name] of [["seven_day_opus", "Opus"], ["seven_day_omelette", "Omelette"]]) if (j[key]) scoped.set(name.toLowerCase(), { name, w: j[key] });
  for (const l of Array.isArray(j.limits) ? j.limits : []) {
    if (!l || l.kind !== "weekly_scoped" || !l.scope) continue;
    const s = l.scope.model || l.scope.surface || {};
    const name = s.display_name || s.id;
    if (name) scoped.set(String(name).toLowerCase(), { name, w: { percent: l.percent, resets_at: l.resets_at } });
  }
  for (const [key, { name, w }] of scoped) add(`weekly-${key}`, `Weekly · ${name}`, `wk ${name}`, w, 604800);
  const tier = String(c.rateLimitTier || "").split("_").pop();
  const plan = c.subscriptionType ? `${c.subscriptionType[0].toUpperCase()}${c.subscriptionType.slice(1)}${/^\d+x$/.test(tier) ? ` ${tier}` : ""}` : "";
  const details = [];
  if (j.extra_usage) details.push({ label: "Extra usage", value: j.extra_usage.is_enabled ? "Enabled" : "Disabled" });
  return { status: "ok", plan, account: (p.json && p.json.account && p.json.account.email) || "", windows, details };
}

/* ---------------------------------------------------------------- Codex */

function codexFromLogs() {
  const root = path.join(process.env.CODEX_HOME || path.join(HOME, ".codex"), "sessions");
  const files = [];
  try {
    for (const y of fs.readdirSync(root).sort().reverse().slice(0, 1))
      for (const m of fs.readdirSync(path.join(root, y)).sort().reverse().slice(0, 1))
        for (const d of fs.readdirSync(path.join(root, y, m)).sort().reverse().slice(0, 2))
          for (const f of fs.readdirSync(path.join(root, y, m, d))) files.push(path.join(root, y, m, d, f));
  } catch {
    return null;
  }
  files.sort((a, b) => fs.statSync(b).mtimeMs - fs.statSync(a).mtimeMs);
  for (const f of files.slice(0, 5)) {
    const lines = fs.readFileSync(f, "utf8").trim().split("\n").reverse();
    for (const line of lines) {
      if (!line.includes('"token_count"') || !line.includes("rate_limits")) continue;
      try {
        const rl = JSON.parse(line).payload.rate_limits;
        if (rl && (rl.primary || rl.secondary)) return { rl, at: fs.statSync(f).mtimeMs };
      } catch {}
    }
  }
  return null;
}

const label = (secs, fallback) => (!secs ? fallback : secs <= 18000 ? `${Math.round(secs / 3600)}-hour` : secs >= 604800 && secs < 2.6e6 ? "Weekly" : secs >= 2.6e6 ? "Monthly" : `${Math.round(secs / 3600)}h`);
const short = (secs) => (!secs ? "" : secs <= 18000 ? `${Math.round(secs / 3600)}h` : secs >= 604800 && secs < 2.6e6 ? "wk" : secs >= 2.6e6 ? "mo" : `${Math.round(secs / 3600)}h`);

async function codex() {
  const auth = readJson(path.join(process.env.CODEX_HOME || path.join(HOME, ".codex"), "auth.json"));
  const t = auth && auth.tokens;
  const claims = t ? { ...jwtClaims(t.id_token), ...jwtClaims(t.access_token) } : {};
  const account = (claims["https://api.openai.com/profile"] || {}).email || claims.email || "";
  if (t && t.access_token) {
    const id = t.account_id || (claims["https://api.openai.com/auth"] || {}).chatgpt_account_id;
    const r = await getJson("https://chatgpt.com/backend-api/wham/usage", {
      headers: { Authorization: `Bearer ${t.access_token}`, "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", ...(id ? { "ChatGPT-Account-Id": id } : {}) },
    });
    if (r.json) {
      const j = r.json;
      const windows = [];
      const add = (key, w, fallback) => {
        if (!w) return;
        const secs = w.limit_window_seconds;
        windows.push({ id: key, label: label(secs, fallback), short: short(secs), usedPct: pct(w.used_percent), resetsAt: ms(w.reset_at), duration: secs || null });
      };
      add("primary", j.rate_limit && j.rate_limit.primary_window, "Primary limit");
      add("secondary", j.rate_limit && j.rate_limit.secondary_window, "Secondary limit");
      for (const a of j.additional_rate_limits || []) if (a && a.limit_name && a.rate_limit) add(`limit-${a.metered_feature || a.limit_name}`, a.rate_limit.primary_window, a.limit_name);
      if (j.code_review_rate_limit) add("code-review", j.code_review_rate_limit.primary_window, "Code review");
      const details = j.credits && j.credits.balance != null ? [{ label: "Credits", value: String(j.credits.balance) }] : [];
      return { status: "ok", plan: j.plan_type ? `${j.plan_type[0].toUpperCase()}${j.plan_type.slice(1)}` : "", account: j.email || account, windows, details };
    }
    if (r.rejected) {
      const local = codexFromLogs();
      if (!local) return rejected("Codex");
    }
  }
  const local = codexFromLogs();
  if (!local) return unavailable("Not signed in to Codex");
  const { rl, at } = local;
  const windows = [];
  for (const [key, w] of [["primary", rl.primary], ["secondary", rl.secondary]]) {
    if (!w) continue;
    const secs = w.window_minutes ? w.window_minutes * 60 : null;
    const resets = w.resets_at ? ms(w.resets_at) : w.resets_in_seconds ? at + w.resets_in_seconds * 1000 : null;
    windows.push({ id: key, label: label(secs, key === "primary" ? "Primary limit" : "Secondary limit"), short: short(secs), usedPct: pct(w.used_percent), resetsAt: resets, duration: secs });
  }
  return { status: "ok", plan: rl.plan_type ? `${rl.plan_type[0].toUpperCase()}${rl.plan_type.slice(1)}` : "", account, windows, details: [{ label: "Source", value: "Codex session logs" }] };
}

/* --------------------------------------------------------------- Cursor */

/** Every Cursor login we can find, best first: the cursor-agent CLI's
 *  keychain entry (what Bridge actually runs), then the editor's, then
 *  auth files. The editor's token goes stale while the CLI's stays fresh. */
async function cursorTokens() {
  const out = [];
  const add = (t) => {
    t = String(t || "").trim().replace(/^"|"$/g, "");
    if (t && !out.includes(t)) out.push(t);
  };
  add(process.env.CURSOR_ACCESS_TOKEN || process.env.CURSOR_TOKEN);
  if (process.platform === "darwin") add(await run("/usr/bin/security", ["find-generic-password", "-s", "cursor-access-token", "-a", "cursor-user", "-w"]));
  const db = path.join(HOME, "Library/Application Support/Cursor/User/globalStorage/state.vscdb");
  if (fs.existsSync(db)) add(await run("/usr/bin/sqlite3", ["-readonly", db, "SELECT value FROM ItemTable WHERE key='cursorAuth/accessToken'"]));
  for (const f of [path.join(HOME, ".cursor/auth.json"), path.join(HOME, ".config/cursor/auth.json")]) {
    const j = readJson(f);
    if (j && j.accessToken) add(j.accessToken);
  }
  return out;
}

const dollars = (cents) => `$${(Number(cents) / 100).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

async function cursor() {
  const tokens = await cursorTokens();
  if (!tokens.length) return unavailable("Not signed in to Cursor: run cursor-agent login");
  let call, me;
  for (const token of tokens) {
    const c = (method, body = {}) =>
      getJson(`https://api2.cursor.sh/aiserver.v1.DashboardService/${method}`, {
        method: "POST",
        headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", "Connect-Protocol-Version": "1" },
        body: JSON.stringify(body),
      });
    const r = await c("GetMe");
    if (r.rejected) continue;
    if (r.error) throw new Error(r.error);
    call = c;
    me = r.json || {};
    break;
  }
  if (!call) return rejected("Cursor");
  const teamId = me.teamId || null;
  const [period, plan, team, grants] = await Promise.all([
    call("GetCurrentPeriodUsage", teamId ? { teamId } : {}),
    call("GetPlanInfo"),
    teamId && me.email ? call("GetTeamSpend", { teamId, searchTerm: me.email }) : null,
    call("GetUsageLimitStatusAndActiveGrants"),
  ]);
  const j = period.json || {};
  const p = j.planUsage || {};
  const t = (team && team.json) || {};
  const end = ms(Number(t.nextCycleStart) || Number(j.billingCycleEnd) || null);
  const start = ms(Number(t.subscriptionCycleStart) || Number(j.billingCycleStart) || null);
  const duration = end && start && end > start ? Math.round((end - start) / 1000) : 2592000;
  const windows = [];
  const details = [];
  for (const [id, lbl, v] of [["total", "Monthly", p.totalPercentUsed], ["auto", "Cursor models", p.autoPercentUsed], ["api", "Other models", p.apiPercentUsed]]) {
    if (v != null) windows.push({ id, label: lbl, short: id === "total" ? "mo" : lbl, usedPct: pct(v), resetsAt: end, duration });
  }
  if (p.limit != null) details.push({ label: "Included", value: `${dollars(p.totalSpend || 0)} of ${dollars(p.limit)}` });
  // Team and enterprise plans: no planUsage; the member's own spend vs its per-user limit.
  const mine = (t.teamMemberSpend || []).find((m) => (me.userId && m.userId === me.userId) || (me.email && m.email === me.email));
  if (mine) {
    const spent = Number(mine.spendCents ?? mine.overallSpendCents) || 0;
    const limit = Number(mine.effectivePerUserLimitDollars ?? mine.monthlyLimitDollars ?? mine.hardLimitOverrideDollars) || 0;
    if (limit > 0) {
      windows.push({ id: "spend", label: "Monthly spend", short: "mo", usedPct: pct((spent / (limit * 100)) * 100), resetsAt: end, duration });
      details.push({ label: "Spend", value: `${dollars(spent)} of ${dollars(limit * 100)}` });
    } else details.push({ label: "Spend", value: `${dollars(spent)} this cycle, no per-user limit` });
  }
  for (const g of ((grants && grants.json) || {}).activeGrants || []) {
    if (Number(g.remainingCents) > 0) details.push({ label: g.grantType === "promo" ? "Promo credit" : "Credit", value: `${dollars(g.remainingCents)} of ${dollars(g.totalCents)} left` });
  }
  if (me.teamName) details.push({ label: "Team", value: me.teamName });
  const planName = (plan.json && plan.json.planInfo && plan.json.planInfo.planName) || (me.isEnterpriseUser ? "Enterprise" : "");
  if (!windows.length) details.unshift({ label: "Plan usage", value: planName === "Enterprise" ? "No usage cap published for this Enterprise seat" : "Cursor published no usage for this cycle", info: true });
  return { status: "ok", plan: planName, account: me.email || "", windows, details };
}

/* ---------------------------------------------------------------- Devin */

async function devin() {
  return { status: "ok", plan: "", account: "", windows: [], details: [{ label: "Plan usage", value: "Devin doesn't publish plan limits; ACUs below are from turns Bridge ran", info: true }] };
}

/* ------------------------------------------------------- Bridge's own use */

/** Turns, tokens, cost and ACUs per agent over the last 7 and 30 days, read
 *  off the transcripts Bridge keeps. */
/** Bridge's own record of turns per agent (store.js indexes the run files). */
const local = () => require("./store").summariseUsage();

/* ---------------------------------------------------------------- entry */

const PROVIDERS = { claude: ["Claude", claude], codex: ["Codex", codex], cursor: ["Cursor", cursor], devin: ["Devin", devin] };

async function one(id, refresh) {
  const c = cache.get(id);
  const blocked = blockedUntil.get(id) || 0;
  if (c && (!refresh || Date.now() < blocked) && Date.now() - c.at < (Date.now() < blocked ? Infinity : TTL)) return c.data;
  let data;
  try {
    data = await PROVIDERS[id][1]();
  } catch (e) {
    data = c ? { ...c.data, stale: String(e.message || e) } : { status: "error", reason: String(e.message || e) };
  }
  data = { id, label: PROVIDERS[id][0], fetchedAt: Date.now(), ...data };
  cache.set(id, { at: Date.now(), data });
  return data;
}

async function all({ refresh = false } = {}) {
  if (env.demo) return require("./demo").usage();
  const counts = local();
  const providers = await Promise.all(Object.keys(PROVIDERS).map((id) => one(id, refresh)));
  return { providers: providers.map((p) => ({ ...p, local: counts[p.id] || null })), at: Date.now() };
}

module.exports = { all, claudeCreds };
