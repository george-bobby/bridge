/**
 * Read-only feeds for the workspace views: your pull requests (through `gh`,
 * already signed in on this machine) and your Linear issues (through
 * LINEAR_API_KEY). Nothing here writes anywhere.
 *
 * Each feed is cached for a minute and fetched at most once at a time, so a
 * page that polls, plus a second window, still costs one request per minute.
 */

const { execFile } = require("child_process");
const path = require("path");
const env = require("./env");
const { previews } = require("./previews");

const ROOT = path.join(__dirname, "..");

const TTL = 60_000;
const cache = new Map();

function cached(key, load, { refresh = false } = {}) {
  const c = cache.get(key) || {};
  if (!refresh && c.data && Date.now() - c.at < TTL) return Promise.resolve(c.data);
  if (c.inflight) return c.inflight;
  const inflight = load()
    .then((data) => {
      cache.set(key, { at: Date.now(), data });
      return data;
    })
    .catch((e) => {
      cache.set(key, { ...c, inflight: null });
      // A stale answer beats an error page; say it's stale.
      if (c.data) return { ...c.data, stale: String(e.message || e) };
      throw e;
    });
  cache.set(key, { ...c, inflight });
  return inflight;
}

/* ----------------------------------------------------------------- GitHub */

const PR_FIELDS = `number title url isDraft state createdAt updatedAt mergedAt closedAt reviewDecision mergeable
  additions deletions headRefName totalCommentsCount repository { nameWithOwner } author { login avatarUrl }
  comments(last: 5) { nodes { author { login } body } }
  commits(last: 1) { nodes { commit { statusCheckRollup { state contexts(first: 1) {
    checkRunCountsByState { state count } statusContextCountsByState { state count } } }
    status { contexts { context state targetUrl } }
    deployments(last: 6) { nodes { environment state latestStatus { state environmentUrl } } } } } }`;

// Check runs and commit statuses by outcome, for "✓ 6 · ⊙ 1" next to a PR.
const CHECK_BUCKET = {
  SUCCESS: "pass", NEUTRAL: "pass", COMPLETED: "pass",
  FAILURE: "fail", ERROR: "fail", TIMED_OUT: "fail", STARTUP_FAILURE: "fail", CANCELLED: "fail", ACTION_REQUIRED: "fail",
  PENDING: "pending", EXPECTED: "pending", QUEUED: "pending", IN_PROGRESS: "pending", WAITING: "pending",
  SKIPPED: "skipped", STALE: "skipped",
};
function checkCounts(rollup) {
  const out = { pass: 0, fail: 0, pending: 0, skipped: 0 };
  const ctx = rollup && rollup.contexts;
  if (!ctx) return out;
  for (const r of [].concat(ctx.checkRunCountsByState || [], ctx.statusContextCountsByState || [])) {
    const b = CHECK_BUCKET[r.state];
    if (b) out[b] += r.count || 0;
  }
  return out;
}

const PR_QUERY = `query($mine: String!, $review: String!, $merged: String!) {
  viewer { login }
  mine: search(query: $mine, type: ISSUE, first: 50) { nodes { ... on PullRequest { ${PR_FIELDS} } } }
  review: search(query: $review, type: ISSUE, first: 30) { nodes { ... on PullRequest { ${PR_FIELDS} } } }
  merged: search(query: $merged, type: ISSUE, first: 30) { nodes { ... on PullRequest { ${PR_FIELDS} } } }
}`;

function gh(args, input) {
  return new Promise((resolve, reject) => {
    const child = execFile(
      "gh",
      args,
      { maxBuffer: 20e6, timeout: 30_000, env: { ...process.env, PATH: `${env.extraPath}:${process.env.PATH || "/usr/bin:/bin"}` } },
      (err, stdout, stderr) => (err ? reject(new Error(String(stderr || err.message).trim().split("\n")[0])) : resolve(stdout)),
    );
    if (input) child.stdin.end(input);
  });
}

