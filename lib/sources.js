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
  commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }`;

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
  const checks = (head && head.commit.statusCheckRollup && head.commit.statusCheckRollup.state) || "";
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
    mergeable: n.mergeable || "",
    branch: n.headRefName || "",
    additions: n.additions || 0,
    deletions: n.deletions || 0,
    comments: n.totalCommentsCount || 0,
    createdAt: n.createdAt,
    updatedAt: n.updatedAt,
    mergedAt: n.mergedAt || null,
    issueKey: key,
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

module.exports = {
  ports: () => cached("ports", loadPorts, { refresh: true }),
  pulls: (o) => cached("pulls", loadPulls, o),
  linear: (o) => cached("linear", loadLinear, o),
};
