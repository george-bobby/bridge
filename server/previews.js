/**
 * Preview deployments of a PR (Vercel, Netlify, or any host that reports a
 * GitHub deployment), from what GitHub already knows about its head commit:
 *
 *   - deployments: `latestStatus.environmentUrl` (Vercel always, Netlify and
 *     others when they create deployments)
 *   - commit statuses whose target is a preview host (Netlify's
 *     `netlify/<site>/deploy-preview` points at the deploy preview)
 *   - the vercel[bot] / netlify[bot] comment, which both keep up to date
 *
 * Pure functions over GitHub's shapes; no network here.
 */

const HOSTS = /\.(vercel\.app|netlify\.app|now\.sh)$/i;
const URL_RE = /https:\/\/[a-z0-9][a-z0-9.-]*\.(?:vercel\.app|netlify\.app|now\.sh)(?:\/[^\s)\]|>"'`<]*)?/gi;
const BOTS = /^(vercel|netlify)(\[bot\])?$/i;

function providerOf(url, hint = "") {
  const s = `${hint} ${url}`.toLowerCase();
  if (s.includes("vercel") || /\.now\.sh/.test(s)) return "vercel";
  if (s.includes("netlify")) return "netlify";
  return "preview";
}

function hostOf(url) {
  try {
    return new URL(url).hostname;
  } catch {
    return "";
  }
}

// GitHub's deployment and status states, folded to ready | building | failed.
function stateOf(raw) {
  const s = String(raw || "").toUpperCase();
  if (["SUCCESS", "ACTIVE"].includes(s)) return "ready";
  if (["PENDING", "IN_PROGRESS", "QUEUED", "WAITING", "EXPECTED"].includes(s)) return "building";
  if (["FAILURE", "ERROR"].includes(s)) return "failed";
  if (["INACTIVE", "DESTROYED"].includes(s)) return "inactive";
  return "ready";
}

/**
 * @param {object} o
 * @param {Array} [o.deployments] GraphQL `Deployment` nodes, oldest first: { environment, state, latestStatus { state, environmentUrl } }
 * @param {Array} [o.statuses]    commit status contexts: { context, state, targetUrl }
 * @param {Array} [o.comments]    PR comments: { author: { login }, body }
 * @returns {Array<{provider, url, state, env}>} newest first, one per environment
 */
function previews({ deployments = [], statuses = [], comments = [] } = {}) {
  const byEnv = new Map();
  const add = (p) => {
    if (!p.url || !/^https?:\/\//.test(p.url)) return;
    const key = p.env || hostOf(p.url);
    // Later nodes are newer: the last one per environment wins.
    byEnv.set(key, p);
  };
  for (const d of deployments) {
    if (!d) continue;
    const st = d.latestStatus || {};
    const url = st.environmentUrl || "";
    const state = stateOf(st.state || d.state);
    if (state === "inactive" || !url) continue;
    add({ provider: providerOf(url, d.environment), url, state, env: String(d.environment || "") });
  }
  for (const c of statuses) {
    const url = (c && c.targetUrl) || "";
    if (!url || !HOSTS.test(hostOf(url))) continue;
    if (Array.from(byEnv.values()).some((p) => p.url === url)) continue;
    add({ provider: providerOf(url, c.context), url, state: stateOf(c.state), env: String(c.context || "") });
  }
  // Bot comments as the fallback, per bot and site (Netlify posts one per
  // site, "Deploy Preview for *site* ready!"). A site's link comes from its
  // newest comment that has one: a cancelled rebuild leaves the last good
  // deploy-preview URL serving. Its state comes from the newest comment.
  if (!byEnv.size) {
    const sites = new Map();
    for (const c of comments) {
      const login = (c && c.author && (c.author.login || c.author.name)) || (c && c.user && c.user.login) || "";
      if (!BOTS.test(login)) continue;
      const body = String(c.body || "");
      const bot = login.toLowerCase().replace("[bot]", "");
      const key = `${bot}\n${(body.match(/ for \*([^*\n]+)\*/) || [])[1] || ""}`;
      const urls = [...new Set(body.match(URL_RE) || [])];
      const prev = sites.get(key) || { bot, urls: [] };
      sites.set(key, { bot, urls: urls.length ? urls : prev.urls, last: body });
    }
    for (const { bot, urls, last } of sites.values()) {
      const state = /\b(failed|error(ed)?)\b/i.test(last) ? "failed" : /\b(building|queued|in progress)\b/i.test(last) && !/\bready\b/i.test(last) ? "building" : "ready";
      for (const url of urls) add({ provider: providerOf(url, bot), url, state, env: hostOf(url) });
    }
  }
  return [...byEnv.values()].reverse();
}

module.exports = { previews, providerOf, stateOf };