const ISSUE_KEY = /\b([A-Z][A-Z0-9]{1,9}-\d+)\b/;

function shapePr(n) {
  const head = n.commits && n.commits.nodes && n.commits.nodes[0];
  const rollup = head && head.commit.statusCheckRollup;
  const checks = (rollup && rollup.state) || "";
  const key = (String(n.title).match(ISSUE_KEY) || String(n.headRefName || "").toUpperCase().match(ISSUE_KEY) || [])[1] || "";
  return {
    number: n.number,
    title: n.title,
    url: n.url,
    repo: n.repository ? n.repository.nameWithOwner : "",
    author: n.author ? n.author.login : "",
    avatar: n.author ? n.author.avatarUrl : "",
    draft: !!n.isDraft,
    state: n.state, // OPEN | MERGED | CLOSED
    review: n.reviewDecision || "", // APPROVED | CHANGES_REQUESTED | REVIEW_REQUIRED | ""
    checks, // SUCCESS | FAILURE | ERROR | PENDING | EXPECTED | ""
    checkCounts: checkCounts(rollup), // { pass, fail, pending, skipped }
    mergeable: n.mergeable || "",
    branch: n.headRefName || "",
    additions: n.additions || 0,
    deletions: n.deletions || 0,
    comments: n.totalCommentsCount || 0,
    createdAt: n.createdAt,
    updatedAt: n.updatedAt,
    mergedAt: n.mergedAt || null,
    issueKey: key,
    previews: previews({
      deployments: (head && head.commit.deployments && head.commit.deployments.nodes) || [],
      statuses: (head && head.commit.status && head.commit.status.contexts) || [],
      comments: (n.comments && n.comments.nodes) || [],
    }),
  };
}

async function loadPulls() {
  const since = new Date(Date.now() - 14 * 86400_000).toISOString().slice(0, 10);
  const body = JSON.stringify({
    query: PR_QUERY,
    variables: {
      mine: "is:pr is:open author:@me archived:false sort:updated-desc",
      review: "is:pr is:open review-requested:@me archived:false sort:updated-desc",
      merged: `is:pr author:@me is:merged merged:>=${since} sort:updated-desc`,
    },
  });
  const out = JSON.parse(await gh(["api", "graphql", "--input", "-"], body));
  if (out.errors && !out.data) throw new Error(out.errors[0].message);
  const list = (k) => ((out.data[k] && out.data[k].nodes) || []).filter((n) => n && n.url).map(shapePr);
  return { login: out.data.viewer.login, mine: list("mine"), review: list("review"), merged: list("merged"), at: Date.now() };
}

/* ----------------------------------------------------------------- Linear */

const LINEAR_QUERY = `{
  viewer {
    name
    organization { urlKey }
    assignedIssues(first: 100, orderBy: updatedAt, filter: { state: { type: { nin: ["canceled", "duplicate"] } }, updatedAt: { gt: "-P30D" } }) {
      nodes {
        identifier title url priority priorityLabel branchName updatedAt createdAt description
        state { name type color position }
        team { key name }
        project { name }
        cycle { number }
        labels { nodes { name color } }
        attachments(first: 20) { nodes { url sourceType } }
        assignee { name avatarUrl }
        parent { identifier title url state { name type color } }
        children(first: 50) {
          nodes {
            identifier title url priority priorityLabel
            state { name type color }
            assignee { name avatarUrl isMe }
          }
        }
      }
    }
  }
}`;

/** The Slack thread an issue came from: a Slack attachment, else a permalink in its description. */
function slackLink(n) {
  const re = /https:\/\/[\w.-]*slack\.com\/archives\/[A-Z0-9]+\/p\d+(?:\?[^\s)\]>"]*)?/;
  const att = ((n.attachments && n.attachments.nodes) || []).find((a) => /slack/i.test(a.sourceType || "") || re.test(a.url || ""));
  if (att && att.url) return att.url;
  const m = String(n.description || "").match(re);
  return m ? m[0] : "";
}

async function loadLinear() {
  if (!env.linearApiKey) return { configured: false, issues: [], at: Date.now() };
  const res = await fetch("https://api.linear.app/graphql", {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: env.linearApiKey },
    body: JSON.stringify({ query: LINEAR_QUERY }),
    signal: AbortSignal.timeout(20_000),
  });
  const out = await res.json().catch(() => ({}));
  if (!res.ok || !out.data) throw new Error((out.errors && out.errors[0] && out.errors[0].message) || `Linear answered ${res.status}`);
  const v = out.data.viewer;
  const issues = v.assignedIssues.nodes.map((n) => ({
    key: n.identifier,
    title: n.title,
    url: n.url,
    priority: n.priority,
    priorityLabel: n.priorityLabel,
    branch: n.branchName || "",
    state: n.state ? n.state.name : "",
    stateType: n.state ? n.state.type : "", // triage | backlog | unstarted | started | completed
    stateColor: n.state ? n.state.color : "",
    statePos: n.state ? n.state.position : 0,
    team: n.team ? n.team.key : "",
    project: n.project ? n.project.name : "",
    cycle: n.cycle ? n.cycle.number : null,
    labels: (n.labels ? n.labels.nodes : []).map((l) => ({ name: l.name, color: l.color })),
    description: String(n.description || "").slice(0, 4000),
    slackUrl: slackLink(n),
    assignee: n.assignee ? n.assignee.name : "",
    assigneeAvatar: n.assignee ? n.assignee.avatarUrl || "" : "",
    parent: n.parent
      ? { key: n.parent.identifier, title: n.parent.title, url: n.parent.url, state: n.parent.state ? n.parent.state.name : "", stateType: n.parent.state ? n.parent.state.type : "", stateColor: n.parent.state ? n.parent.state.color : "" }
      : null,
    children: (n.children ? n.children.nodes : []).map((c) => ({
      key: c.identifier,
      title: c.title,
      url: c.url,
      priority: c.priority,
      priorityLabel: c.priorityLabel,
      state: c.state ? c.state.name : "",
      stateType: c.state ? c.state.type : "",
      stateColor: c.state ? c.state.color : "",
      assignee: c.assignee ? c.assignee.name : "",
      assigneeAvatar: c.assignee ? c.assignee.avatarUrl || "" : "",
      mine: !!(c.assignee && c.assignee.isMe),
    })),
    updatedAt: n.updatedAt,
    createdAt: n.createdAt,
  }));
  return { configured: true, viewer: v.name, org: v.organization ? v.organization.urlKey : "", issues, at: Date.now() };
}

/* ------------------------------------------------------------ dev servers */

function lsof(args) {
  return new Promise((resolve) => {
    execFile("lsof", args, { timeout: 10_000, maxBuffer: 8e6 }, (_err, stdout) => resolve(String(stdout || "")));
  });
}

// Runtimes a dev server runs under; claude, editors and chat apps listen too.
const DEV_SERVER = /^(node|bun|deno|python[\d.]*|Python|ruby|java|uvicorn|gunicorn|next-server.*|vite|php|rails|beam\.smp|dotnet|air|hugo)$/i;

/** Every TCP port your processes listen on, with the folder each process runs
 *  in, so the page can tie a dev server to the worktree it was started from. */
async function loadPorts() {
  const listen = await lsof(["-a", "-iTCP", "-sTCP:LISTEN", "-P", "-n", "-F", "pcn", "-u", String(process.getuid())]);
  const byPid = new Map();
  let pid = 0;
  let cmd = "";
  for (const line of listen.split("\n")) {
    if (line[0] === "p") pid = Number(line.slice(1));
    else if (line[0] === "c") cmd = line.slice(1);
    else if (line[0] === "n" && pid && pid !== process.pid) {
      const port = Number(line.slice(line.lastIndexOf(":") + 1));
      if (!port) continue;
      const e = byPid.get(pid) || { pid, command: cmd, ports: new Set() };
      e.ports.add(port);
      byPid.set(pid, e);
    }
  }
  if (!byPid.size) return { servers: [], at: Date.now() };
  const cwds = await lsof(["-a", "-d", "cwd", "-p", [...byPid.keys()].join(","), "-F", "pn"]);
  pid = 0;
  for (const line of cwds.split("\n")) {
    if (line[0] === "p") pid = Number(line.slice(1));
    else if (line[0] === "n" && byPid.has(pid)) byPid.get(pid).cwd = line.slice(1);
  }
  const servers = [...byPid.values()]
    .filter((e) => DEV_SERVER.test(e.command) && e.cwd && e.cwd.startsWith(require("os").homedir() + "/") && !e.cwd.startsWith(ROOT))
    .map((e) => ({ pid: e.pid, command: e.command, cwd: e.cwd, ports: [...e.ports].sort((a, b) => a - b) }));
  return { servers, at: Date.now() };
}

const alive = (pid) => {
  try { process.kill(pid, 0); return true; } catch (e) { return e.code === "EPERM"; }
};

/** Stop one dev server from the app: only a pid in `listed` (the fresh
 *  listing), never Bridge itself. SIGTERM, then SIGKILL if it outlives `graceMs`. */
async function stopListed(pid, listed, graceMs = 4000) {
  if (!Number.isInteger(pid) || pid <= 1 || pid === process.pid || pid === process.ppid) return { ok: false, status: 403, error: "That process isn't a dev server Bridge can stop." };
  if (!listed.some((s) => s.pid === pid)) return { ok: false, status: 404, error: "No dev server with that pid is listening in your folders." };
  try { process.kill(pid, "SIGTERM"); } catch (e) { if (e.code !== "ESRCH") return { ok: false, status: 500, error: String(e.message || e) }; }
  const end = Date.now() + graceMs;
  while (alive(pid) && Date.now() < end) await new Promise((r) => setTimeout(r, 100));
  if (!alive(pid)) return { ok: true, signal: "SIGTERM" };
  try { process.kill(pid, "SIGKILL"); } catch {}
  return { ok: true, signal: "SIGKILL" };
}

async function stopServer(pid) {
  const out = await stopListed(pid, (await loadPorts()).servers);
  cache.delete("ports");
  return out;
}


/* ---------------------------------- Vercel, incident.io, Granola, Datadog */

// Each is read-only, on its own key from .env (never passed to sessions), and
// answers { configured: false } without one so the app can say what's missing.

async function getJson(url, headers, what, body) {
  const init = body === undefined ? {} : { method: "POST", body: JSON.stringify(body), headers: { "Content-Type": "application/json" } };
  const res = await fetch(url, { ...init, headers: { Accept: "application/json", ...init.headers, ...headers }, signal: AbortSignal.timeout(20_000) });
  const out = await res.json().catch(() => ({}));
  const errs = Array.isArray(out.errors) ? out.errors.map((e) => (typeof e === "string" ? e : e.detail || e.title)).filter(Boolean).join("; ") : "";
  if (!res.ok) throw new Error((out.error && (out.error.message || (typeof out.error === "string" && out.error))) || out.message || errs || `${what} answered ${res.status}`);
  return out;
}

// READY | ERROR | BUILDING | INITIALIZING | QUEUED | CANCELED → a word the app styles.
const VERCEL_STATE = { READY: "ready", ERROR: "failed", BUILDING: "building", INITIALIZING: "building", QUEUED: "queued", CANCELED: "canceled" };

function shapeDeployment(d, team) {
  const m = d.meta || {};
  return {
    id: d.uid || d.id,
    project: d.name || "",
    url: d.url ? `https://${d.url}` : "",
    inspect: d.inspectorUrl || "",
    state: VERCEL_STATE[String(d.state || d.readyState || "").toUpperCase()] || "queued",
    target: d.target || "preview", // production | preview
    branch: m.githubCommitRef || m.gitlabCommitRef || m.branch || "",
    message: String(m.githubCommitMessage || m.gitlabCommitMessage || "").split("\n")[0],
    pr: m.githubPrId ? Number(m.githubPrId) : null,
    repo: m.githubCommitOrg && m.githubCommitRepo ? `${m.githubCommitOrg}/${m.githubCommitRepo}` : "",
    creator: (d.creator && (d.creator.username || d.creator.email)) || "",
    team: team ? team.slug : "",
    createdAt: d.created || d.createdAt || 0,
  };
}

/** Recent deployments across your personal account and every team the token
 *  can see (VERCEL_TEAM_ID pins it to one). VERCEL_TOKEN may list several
 *  tokens, comma-separated: a team that enforces SAML only answers a token
 *  created for that team, so each such team needs its own. A team no token
 *  could read is reported in `blocked` instead of looking empty. */
async function loadVercel() {
  const tokens = String(env.vercelToken || "").split(",").map((t) => t.trim()).filter(Boolean);
  if (!tokens.length) return { configured: false, deployments: [], at: Date.now() };
  const per = await Promise.all(tokens.map(vercelToken));
  const user = per.map((p) => p.user).find(Boolean) || "";
  const teams = [...new Set(per.flatMap((p) => p.teams))];
  const read = new Set(per.flatMap((p) => p.read));
  const blocked = [];
  for (const p of per) for (const b of p.blocked) if (!read.has(b.team) && !blocked.some((x) => x.team === b.team)) blocked.push(b);
  if (!read.size && blocked.length) throw new Error(blocked.map((b) => `${b.team}: ${b.reason}`).join("; "));
  const seen = new Set();
  const deployments = per.flatMap((p) => p.deployments).filter((d) => d.id && !seen.has(d.id) && seen.add(d.id)).sort((a, b) => b.createdAt - a.createdAt).slice(0, 60);
  return { configured: true, user, teams, blocked, deployments, at: Date.now() };
}

async function vercelToken(token) {
  const auth = { Authorization: `Bearer ${token}` };
  const api = (p, q = "") => getJson(`https://api.vercel.com${p}${q}`, auth, "Vercel");
  const user = await api("/v2/user").then((o) => o.user || {}).catch(() => ({}));
  let teams;
  if (env.vercelTeamId) teams = [{ id: env.vercelTeamId, slug: env.vercelTeamId }];
  else teams = ((await api("/v2/teams", "?limit=20").catch(() => ({}))).teams || []).map((t) => ({ id: t.id, slug: t.slug, name: t.name }));
  const scopes = env.vercelTeamId ? teams : [null, ...teams.slice(0, 6)];
  const read = [], blocked = [];
  const lists = await Promise.all(
    scopes.map((t) =>
      api("/v6/deployments", `?limit=40${t ? `&teamId=${encodeURIComponent(t.id)}` : ""}`)
        .then((o) => {
          read.push(t ? t.slug : "");
          return (o.deployments || []).map((d) => shapeDeployment(d, t));
        })
        .catch((e) => {
          const msg = String(e.message || e);
          const saml = /scope|re-authenticate|saml/i.test(msg);
          blocked.push({ team: t ? t.slug : user.username || "personal", saml, reason: saml ? "this team enforces SAML; add a token created for it" : msg });
          return [];
        }),
    ),
  );
  return { user: user.username || user.email || "", teams: teams.map((t) => t.slug), read, blocked, deployments: lists.flat() };
}

/** Recent incidents in your incident.io workspace, live ones first. */
async function loadIncidents() {
  if (!env.incidentApiKey) return { configured: false, incidents: [], at: Date.now() };
  const out = await getJson("https://api.incident.io/v2/incidents?page_size=40", { Authorization: `Bearer ${env.incidentApiKey}` }, "incident.io");
  const incidents = (out.incidents || []).map((i) => ({
    id: i.id,
    ref: i.reference || "",
    name: i.name || "",
    summary: String(i.summary || "").slice(0, 600),
    status: (i.incident_status && i.incident_status.name) || "",
    category: (i.incident_status && i.incident_status.category) || "", // triage | live | learning | closed | declined | merged | canceled | paused
    severity: (i.severity && i.severity.name) || "",
    severityRank: (i.severity && i.severity.rank) || 0,
    lead: ((i.incident_role_assignments || []).find((r) => r.role && r.role.role_type === "lead" && r.assignee) || { assignee: {} }).assignee.name || "",
    url: i.permalink || "",
    slack: i.slack_channel_id && i.slack_team_id ? `https://app.slack.com/client/${i.slack_team_id}/${i.slack_channel_id}` : "",
    createdAt: i.created_at || "",
    updatedAt: i.updated_at || "",
  }));
  return { configured: true, incidents, at: Date.now() };
}

const GRANOLA = "https://public-api.granola.ai/v1";
const granolaAuth = () => ({ Authorization: `Bearer ${env.granolaApiKey}` });

/** Your recent Granola notes (the list has no summary or link: see granolaNote). */
async function loadGranola() {
  if (!env.granolaApiKey) return { configured: false, notes: [], at: Date.now() };
  const notes = [];
  let cursor = "";
  for (let page = 0; page < 3; page++) {
    const out = await getJson(`${GRANOLA}/notes?page_size=30${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ""}`, granolaAuth(), "Granola");
    for (const n of out.notes || []) {
      if (n.deleted_at) continue;
      notes.push({ id: n.id, title: n.title || "Untitled", owner: (n.owner && (n.owner.name || n.owner.email)) || "", createdAt: n.created_at || "", updatedAt: n.updated_at || "" });
    }
    if (!out.hasMore || !out.cursor) break;
    cursor = out.cursor;
  }
  return { configured: true, notes, at: Date.now() };
}

/** One note's summary, attendees and link to open it in Granola. */
async function granolaNote(id) {
  if (env.demo) return require("./demo").granolaNote(id);
  if (!env.granolaApiKey) throw new Error("GRANOLA_API_KEY isn't set");
  if (!/^[A-Za-z0-9_-]+$/.test(String(id))) throw new Error("bad note id");
  for (const [k, v] of cache) if (k.startsWith("granola:") && !v.inflight && !(v.data && Date.now() - v.at < TTL)) cache.delete(k);
  return cached(`granola:${id}`, async () => {
    const n = await getJson(`${GRANOLA}/notes/${id}`, granolaAuth(), "Granola");
    return {
      id: n.id,
      title: n.title || "Untitled",
      url: n.web_url || "",
      attendees: (n.attendees || []).map((a) => a.name || a.email).filter(Boolean),
      event: (n.calendar_event && n.calendar_event.event_title) || "",
      summary: String(n.summary_markdown || n.summary_text || "").slice(0, 20000),
      createdAt: n.created_at || "",
    };
  });
}

/** "us5.datadoghq.com" (or "app.datadoghq.eu", a URL…) → its API and web hosts. */
function datadogHosts(raw) {
  const site = String(raw || "datadoghq.com").trim().replace(/^https?:\/\//, "").replace(/\/.*$/, "").replace(/^(app|api)\./, "") || "datadoghq.com";
  // The two-label sites serve the app on app.<site>; regional ones on the site itself.
  return { api: `https://api.${site}`, app: site.split(".").length === 2 ? `https://app.${site}` : `https://${site}` };
}

// Monitor search answers "Alert" | "Warn" | "No Data" | "OK" | …
const DD_STATUS = { alert: "alert", warn: "warn", "no data": "nodata", ok: "ok" };

/** Monitors that are alerting, warning or without data, and the last day's
 *  open Error Tracking issues. Read-only; each half reports its own error. */
async function loadDatadog() {
  if (!env.datadogApiKey || !env.datadogAppKey) return { configured: false, monitors: [], issues: [], at: Date.now() };
  const { api, app } = datadogHosts(env.datadogSite);
  const auth = { "DD-API-KEY": env.datadogApiKey, "DD-APPLICATION-KEY": env.datadogAppKey };
  const errors = {};
  const query = encodeURIComponent('status:(alert OR warn OR "no data")');
  const monitors = await getJson(`${api}/api/v1/monitor/search?query=${query}&per_page=100&sort=status,asc`, auth, "Datadog")
    .then((o) =>
      (o.monitors || []).map((m) => ({
        id: m.id,
        name: m.name || "",
        status: DD_STATUS[String(m.status || "").toLowerCase()] || "nodata",
        type: m.type || "",
        priority: m.priority || 0,
        muted: !!m.muted_until_ts || String(m.status || "").toLowerCase() === "muted",
        tags: (m.tags || []).slice(0, 6),
        triggeredAt: (m.last_triggered_ts || 0) * 1000,
        url: `${app}/monitors/${m.id}`,
      })),
    )
    .catch((e) => ((errors.monitors = String(e.message || e)), []));
  const to = Date.now();
  const issues = await getJson(`${api}/api/v2/error-tracking/issues/search?include=issue`, auth, "Datadog Error Tracking", {
    data: { type: "search_request", attributes: { query: "*", from: to - 86_400_000, to, persona: "ALL", order_by: "TOTAL_COUNT" } },
  })
    .then((o) => {
      const byId = new Map((o.included || []).filter((x) => x.type === "issue").map((x) => [x.id, x.attributes || {}]));
      return (o.data || [])
        .map((r) => {
          const id = (r.relationships && r.relationships.issue && r.relationships.issue.data && r.relationships.issue.data.id) || r.id;
          const a = byId.get(id) || {};
          return {
            id,
            type: a.error_type || "",
            message: String(a.error_message || "").split("\n")[0].slice(0, 300),
            service: a.service || "",
            where: [a.file_path, a.function_name].filter(Boolean).join(" · "),
            state: String(a.state || "").toLowerCase(),
            count: (r.attributes && r.attributes.total_count) || 0,
            firstSeen: a.first_seen || 0,
            lastSeen: a.last_seen || 0,
            url: `${app}/error-tracking?issueId=${encodeURIComponent(id)}`,
          };
        })
        .filter((i) => !["resolved", "ignored", "excluded"].includes(i.state))
        .slice(0, 40);
    })
    .catch((e) => ((errors.issues = String(e.message || e)), []));
  if (errors.monitors && errors.issues) throw new Error(errors.monitors);
  return { configured: true, site: app.replace(/^https:\/\//, ""), monitors, issues, errors, at: Date.now() };
}

const demo = env.demo ? require("./demo") : null;

module.exports = demo
  ? { pulls: async () => demo.pulls(), linear: async () => demo.linear(), ports: async () => demo.ports(), vercel: async () => demo.vercel(), incidents: async () => demo.incidents(), granola: async () => demo.granola(), datadog: async () => demo.datadog(), granolaNote, stopServer: async (pid) => demo.stopServer(pid), stopListed }
  : {
  ports: () => cached("ports", loadPorts, { refresh: true }),
  stopServer,
  stopListed,
  pulls: (o) => cached("pulls", loadPulls, o),
  linear: (o) => cached("linear", loadLinear, o),
  vercel: (o) => cached("vercel", loadVercel, o),
  incidents: (o) => cached("incidents", loadIncidents, o),
  granola: (o) => cached("granola", loadGranola, o),
  datadog: (o) => cached("datadog", loadDatadog, o),
  granolaNote,
    };
