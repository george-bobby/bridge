#!/usr/bin/env node
/**
 * bridge dashboard
 *
 * A zero-dependency local control panel for the Slack -> Claude Code fetch
 * pipeline. You paste a Slack thread link; a Claude Code session reads the thread, replies and
 * files Linear tickets through the Slack / Linear MCP connectors it already
 * has. The one timer that reads Slack (server/watch.js) files what it finds
 * in the Inbox and the chats; a job starts only when you (or, in triage mode,
 * the orchestrator) start one.
 *
 * What it owns:
 *   data/config.json    pipeline gates + job defaults (Settings writes it)
 *   data/runs/<id>.json one chat per Slack thread: transcript, phases, follow-ups
 *
 * Every chat has a composer: replying spawns a real Claude session against
 * the repo (see server/jobs.js). That is why every mutating route below is
 * origin-checked and the listener is pinned to loopback — a page on the open
 * web must not be able to POST a follow-up into a session that runs with
 * permissions skipped.
 *
 * Run:  node server          (open http://localhost:4319)
 */

const http = require("http");
const fs = require("fs");
const path = require("path");
const os = require("os");

const env = require("./env");
const store = require("./store");
const jobs = require("./jobs");
const memory = require("./memory");
const proposals = require("./proposals");
const bus = require("./bus");
const harness = require("./harness");
const tasks = require("./tasks");
const sources = require("./sources");
const projects = require("./projects");
const identity = require("./identity");
const dotenv = require("./dotenv");
const slack = env.demo ? require("./demo").slack : require("./slack");
const watcher = require("./watch");
const rules = require("./rules");
const pipeline = require("./pipeline");

const ROOT = path.join(__dirname, "..");
const PORT = env.port;
// The old browser UI (legacy/web) is served only with BRIDGE_LEGACY_WEB=1;
// otherwise the server answers the API alone and the native app is the client.
const PUBLIC = path.join(ROOT, "legacy", "web");
const LEGACY_WEB = process.env.BRIDGE_LEGACY_WEB === "1";

/* ------------------------------------------------------------- http utils */

/** Serialised transcripts by run id, keyed by the file's stamp: switching
 *  back to a chat, or a pane re-reading one that hasn't changed, skips the
 *  parse and stringify of a file that can be megabytes. A few dozen at most. */
const runBodies = new Map();

function sendJson(res, status, body) {
  res.writeHead(status, { "Content-Type": "application/json", "Cache-Control": "no-store" });
  res.end(JSON.stringify(body));
}

// Buffers, decoded once at the end: a multi-byte character split across two
// chunks would otherwise turn into two replacement characters.
function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > 2e6) {
        reject(new Error("body too large"));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

/**
 * Who may talk to this server: this machine, and pages served by this server.
 *
 * Binding 127.0.0.1 stops remote connections but not a browser. Any page you
 * visit can send requests to http://localhost:4319, DNS rebinding can make
 * one arrive with a foreign Host, and a dev server on another localhost port
 * (the very apps the sessions work on, opened in a browser tab) is a
 * different origin too. A POST here can start a session with full access, so:
 *
 *   - Host must be loopback (rebinding);
 *   - an Origin, when sent, must be this server's own: same host set, same port;
 *   - without one, a browser's Sec-Fetch-Site must say same-origin (or none).
 *
 * The app's URLSession, curl, emit.sh and bin/bridge send none of these.
 */
function loopbackHost(req) {
  return /^(127\.0\.0\.1|\[::1\]|localhost)(:\d+)?$/i.test(String(req.headers.host || ""));
}

function sameOrigin(req) {
  if (!loopbackHost(req)) return false;
  const origin = req.headers.origin;
  if (origin) return new RegExp(`^https?://(127\\.0\\.0\\.1|\\[::1\\]|localhost):${PORT}$`, "i").test(origin);
  const site = req.headers["sec-fetch-site"];
  return !site || site === "same-origin" || site === "none";
}

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  // The vendored editor is an ES module, and a browser refuses to run one
  // served as anything but a JavaScript type.
  ".mjs": "text/javascript; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".json": "application/json",
};

function serveStatic(res, urlPath) {
  const rel = urlPath === "/" ? "/index.html" : urlPath;
  const file = path.join(PUBLIC, path.normalize(rel).replace(/^(\.\.[/\\])+/, ""));
  if (file !== PUBLIC && !file.startsWith(PUBLIC + path.sep)) {
    res.writeHead(403).end("forbidden");
    return;
  }
  fs.readFile(file, (err, buf) => {
    if (err) {
      res.writeHead(404, { "Content-Type": "text/plain" }).end("not found: " + rel);
      return;
    }
    res.writeHead(200, {
      "Content-Type": MIME[path.extname(file)] || "application/octet-stream",
      "Cache-Control": "no-store",
    });
    res.end(buf);
  });
}

/* -------------------------------------------------------------- job opts */

/**
 * Open (or create) the chat for a Slack link, optionally starting the
 * pipeline on it. Shared by a pasted link, `bridge slack` and the Inbox's Start.
 */
async function chatFromLink(link, { project, opts, start } = {}) {
  const { run, created } = store.createFromLink(link);
  if (created && project) store.setProject(run.runId, String(project));
  // With the Slack connector on, the chat starts knowing who asked and what.
  if (created && slack.configured()) {
    const about = await slack.describeThread(store.parseSlackLink(link)).catch(() => null);
    const fresh0 = about && store.loadRun(run.runId);
    if (fresh0) {
      Object.assign(fresh0, { who: about.who, channel: about.channel, text: about.text, userId: about.userId || "" });
      store.saveRun(fresh0);
    }
  }
  applyOpts(run.runId, opts);
  let started = false;
  const fresh = store.loadRun(run.runId);
  if (start && !jobs.isRunning(run.runId) && !fresh.sessionId && fresh.action !== "running") {
    started = harness.startSlack(run.runId).state === "started";
  }
  return { runId: run.runId, created, started };
}

/** Fold a composer's picks into a chat before its job launches. Silent when
 *  there is nothing to apply — every caller passes an optional field. */
function applyOpts(id, opts) {
  const clean = store.sanitizeJobOpts(opts);
  if (!Object.keys(clean).length) return;
  const run = store.loadRun(id);
  if (!run) return;
  run.opts = { ...run.opts, ...clean };
  store.saveRun(run);
}

/* ------------------------------------------------------------ dir picker */

/**
 * Directory listing for the composer's working-directory picker.
 *
 * A browser cannot hand back an absolute path — `webkitdirectory` gives
 * relative names and the File System Access API gives an opaque handle — so
 * the picker walks the real filesystem through here instead. Read-only, names
 * only, and it never reads a file: it answers "what folders are inside this
 * one", which is exactly what the picker draws.
 */
function listDirs(dir) {
  const target = path.resolve(dir && dir !== "~" ? dir : os.homedir());
  if (!store.isDir(target)) throw new Error("not a directory");
  const dirs = [];
  for (const name of fs.readdirSync(target)) {
    if (name.startsWith(".")) continue; // .git, .venv, node_modules noise
    if (name === "node_modules") continue;
    const full = path.join(target, name);
    let stat;
    try {
      stat = fs.lstatSync(full);
    } catch {
      continue; // a broken symlink or something we cannot see
    }
    // Don't follow symlinks: a link into / would make the picker look infinite.
    if (!stat.isDirectory()) continue;
    dirs.push({ name, path: full, repo: fs.existsSync(path.join(full, ".git")) });
  }
  dirs.sort((a, b) => a.name.localeCompare(b.name));
  const parent = path.dirname(target);
  return {
    path: target,
    parent: parent === target ? null : parent,
    home: os.homedir(),
    repo: fs.existsSync(path.join(target, ".git")),
    dirs: dirs.slice(0, 500),
  };
}

/* ---------------------------------------------------------------- payload */

function snapshot() {
  const config = store.readConfig();
  const workdir = jobs.resolveWorkdir(config);
  return {
    config,
    cost: store.summariseCost(),
    jobs: { running: jobs.runningIds(), awaiting: jobs.awaitingIds() },
    inbox: harness.inbox().counts,
    // Only what the page actually draws: the repo a new chat's job would run
    // in, which the composer's picker opens on.
    meta: { workdir, root: ROOT, projects: projects.withRoot() },
    now: Date.now(),
  };
}

/* ----------------------------------------------------------------- routes */

/**
 * The body of a proposed memory, which a run hands over by path.
 *
 * Confined to `data/runs/memories/`: this endpoint takes an unauthenticated
 * local POST, and "read me any file and store it" is a much larger door than a
 * narration route needs. Resolved and then re-checked, the same two-step
 * server/memory.js uses — the pattern test rejects the obvious traversal, the
 * containment test is what still holds if the pattern is ever loosened.
 */
function readProposalText(textFile) {
  if (!textFile) return "";
  const file = path.resolve(proposals.DIR, String(textFile));
  if (path.dirname(file) !== path.resolve(proposals.DIR)) throw new Error("proposal text must live in data/runs/memories/");
  if (!file.endsWith(".md")) throw new Error("proposal text must be a .md file");
  return fs.readFileSync(file, "utf8");
}

const server = http.createServer((req, res) => {
  handle(req, res).catch((e) => {
    // A bad id (a malformed %-escape) or a bug in one route must cost that
    // request, never the server and every worker it is watching.
    console.error(`${req.method} ${req.url}:`, e);
    if (!res.headersSent) sendJson(res, 500, { ok: false, error: String(e.message || e) });
    else res.end();
  });
});

async function handle(req, res) {
  const url = new URL(req.url, `http://localhost:${PORT}`);
  const p = url.pathname;

  // Reads too: every transcript, file list and report is behind a GET, and
  // some GETs do work (a probe, a refresh) a foreign page must not trigger.
  if (!sameOrigin(req)) {
    sendJson(res, 403, { ok: false, error: loopbackHost(req) ? "cross-origin request refused" : "loopback only" });
    return;
  }

  // --- live stream ---------------------------------------------------------
  if (req.method === "GET" && p === "/api/events") {
    bus.subscribe(req, res);
    // Seed the new tab so it never renders an empty shell waiting for a push.
    res.write(`event: state\ndata: ${JSON.stringify(snapshot())}\n\n`);
    res.write(
      `event: runs\ndata: ${JSON.stringify({ runs: store.listRunSummaries() })}\n\n`
    );
    res.write(`event: inbox\ndata: ${JSON.stringify(harness.inbox())}\n\n`);
    return;
  }

  // --- every session an orchestrator can see (`bridge sessions`) ---------------
  // ?orchestrator=<run id> scopes it like that orchestrator's roster;
  // ?project=<id> to one project; neither = every project.
  if (req.method === "GET" && p === "/api/sessions") {
    const roster = require("./roster");
    const orch = store.loadRun(store.safeId(url.searchParams.get("orchestrator") || "") || "-");
    const project = String(url.searchParams.get("project") || "");
    const view = orch && orch.kind === "orchestrator" ? roster.forOrchestrator(orch, { isRunning: jobs.isRunning }) : { sessions: roster.list({ project, all: !project, isRunning: jobs.isRunning }), scope: project ? `project ${project}` : "all projects" };
    return sendJson(res, 200, { ok: true, scope: view.scope, sessions: view.sessions, markdown: roster.markdown(view.sessions, { scope: view.scope, bridge: path.join(ROOT, "bin", "bridge") }) });
  }

  // --- the harness ---------------------------------------------------------
  // What bin/bridge and the Inbox talk to. Same origin rules as every other route.
  if (p === "/api/tasks" || p.startsWith("/api/tasks/") || p === "/api/inbox" || p === "/api/catchup" || p.startsWith("/api/decisions/") || p.startsWith("/api/todos") || p === "/api/mode" || p === "/api/brief") {
    try {
      const body = req.method === "POST" ? JSON.parse((await readBody(req)) || "{}") : {};
      const ok = (extra) => sendJson(res, 200, { ok: true, ...extra });

      if (req.method === "GET" && p === "/api/tasks") return ok({ tasks: harness.status(), working: harness.workingCount().total, harness: store.readConfig().harness });
      if (req.method === "POST" && p === "/api/tasks") {
        return ok(await harness.spawnTask({ repo: body.repo, title: body.title, brief: body.brief, branch: body.branch, base: body.base, workspace: body.workspace, opts: body.opts, start: body.start !== false, by: body.by === "orchestrator" ? "orchestrator" : "" }));
      }
      if (req.method === "GET" && p === "/api/inbox") return ok(harness.inbox());
      if (req.method === "GET" && p === "/api/catchup") return ok(harness.catchup(url.searchParams.get("since") || "8h"));
      if (req.method === "POST" && p === "/api/mode") return ok({ harness: harness.setMode(String(body.mode || "")) });
      if (req.method === "POST" && p === "/api/brief") return ok(harness.brief({ since: String(body.since || "8h"), orchestrator: String(body.orchestrator || "") }));
      if (req.method === "POST" && p === "/api/todos") {
        if (!String(body.text || "").trim()) throw new Error("a to-do needs text");
        const out = tasks.addTodo({ key: body.key, text: body.text, taskId: body.taskId || "", url: body.url || "" });
        bus.broadcast("inbox", harness.inbox());
        return ok(out);
      }
      if (req.method === "POST" && p === "/api/todos/done") {
        const out = tasks.doneTodo(String(body.key || ""));
        bus.broadcast("inbox", harness.inbox());
        return ok({ todo: out });
      }
      const dm = p.match(/^\/api\/decisions\/([A-Za-z0-9-]+)$/);
      if (req.method === "POST" && dm) {
        const out = await harness.decide(dm[1], { answer: String(body.answer || "").slice(0, 8000), action: body.action || "answer" });
        bus.broadcast("inbox", harness.inbox());
        return ok({ decision: out });
      }
      const tm = p.match(/^\/api\/tasks\/([^/]+)(?:\/(\w+))?$/);
      if (tm) {
        const id = tasks.safeTaskId(decodeURIComponent(tm[1]));
        if (!id || !tasks.exists(id)) return sendJson(res, 404, { ok: false, error: "no such task" });
        const verb = tm[2];
        if (req.method === "GET" && !verb) {
          const pth = tasks.paths(id);
          const read = (f) => {
            try {
              return fs.readFileSync(f, "utf8");
            } catch {
              return "";
            }
          };
          const report = tasks.readReport(id);
          const meta = tasks.readMeta(id);
          return ok({
            meta,
            brief: read(pth.brief),
            report: report ? report.text : "",
            parsed: report ? { ...report.parsed, sections: undefined } : null,
            paths: pth,
            worktree: meta.worktree && meta.status !== "cleaned" ? await tasks.inspectWorktree(meta.worktree) : null,
            live: jobs.isRunning(id),
          });
        }
        if (req.method === "POST" && verb === "declare") return ok({ meta: harness.declare(id, String(body.state || ""), String(body.text || "").slice(0, 300)) });
        if (req.method === "POST" && verb === "plan") return ok({ plan: harness.plan(id, String(body.op || ""), Array.isArray(body.args) ? body.args : []) });
        if (req.method === "POST" && verb === "relaunch") {
          await harness.relaunch(id, String(body.note || "").slice(0, 2000));
          return ok({});
        }
        if (req.method === "POST" && verb === "cleanup") return ok(await harness.cleanup(id, { force: !!body.force }));
      }
      return sendJson(res, 404, { ok: false, error: `no harness route for ${req.method} ${p}` });
    } catch (e) {
      return sendJson(res, e.refused ? 409 : 400, { ok: false, error: String(e.message || e) });
    }
  }

  // --- everything the header + settings drawer render ----------------------
  if (req.method === "GET" && p === "/api/state") {
    sendJson(res, 200, snapshot());
    return;
  }

  // --- slash commands: the skills and commands a session's agent can run ---
  // Claude Code's own list (built-ins, skills, plugins) from its initialize
  // handshake, plus the skill folders the other agents read, plus anything on
  // disk the probe didn't report (it can time out, or not be Claude at all).
  if (req.method === "GET" && p === "/api/commands") {
    const runId = store.safeId(url.searchParams.get("runId") || "");
    const run = runId ? store.loadRun(runId) : null;
    const proj = url.searchParams.get("project") ? projects.get(String(url.searchParams.get("project"))) : null;
    const dir = run ? jobs.resolveWorkdir(store.readConfig(), run) : proj && proj.path && fs.existsSync(proj.path) ? proj.path : jobs.resolveWorkdir(store.readConfig());
    const out = new Map();
    const frontmatter = (text) => {
      const fm = /^---\n([\s\S]*?)\n---/.exec(text);
      const get = (k) => {
        if (!fm) return "";
        const m = new RegExp(`^${k}:[ \\t]*(.*)$`, "m").exec(fm[1]);
        if (!m) return "";
        let v = m[1].trim();
        // Folded / literal blocks: the indented lines after `key: >`.
        if (/^[>|][-+]?$/.test(v) || v === "") {
          const rest = fm[1].slice(m.index + m[0].length).split("\n").slice(1);
          const lines = [];
          for (const l of rest) {
            if (/^\s+\S/.test(l)) lines.push(l.trim());
            else break;
          }
          v = lines.join(" ");
        }
        return v.replace(/^["']|["']$/g, "");
      };
      return { name: get("name"), description: get("description"), hint: get("argument-hint") };
    };
    const add = (c) => {
      if (!c.name || out.has(c.name)) return;
      out.set(c.name, { name: c.name, description: String(c.description || "").slice(0, 240), source: c.source, scope: c.scope || "", hint: c.hint || "" });
    };
    const read = (base, kind, scope) => {
      let names = [];
      try {
        names = fs.readdirSync(base);
      } catch {
        return;
      }
      for (const n of names) {
        const file = kind === "skill" ? path.join(base, n, "SKILL.md") : path.join(base, n);
        if (kind === "command" && !n.endsWith(".md")) continue;
        let text = "";
        try {
          text = fs.readFileSync(file, "utf8").slice(0, 6000);
        } catch {
          continue;
        }
        const f = frontmatter(text);
        const name = kind === "skill" ? f.name || n : n.replace(/\.md$/, "");
        const desc = f.description || text.replace(/^---[\s\S]*?---/, "").trim().split("\n")[0] || "";
        add({ name, description: desc, source: kind, scope, hint: f.hint });
      }
    };
    const probe = env.demo ? null : await require("./agents").claudeProbe(dir, { refresh: url.searchParams.get("refresh") === "1" });
    const BUILTIN = new Set(["compact", "review", "init", "security-review", "pr-comments", "context", "cost", "usage", "clear", "model", "effort", "mcp", "agents", "config", "doctor", "recap", "insights", "ultrareview", "goal", "loop", "schedule", "batch", "simplify", "verify", "debug", "code-review", "fewer-permission-prompts", "update-config", "claude-api", "autocompact", "fast", "focus", "rename", "color", "output-style", "import", "heapdump", "reload-plugins", "reload-skills", "skill-doctor", "extra-usage", "usage-credits", "auto-mode-setup", "list-agents", "team-onboarding", "design-consent", "design-revoke"]);
    // Interactive-only commands do nothing in a headless turn.
    const TUI = new Set(["clear", "color", "config", "focus", "heapdump", "rename", "output-style", "model", "effort", "mcp", "fast", "autocompact", "reload-plugins", "reload-skills", "extra-usage", "usage-credits", "design-consent", "design-revoke", "import", "list-agents", "auto-mode-setup", "agents", "skill-doctor", "team-onboarding", "doctor", "insights", "recap", "heapdump", "workflow-launch-exec"]);
    for (const c of (probe && probe.commands) || []) {
      if (!c || !c.name || c.name.startsWith("__") || TUI.has(c.name)) continue;
      const tag = (/\(([^()]+)\)\s*$/.exec(c.description || "") || [])[1] || "";
      const own = tag === "user" || tag === "project";
      const plugin = !own && tag && !BUILTIN.has(c.name);
      const desc = own || plugin ? String(c.description || "").replace(/\s*\([^()]+\)\s*$/, "") : String(c.description || "");
      if (own) add({ name: c.name, description: desc, source: "skill", scope: tag, hint: c.argumentHint });
      else if (plugin) add({ name: c.name, description: desc, source: "plugin", scope: c.name.includes(":") ? c.name.split(":")[0] : tag.replace(/ sync$/, ""), hint: c.argumentHint });
      else if (BUILTIN.has(c.name)) add({ name: c.name, description: desc, source: "built-in", scope: "built-in", hint: c.argumentHint });
      else add({ name: c.name, description: desc, source: "skill", scope: "bundled", hint: c.argumentHint });
    }
    const home = os.homedir();
    for (const [root, scope] of [[path.join(dir, ".claude"), "project"], [path.join(home, ".claude"), "user"]]) {
      read(path.join(root, "skills"), "skill", scope);
      read(path.join(root, "commands"), "command", scope);
    }
    for (const [base, scope] of [[path.join(dir, ".agents", "skills"), "project"], [path.join(dir, ".devin", "skills"), "devin · project"], [path.join(dir, ".cursor", "skills"), "cursor · project"], [path.join(home, ".agents", "skills"), "user"], [path.join(home, ".devin", "skills"), "devin"], [path.join(home, ".config", "devin", "skills"), "devin"], [path.join(home, ".codex", "skills"), "codex"]]) read(base, "skill", scope);
    // Bridge's own, handled by the app before anything reaches the agent.
    if (run && run.kind === "orchestrator") add({ name: "brief", description: "Catch up: what needs you, Slack, to-dos, workers and what moved", source: "built-in", scope: "bridge", hint: "[3h | 8h | 24h | 3d]" });
    for (const b of [["compact", "Summarise the conversation so far to free up context"], ["review", "Review the current changes"], ["init", "Write a CLAUDE.md for this repo"], ["security-review", "Security review of the pending changes"]]) add({ name: b[0], description: b[1], source: "built-in", scope: "built-in" });
    return sendJson(res, 200, { ok: true, dir, commands: [...out.values()].sort((a, b) => a.name.localeCompare(b.name)) });
  }

  // --- files in a project folder, for the `@` picker when there's no session yet ---
  if (req.method === "GET" && p === "/api/files") {
    try {
      const proj = projects.get(String(url.searchParams.get("project") || ""));
      const dir = proj && proj.path ? proj.path : jobs.resolveWorkdir(store.readConfig());
      return sendJson(res, 200, { ok: true, ...(await require("./files").list(dir)) });
    } catch (e) {
      return sendJson(res, 400, { ok: false, error: String(e.message || e) });
    }
  }

  // --- the agents installed here and their models (composer pickers) --------
  if (req.method === "GET" && p === "/api/agents") {
    if (env.demo) return sendJson(res, 200, { ok: true, agents: require("./demo").agents() });
    return sendJson(res, 200, { ok: true, ...(await require("./agents").catalog({ refresh: url.searchParams.get("refresh") === "1" })) });
  }

  // --- plan usage for Claude, Codex, Cursor and Devin (status bar, Usage page) ---
  if (req.method === "GET" && p === "/api/usage") {
    try {
      return sendJson(res, 200, { ok: true, ...(await require("./usage").all({ refresh: url.searchParams.get("refresh") === "1" })) });
    } catch (e) {
      return sendJson(res, 500, { ok: false, error: String(e.message || e) });
    }
  }

  // --- Settings › Tokens: CodeBurn spend and the token savers (server/tokens.js) ---
  if (p.startsWith("/api/tokens/")) {
    const tokens = require("./tokens");
    try {
      if (req.method === "GET" && p === "/api/tokens/codeburn") {
        return sendJson(res, 200, await tokens.codeburn({ period: url.searchParams.get("period") || "30days", refresh: url.searchParams.get("refresh") === "1" }));
      }
      if (req.method === "GET" && p === "/api/tokens/savers") return sendJson(res, 200, { ok: true, savers: await tokens.savers() });
      if (req.method === "POST" && p === "/api/tokens/savers") {
        const body = JSON.parse((await readBody(req)) || "{}");
        return sendJson(res, 200, { ok: true, ...(await tokens.toggle(String(body.id || ""), body.on === true)) });
      }
      return sendJson(res, 404, { ok: false, error: `no tokens route for ${req.method} ${p}` });
    } catch (e) {
      return sendJson(res, 400, { ok: false, error: String(e.message || e) });
    }
  }

  // --- chats from the agents' own histories (Import chat) ------------------
  // GET /api/history[?agent=&q=] lists them, GET /api/history/:agent/:id
  // previews one, POST /api/history/import {agent, id} makes it a worker.
  if (p === "/api/history" || p.startsWith("/api/history/")) {
    const history = env.demo ? require("./demo").history : require("./history");
    try {
      if (req.method === "GET" && p === "/api/history") {
        const agent = String(url.searchParams.get("agent") || "");
        const opts = { agents: agent ? [agent] : undefined, q: url.searchParams.get("q") || "", runs: store.listRunSessions() };
        const out = history.listAsync ? await history.listAsync(opts) : history.list(opts);
        return sendJson(res, 200, { ok: true, ...out });
      }
      if (req.method === "POST" && p === "/api/history/import") {
        const body = JSON.parse((await readBody(req)) || "{}");
        const out = await harness.importChat({ agent: String(body.agent || ""), id: String(body.id || ""), project: String(body.project || ""), history });
        return sendJson(res, 200, { ok: true, ...out });
      }
      const m = p.match(/^\/api\/history\/([a-z]+)\/([^/]+)$/);
      if (req.method === "GET" && m) {
        const t = history.readAsync ? await history.readAsync(m[1], decodeURIComponent(m[2])) : history.read(m[1], decodeURIComponent(m[2]));
        return sendJson(res, 200, { ok: true, cwd: t.cwd, total: t.messages.length, messages: t.messages.slice(-40) });
      }
      return sendJson(res, 404, { ok: false, error: "not found" });
    } catch (e) {
      return sendJson(res, 400, { ok: false, error: String(e.message || e) });
    }
  }

  // --- a repo's branches and worktrees (New task's workspace pickers) -------
  if (req.method === "GET" && p === "/api/git") {
    try {
      const proj = projects.get(String(url.searchParams.get("project") || ""));
      const repo = proj && proj.path ? proj.path : jobs.resolveWorkdir(store.readConfig());
      return sendJson(res, 200, { ok: true, ...(env.demo ? require("./demo").git() : await tasks.branches(repo)) });
    } catch (e) {
      return sendJson(res, 400, { ok: false, error: String(e.message || e) });
    }
  }

  // --- MCP servers of each agent (Settings, the composer's MCP menu) --------
  if (p === "/api/mcp" || p.startsWith("/api/mcp/")) {
    try {
      const mcp = env.demo ? require("./demo").mcp : require("./mcp");
      const body = req.method === "POST" ? JSON.parse((await readBody(req)) || "{}") : {};
      // Which folder's view: a session's (its worktree), a project's, or the default repo.
      const runId = url.searchParams.get("run") || body.run || "";
      const proj = projects.get(String(url.searchParams.get("project") || body.project || ""));
      const run = runId ? store.loadRun(runId) : null;
      // Where the chat's next turn runs: that's what its agent loads servers for.
      const dir = run ? jobs.resolveWorkdir(store.readConfig(), run) : proj && proj.path ? proj.path : jobs.resolveWorkdir(store.readConfig());
      const refresh = url.searchParams.get("refresh") === "1";
      const ok = (extra) => sendJson(res, 200, { ok: true, dir, ...extra });
      if (req.method === "GET" && p === "/api/mcp") return ok(await mcp.all({ dir, refresh }));
      const m = p.match(/^\/api\/mcp\/(claude|codex|cursor|devin)(?:\/([^/]+)(?:\/(tools|enabled|login))?)?$/);
      if (!m) return sendJson(res, 404, { ok: false, error: "not found" });
      const [, agent, rawName, verb] = m;
      const name = rawName ? decodeURIComponent(rawName) : "";
      if (req.method === "GET" && !name) return ok(await mcp.list(agent, { dir, refresh }));
      if (req.method === "POST" && !name) return ok(await mcp.save(agent, { name: body.name, original: body.original || "", form: body.form || {} }, { dir }));
      if (req.method === "GET" && verb === "tools") return ok(await mcp.tools(agent, name, { dir, refresh }));
      if (req.method === "POST" && verb === "enabled") return ok(await mcp.setEnabled(agent, name, body.enabled !== false, { dir }));
      if (req.method === "POST" && verb === "login") return ok(await mcp.login(agent, name, { dir }));
      if (req.method === "DELETE" && name && !verb) return ok(await mcp.remove(agent, name, { dir }));
      return sendJson(res, 405, { ok: false, error: "method not allowed" });
    } catch (e) {
      return sendJson(res, 400, { ok: false, error: String(e.message || e) });
    }
  }

  // --- .env from Settings; a restart applies it ----------------------------
  if (p === "/api/env" || p === "/api/restart") {
    try {
      if (req.method === "GET" && p === "/api/env") return sendJson(res, 200, { ok: true, ...dotenv.describe() });
      if (req.method === "POST" && p === "/api/env") {
        const body = JSON.parse((await readBody(req)) || "{}");
        return sendJson(res, 200, { ok: true, ...dotenv.save(body.values) });
      }
      if (req.method === "POST" && p === "/api/restart") {
        // launchd (KeepAlive) starts a fresh server, which rereads .env. The
        // skill is rendered first so a changed repo or team lands in it too.
        try {
          require("child_process").execFileSync(process.execPath, [path.join(ROOT, "server", "render.js")], { stdio: "ignore", timeout: 20000 });
        } catch {}
        sendJson(res, 200, { ok: true, restarting: true });
        setTimeout(() => process.exit(0), 250);
        return;
      }
    } catch (e) {
      return sendJson(res, 400, { ok: false, error: String(e.message || e) });
    }
  }

  // --- the native Slack connector (a user token; no bot, no channel installs) ---
  if (p.startsWith("/api/slack/")) {
    try {
      const body = req.method === "POST" ? JSON.parse((await readBody(req)) || "{}") : {};
      const link = (u) => store.parseSlackLink(u);
      if (req.method === "GET" && p === "/api/slack/status") return sendJson(res, 200, { ok: true, ...(await slack.status()) });
      if (req.method === "GET" && p === "/api/slack/mentions") return sendJson(res, 200, { ok: true, mentions: await slack.mentions() });
      if (req.method === "GET" && p === "/api/slack/thread") return sendJson(res, 200, { ok: true, ...(await slack.thread(link(url.searchParams.get("url")))) });
      if (req.method === "POST" && p === "/api/slack/reply") return sendJson(res, 200, { ok: true, ...(await slack.reply({ ...link(body.url), text: body.text })) });
      if (req.method === "GET" && p === "/api/slack/channels") return sendJson(res, 200, { ok: true, channels: await slack.channels() });
      if (req.method === "GET" && p === "/api/slack/watch") return sendJson(res, 200, { ok: true, status: watcher.status(), items: watcher.all() });
      if (req.method === "POST" && p === "/api/slack/watch/poll") return sendJson(res, 200, { ok: true, ...(await watcher.poll({ force: true })), status: watcher.status() });
      const item = p.match(/^\/api\/slack\/watch\/([\w-]+)$/);
      if (req.method === "POST" && item) {
        const id = item[1];
        if (body.action === "dismiss") return sendJson(res, 200, { ok: true, item: watcher.dismiss(id) });
        if (body.action === "triage") return sendJson(res, 200, { ok: true, item: watcher.triage(id, String(body.verdict || ""), String(body.reason || "")) });
        if (body.action === "start") {
          const out = await chatFromLink(watcher.permalinkOf(id), { project: body.project, start: true });
          watcher.markStarted(id, out.runId);
          bus.broadcast("runs", { runs: store.listRunSummaries() });
          bus.broadcast("inbox", harness.inbox());
          return sendJson(res, 200, { ok: true, ...out });
        }
        return sendJson(res, 400, { ok: false, error: "action is start, dismiss or triage" });
      }
      return sendJson(res, 404, { ok: false, error: `no slack route for ${req.method} ${p}` });
    } catch (e) {
      return sendJson(res, 400, { ok: false, error: String(e.message || e) });
    }
  }

  // --- what Bridge works out itself (server/identity.js) -------------------
  if (p === "/api/identity" || p === "/api/identity/refresh") {
    if (req.method === "POST") await refreshIdentity();
    return sendJson(res, 200, { ok: true, ...identity.summary() });
  }

  // --- Settings › Customize: skills and plugins (server/customize.js) ---
  if (p === "/api/customize/skills" || p.startsWith("/api/customize/")) {
    const customize = require("./customize");
    try {
      const body = req.method === "POST" ? JSON.parse((await readBody(req)) || "{}") : Object.fromEntries(url.searchParams);
      const proj = body.project ? projects.get(String(body.project)) : null;
      const repo = proj && !proj.root ? proj.path : "";
      const ok = (extra) => sendJson(res, 200, { ok: true, ...extra });
      if (req.method === "GET" && p === "/api/customize/skills") return ok(customize.listSkills(repo));
      if (req.method === "GET" && p === "/api/customize/skills/file") return ok(customize.readSkill(body.path, repo));
      if (req.method === "POST" && p === "/api/customize/skills/file") return ok(customize.writeSkill(body.path, body.text, repo));
      if (req.method === "POST" && p === "/api/customize/skills") return ok(customize.createSkill({ ...body, repo }));
      if (req.method === "POST" && p === "/api/customize/skills/delete") return ok(customize.deleteSkill(body.path, repo));
      if (req.method === "GET" && p === "/api/customize/plugins") {
        const refresh = url.searchParams.get("refresh") === "1";
        const [claude, devin] = await Promise.all([customize.claudePlugins({ refresh }), customize.devinPlugins()]);
        return ok({ claude, codex: customize.codexPlugins(), cursor: customize.cursorPlugins(), devin });
      }
      const agentPlugin = req.method === "POST" && p.match(/^\/api\/customize\/plugins\/(claude|codex|devin)$/);
      if (agentPlugin) return ok(await customize.agentPlugin(agentPlugin[1], String(body.action || ""), String(body.id || "")));
      return sendJson(res, 404, { ok: false, error: `no customize route for ${req.method} ${p}` });
    } catch (e) {
      return sendJson(res, 400, { ok: false, error: String(e.message || e) });
    }
  }

  // --- projects: the repos in the sidebar, each with its own orchestrator ---
  if (p === "/api/projects" || p.startsWith("/api/projects/")) {
    try {
      const body = req.method === "POST" ? JSON.parse((await readBody(req)) || "{}") : {};
      const m = p.match(/^\/api\/projects\/([a-z0-9-]+)(?:\/(orchestrator))?$/);
      const all = () => projects.withRoot();
      let out;
      if (req.method === "GET" && p === "/api/projects") out = { projects: all() };
      else if (req.method === "POST" && p === "/api/projects") out = { project: projects.add(body) };
      else if (m && req.method === "POST" && m[2]) out = { runId: harness.ensureOrchestrator(m[1]).runId };
      else if (m && req.method === "POST") out = { project: projects.update(m[1], body) };
      else if (m && req.method === "DELETE") out = (projects.remove(m[1]), {});
      else return sendJson(res, 404, { ok: false, error: `no project route for ${req.method} ${p}` });
      if (req.method !== "GET") {
        bus.broadcast("projects", { projects: all() });
        bus.broadcast("runs", { runs: store.listRunSummaries() });
      }
      return sendJson(res, 200, { ok: true, ...out });
    } catch (e) {
      return sendJson(res, 400, { ok: false, error: String(e.message || e) });
    }
  }

  // --- read-only feeds for the workspace views (GitHub PRs, Linear issues) ---
  const note = req.method === "GET" && p.match(/^\/api\/sources\/granola\/([^/]+)$/);
  if (note) {
    try {
      return sendJson(res, 200, { ok: true, note: await sources.granolaNote(decodeURIComponent(note[1])) });
    } catch (e) {
      return sendJson(res, 502, { ok: false, error: String(e.message || e) });
    }
  }
  // Stop a listed dev server. The app's own action: deliberately not in policy.js
  // BRIDGE_WRITES, so a session can't call it.
  const stop = req.method === "POST" && p.match(/^\/api\/servers\/(\d+)\/stop$/);
  if (stop) {
    const r = await sources.stopServer(Number(stop[1]));
    return sendJson(res, r.ok ? 200 : r.status || 500, r.ok ? { ok: true, signal: r.signal } : { ok: false, error: r.error });
  }
  const src = req.method === "GET" && p.match(/^\/api\/sources\/(pulls|linear|ports|vercel|incidents|granola|datadog|models)$/);
  if (src) {
    try {
      const data = await sources[src[1]]({ refresh: url.searchParams.get("refresh") === "1" });
      sendJson(res, 200, { ok: true, ...data });
    } catch (e) {
      sendJson(res, 502, { ok: false, error: String(e.message || e) });
    }
    return;
  }

  // --- working-directory picker --------------------------------------------
  if (req.method === "GET" && p === "/api/dirs") {
    try {
      sendJson(res, 200, { ok: true, ...listDirs(url.searchParams.get("path")) });
    } catch (e) {
      sendJson(res, 400, { ok: false, error: String(e.message || e) });
    }
    return;
  }

  // --- project memory ------------------------------------------------------
  // What Claude Code was told about the repo a job runs in: `MEMORY.md` and the
  // one-fact-per-file memories beside it. The workdir is resolved through the
  // same jobs.resolveWorkdir() a job would use — pass a chat's id and you get
  // that chat's repo, `project` gives that project's folder, nothing the job default — so the panel
  // can never show the memory of a repo the run wouldn't have read.
  if (p === "/api/memory" || p.startsWith("/api/memory/")) {
    try {
      const body =
        req.method === "POST" ? JSON.parse((await readBody(req)) || "{}") : Object.fromEntries(url.searchParams);
      const runId = store.safeId(String(body.runId || ""));
      // ?project=<id> asks about that project's folder (Default: the root one).
      const proj = !runId && body.project ? projects.get(String(body.project)) : null;
      const workdir = proj ? proj.path : jobs.resolveWorkdir(store.readConfig(), runId ? store.loadRun(runId) : null);
      const verb = p.slice("/api/memory".length);
      const ok = (extra) => sendJson(res, 200, { ok: true, workdir, ...extra });

      // A proposal names the run it came from, and that run names the repo.
      // Resolving the workdir from it rather than trusting the one recorded on
      // the proposal keeps every route here answering about the same directory.
      const forProposal = (id) => {
        const rec = proposals.get(id);
        if (!rec) throw new Error(`no such proposal: ${id}`);
        const run = store.safeId(rec.runId) ? store.loadRun(rec.runId) : null;
        return { rec, dir: jobs.resolveWorkdir(store.readConfig(), run) };
      };

      if (req.method === "GET" && verb === "") {
        ok(memory.list(workdir));
      } else if (req.method === "GET" && verb === "/file") {
        ok(memory.read(workdir, body.name));
      } else if (req.method === "GET" && verb === "/proposals") {
        // Grouped by territory, with the live memory names so an amendment to
        // something that already exists is marked ripe without a second run.
        const live = memory.list(workdir, { usage: false }).files.map((f) => f.name);
        ok({ territories: proposals.territories(live), all: proposals.all() });
      } else if (req.method === "POST" && verb === "/file") {
        ok(memory.write(workdir, body.name, body.text));
      } else if (req.method === "POST" && verb === "/approve") {
        // The one place a proposal becomes a memory. `update` carries the whole
        // amended file rather than a patch, which is what the editor showed you
        // before you pressed the button.
        const { rec, dir } = forProposal(body.id);
        const wrote =
          rec.verdict === "update"
            ? memory.write(dir, rec.target, body.text || rec.text)
            : memory.create(dir, rec.name, body.text || rec.text, { title: rec.title, section: rec.section });
        // Every proposal for this ground, not just the one on screen — the
        // memory just written is what all of them were arguing for.
        proposals.setStatus(rec.runId, "approved");
        proposals.resolveTerritory(rec.territory, "approved");
        // `dir`, not the request's workdir: a proposal is approved from
        // wherever the panel happens to be pointed, and reporting the caller's
        // repo for a write that landed in the run's would be a lie the UI
        // then repeats.
        sendJson(res, 200, { ok: true, workdir: dir, ...wrote, verdict: rec.verdict });
      } else if (req.method === "POST" && verb === "/discard") {
        // The row you pressed this on is a territory, not a single proposal, so
        // discarding it drops the whole case rather than one run's half of it.
        const rec = proposals.setStatus(String(body.id || ""), "discarded");
        proposals.resolveTerritory(rec.territory, "discarded");
        ok(rec);
      } else if (req.method === "POST" && verb === "/archive") {
        ok(memory.archive(workdir, body.name));
      } else if (req.method === "POST" && verb === "/restore") {
        ok(memory.restore(workdir, body.name));
      } else if (req.method === "POST" && verb === "/draft") {
        // You type the point; a read-only session decides whether the repo
        // already remembers it and writes the file properly either way. What
        // comes back is a proposal — reviewed in the same editor, written by
        // the same validated path — so drafting can never itself touch
        // ~/.claude.
        const info = memory.list(workdir, { usage: false });
        const draft = await jobs.draftMemory(body.text, {
          config: store.readConfig(),
          run: runId ? store.loadRun(runId) : null,
          memoryDir: info.dir,
          project: info.project,
        });
        // Keyed by a synthetic id, not a run: this came from you, not a
        // mention, and it must not collide with a run's own proposal.
        const id = `draft-${Date.now().toString(36)}`;
        const rec = proposals.propose(id, {
          ...draft,
          citation: "typed in the dashboard",
          workdir,
          // Yours is ripe immediately — the recurrence bar exists to stop
          // unattended runs banking noise, and you are neither.
          ripeNow: true,
        });
        ok({ ...rec, draftedFrom: String(body.text || "").slice(0, 200) });
      } else if (req.method === "POST" && verb === "/relist") {
        ok(memory.relist(workdir, body.name, { section: body.section }));
      } else {
        sendJson(res, 404, { ok: false, error: `no memory route for ${req.method} ${p}` });
      }
    } catch (e) {
      sendJson(res, 400, { ok: false, error: String(e.message || e) });
    }
    return;
  }

  // --- transcript search (the ⌘K palette) -----------------------------------
  if (req.method === "GET" && p === "/api/search") {
    sendJson(res, 200, { ok: true, hits: store.searchRuns(url.searchParams.get("q")) });
    return;
  }

  // --- sidebar -------------------------------------------------------------
  if (req.method === "GET" && p === "/api/runs") {
    sendJson(res, 200, { runs: store.listRunSummaries() });
    return;
  }

  // --- a chat from a pasted Slack link --------------------------------------
  // The only way a chat is born from the dashboard. Pasting a link to a thread
  // that already has a chat opens that chat rather than minting a second one;
  // `start` runs the pipeline on it straight away unless a job already ran.
  if (req.method === "POST" && p === "/api/runs") {
    try {
      const body = JSON.parse((await readBody(req)) || "{}");
      const out = await chatFromLink(body.url, body);
      // `bridge slack` from the orchestrator: its outcomes go back to it.
      if (body.by === "orchestrator" && out.runId && tasks.exists(out.runId)) tasks.writeMeta(out.runId, { by: "orchestrator" });
      bus.broadcast("runs", { runs: store.listRunSummaries() });
      sendJson(res, 200, { ok: true, ...out });
    } catch (e) {
      sendJson(res, 400, { ok: false, error: String(e.message || e) });
    }
    return;
  }

  // --- a chat's subagents and background tasks ------------------------------
  // The output file is only ever the one Claude named for that task.
  const taskMatch = p.match(/^\/api\/runs\/([^/]+)\/tasks\/([A-Za-z0-9_-]{1,80})\/(output|stop)$/);
  if (taskMatch) {
    const id = store.safeId(decodeURIComponent(taskMatch[1]));
    const run = id ? store.loadRun(id) : null;
    const task = run && (run.messages || []).flatMap((m) => m.tasks || []).find((t) => t.id === taskMatch[2] || t.toolUseId === taskMatch[2]);
    if (!task) return sendJson(res, 404, { ok: false, error: "no such task" });
    if (req.method === "POST" && taskMatch[3] === "stop") {
      if (task.status !== "running") return sendJson(res, 409, { ok: false, error: "that task isn't running" });
      const sent = jobs.stopTask(id, task.id);
      return sendJson(res, sent ? 200 : 409, sent ? { ok: true } : { ok: false, error: "the session has ended" });
    }
    if (req.method === "GET" && taskMatch[3] === "output") {
      // Only the file Claude named for this task: `<task id>.output`.
      const file = task.outputFile && path.basename(task.outputFile) === `${task.id}.output` ? task.outputFile : "";
      let text = "";
      let size = 0;
      let fd = null;
      try {
        const st = fs.statSync(file);
        size = st.size;
        const cap = 256 * 1024;
        fd = fs.openSync(file, "r");
        const buf = Buffer.alloc(Math.min(cap, size));
        const n = fs.readSync(fd, buf, 0, buf.length, Math.max(0, size - cap));
        text = buf.subarray(0, n).toString("utf8");
      } catch {
      } finally {
        if (fd != null) fs.closeSync(fd);
      }
      return sendJson(res, 200, { ok: true, task: task.id, text, size, truncated: size > 256 * 1024, exists: !!file && fs.existsSync(file) });
    }
    return sendJson(res, 405, { ok: false, error: "method not allowed" });
  }

  // --- a chat's queued messages: edit, remove, or send now (interrupting) ---
  const queueMatch = p.match(/^\/api\/runs\/([^/]+)\/queue\/([\w-]+)(\/send)?$/);
  if (queueMatch) {
    const id = store.safeId(decodeURIComponent(queueMatch[1]));
    const qid = queueMatch[2];
    if (!id) return sendJson(res, 400, { ok: false, error: "bad run id" });
    try {
      if (req.method === "DELETE" && !queueMatch[3]) return sendJson(res, 200, { ok: jobs.editQueued(id, qid, null) });
      if (req.method !== "POST") return sendJson(res, 405, { ok: false, error: "method not allowed" });
      const body = JSON.parse((await readBody(req)) || "{}");
      if (queueMatch[3]) {
        const item = jobs.queueOf(id).find((m) => m.id === qid);
        if (!item) throw new Error("that message has already gone out");
        return sendJson(res, 200, { ok: true, ...jobs.interrupt(id, item.text, { config: store.readConfig(), id: qid }) });
      }
      const text = String(body.text || "").trim();
      if (!text) throw new Error("empty message");
      if (text.length > 20000) throw new Error("message too long");
      return sendJson(res, 200, { ok: jobs.editQueued(id, qid, text) });
    } catch (e) {
      return sendJson(res, 409, { ok: false, error: String(e.message || e) });
    }
  }

  // --- one chat ------------------------------------------------------------
  const runMatch = p.match(/^\/api\/runs\/([^/]+)(?:\/(\w+))?$/);
  if (runMatch) {
    const id = store.safeId(decodeURIComponent(runMatch[1]));
    const verb = runMatch[2];
    if (!id) {
      sendJson(res, 400, { ok: false, error: "bad run id" });
      return;
    }

    if (req.method === "GET" && !verb) {
      // Current to the last streamed delta: `seq` tells the app which of the
      // deltas it holds are already in here (see jobs.flushLive).
      const seq = jobs.flushLive(id);
      const stamp = store.runStamp(id);
      const hit = runBodies.get(id);
      let body = hit && hit.stamp === stamp ? hit.body : "";
      if (!body) {
        const run = store.loadRun(id);
        if (!run) {
          sendJson(res, 404, { ok: false, error: "no such run" });
          return;
        }
        body = JSON.stringify(run);
        runBodies.delete(id);
        runBodies.set(id, { stamp, body });
        while (runBodies.size > 24) runBodies.delete(runBodies.keys().next().value);
      }
      // No `running` alongside it: the page tracks live jobs through the
      // `jobs` event on the SSE stream, which is pushed the moment one starts
      // or ends rather than only when a chat happens to be fetched.
      res.writeHead(200, { "Content-Type": "application/json", "Cache-Control": "no-store" });
      res.end(`{"run":${body},"seq":${seq},"queue":${JSON.stringify(jobs.queueOf(id))}}`);
      return;
    }

    // The pipeline narrates itself through here. Best-effort by design:
    // `emit.sh` swallows failures, so a dashboard that isn't running never
    // blocks or breaks a run started from a terminal.
    if (req.method === "POST" && verb === "event") {
      try {
        const body = JSON.parse((await readBody(req)) || "{}");
        const run = store.loadRun(id) || store.blankRun(id, body);
        // The pipeline read the thread through the Slack connector; `message`
        // is the opening ask. Seed it once, at the top of the transcript, so
        // the chat starts where Slack did even though this server never saw it.
        if (body.message && !run.messages.some((m) => m.role === "slack")) {
          const ask = {
            id: `slack-${run.runId}`,
            ts: Math.floor(Number(run.rootTs || run.threadTs) || Date.now() / 1000),
            role: "slack",
            author: body.who || run.who,
            text: String(body.message),
            permalink: body.permalink || run.permalink || "",
          };
          run.messages.unshift(ask);
          run.text = ask.text;
        }
        for (const k of ["who", "channel", "channelId", "userId", "permalink", "threadTs", "prUrl", "linearUrl", "action"]) {
          if (body[k]) run[k] = body[k];
        }
        const phase = String(body.phase || "step");
        // A pipeline run records its worktree for cleanup and status.
        if (body.worktree || body.branch || body.prUrl) {
          const patch = {};
          if (body.worktree && path.isAbsolute(String(body.worktree))) patch.worktree = String(body.worktree);
          if (body.branch) patch.branch = String(body.branch).slice(0, 120);
          if (body.prUrl) patch.prUrl = String(body.prUrl);
          if (Object.keys(patch).length && tasks.safeTaskId(id)) tasks.writeMeta(id, { kind: "slack", repo: jobs.resolveWorkdir(store.readConfig(), run), ...patch });
        }

        // A `memory` event is a *proposal*, never a memory: it lands in
        // data/runs/memories/, which no session loads, and is promoted only by
        // recurrence or by you (see server/proposals.js §8.7 of the skill). Filed
        // through the narration route on purpose — emit.sh stays the single way
        // a headless run talks to the dashboard, and a proposal that fails to
        // parse must not cost the run its stage line.
        if (phase === "memory") {
          try {
            proposals.propose(id, {
              verdict: body.verdict,
              territory: body.territory,
              reason: String(body.detail || body.text || ""),
              citation: body.citation,
              target: body.target,
              name: body.name,
              title: body.title,
              section: body.section,
              workdir: jobs.resolveWorkdir(store.readConfig(), run),
              // The memory itself is passed by path, since it is a whole file
              // and `text` is already this event's one-line summary. Confined
              // to the proposals directory so a POST here cannot read the disk.
              text: readProposalText(body.textFile),
            });
          } catch (e) {
            store.appendMessage(run, { role: "event", phase, text: `memory proposal rejected: ${e.message}` });
          }
        }

        const msg = store.appendMessage(run, {
          role: body.role === "outcome" ? "outcome" : "event",
          phase,
          text: String(body.detail || body.text || ""),
          prUrl: body.prUrl || "",
          linearUrl: body.linearUrl || "",
        });
        run.phase = phase;
        store.saveRun(run);
        bus.broadcast("message", { runId: id, message: msg });
        bus.broadcast("run-updated", { runId: id });
        sendJson(res, 200, { ok: true });
      } catch (e) {
        sendJson(res, 400, { ok: false, error: String(e.message || e) });
      }
      return;
    }

    // This chat's job options — which repo, model, permission mode, effort and
    // context window its next job runs with. Sparse: only the keys you have
    // actually changed are stored, so a chat you never tuned keeps following
    // the Settings defaults.
    if (req.method === "POST" && verb === "opts") {
      try {
        const body = JSON.parse((await readBody(req)) || "{}");
        const run = store.loadRun(id);
        if (!run) throw new Error("unknown run");
        run.opts = { ...run.opts, ...store.sanitizeJobOpts(body.opts) };
        store.saveRun(run);
        bus.broadcast("run-updated", { runId: id });
        sendJson(res, 200, { ok: true, opts: run.opts, effective: store.jobOpts(store.readConfig(), run) });
      } catch (e) {
        sendJson(res, 400, { ok: false, error: String(e.message || e) });
      }
      return;
    }

    if (req.method === "POST" && verb === "followup") {
      try {
        const body = JSON.parse((await readBody(req)) || "{}");
        const text = String(body.text || "").trim();
        if (!text) throw new Error("empty follow-up");
        if (text.length > 20000) throw new Error("follow-up too long");
        // The composer sends what it is showing along with the message, so the
        // job can never run under options you changed but that hadn't landed.
        applyOpts(id, body.opts);
        // `/clear` in an orchestrator wipes its chat instead of reaching the agent.
        if (text === "/clear" && projects.isOrchestrator(id)) {
          jobs.clear(id);
          bus.broadcast("runs", { runs: store.listRunSummaries() });
          return sendJson(res, 200, { ok: true, cleared: true });
        }
        // `/compact` typed in the composer compacts for real, whatever the agent.
        const c = /^\/compact(?:\s+([\s\S]*))?$/.exec(text);
        if (c && !jobs.isRunning(id)) {
          const out = jobs.compact(id, { config: store.readConfig(), instructions: c[1] || "" });
          return sendJson(res, 200, { ok: true, compacted: true, native: out.native });
        }
        // While a turn runs: `steer` hands it to that turn, `interrupt` stops
        // it and sends this next, `queue` (or `queue: true`) waits for it.
        const config = store.readConfig();
        const mode = String(body.mode || (body.queue ? "queue" : ""));
        if (mode === "steer") return sendJson(res, 200, { ok: true, ...jobs.steer(id, text, { config }) });
        if (mode === "interrupt") return sendJson(res, 200, { ok: true, ...jobs.interrupt(id, text, { config }) });
        if (!body.opts || !body.opts.agent) await harness.autoFailover(id);
        const msg = jobs.startFollowup(id, text, { config, queue: mode === "queue" });
        sendJson(res, 200, { ok: true, message: msg, queued: !!(msg && msg.queued), ...(msg && msg.queued ? { id: msg.id } : {}) });
      } catch (e) {
        sendJson(res, 409, { ok: false, error: String(e.message || e) });
      }
      return;
    }

    if (req.method === "POST" && verb === "agent") {
      try {
        const body = JSON.parse((await readBody(req)) || "{}");
        const clean = store.sanitizeJobOpts({ agent: body.agent, agentModel: body.model == null ? "" : body.model });
        if (!clean.agent) throw new Error("agent is claude, codex, cursor or devin");
        const run = store.loadRun(id);
        if (!run) throw new Error("unknown run");
        const before = store.jobOpts(store.readConfig(), run).agent || "claude";
        run.opts = { ...run.opts, agent: clean.agent };
        if (clean.agent === "claude") {
          delete run.opts.agentModel;
          if (clean.agentModel) run.opts.model = clean.agentModel;
        } else run.opts.agentModel = clean.agentModel || "";
        const labels = { claude: "Claude", codex: "Codex", cursor: "Cursor", devin: "Devin" };
        const label = labels[clean.agent];
        const text = `Agent changed from ${labels[before]} to ${label}; the current turn will finish and the next turn will use ${label}`;
        const msg = store.appendMessage(run, { role: "event", phase: "agent", text });
        store.saveRun(run);
        bus.broadcast("message", { runId: id, message: msg });
        bus.broadcast("run-updated", { runId: id });
        return sendJson(res, 200, { ok: true, agent: clean.agent, model: clean.agent === "claude" ? run.opts.model || "" : run.opts.agentModel || "", queued: jobs.isRunning(id) });
      } catch (e) {
        return sendJson(res, 400, { ok: false, error: String(e.message || e) });
      }
    }

    // Run the pipeline on a chat that hasn't had one yet.
    if (req.method === "POST" && verb === "start") {
      try {
        const body = JSON.parse((await readBody(req)) || "{}");
        applyOpts(id, body.opts);
        const out = harness.startSlack(id);
        bus.broadcast("runs", { runs: store.listRunSummaries() });
        sendJson(res, 200, { ok: true, ...out });
      } catch (e) {
        sendJson(res, 409, { ok: false, error: String(e.message || e) });
      }
      return;
    }

    // Answer whatever the running session stopped to ask — a permission
    // request, a question, or a plan waiting for approval. The session is
    // blocked until this lands, which is why it is the one route that reaches
    // straight into a live child process rather than going through the run file.
    if (req.method === "POST" && verb === "answer") {
      try {
        const body = JSON.parse((await readBody(req)) || "{}");
        const askId = String(body.askId || "");
        if (!askId) throw new Error("which question?");
        const out = jobs.answerAsk(id, askId, {
          behavior: body.behavior,
          message: body.message,
          answers: body.answers,
        });
        sendJson(res, 200, out);
      } catch (e) {
        // 409, not 400: the usual cause is a second tab (or a stale one) having
        // answered it already, which is a race rather than a bad request.
        sendJson(res, 409, { ok: false, error: String(e.message || e) });
      }
      return;
    }

    // The composer's `@` picker: the files in this session's folder.
    if (req.method === "GET" && verb === "files") {
      try {
        const run = store.loadRun(id);
        if (!run) throw new Error("no such run");
        const meta = tasks.exists(id) ? tasks.readMeta(id) || {} : {};
        const dir = meta.worktree && fs.existsSync(meta.worktree) ? meta.worktree : jobs.resolveWorkdir(store.readConfig(), run);
        return sendJson(res, 200, { ok: true, ...(await require("./files").list(dir)) });
      } catch (e) {
        return sendJson(res, 400, { ok: false, error: String(e.message || e) });
      }
    }

    // Start the orchestrator over: an empty chat and a fresh agent session.
    if (req.method === "POST" && verb === "clear") {
      if (!projects.isOrchestrator(id)) return sendJson(res, 409, { ok: false, error: "only an orchestrator chat can be cleared" });
      try {
        jobs.clear(id);
        bus.broadcast("runs", { runs: store.listRunSummaries() });
        return sendJson(res, 200, { ok: true });
      } catch (e) {
        return sendJson(res, 409, { ok: false, error: String(e.message || e) });
      }
    }

    // Free up context: /compact for Claude, a self-handoff for the others.
    if (req.method === "POST" && verb === "compact") {
      try {
        const body = JSON.parse((await readBody(req)) || "{}");
        const out = jobs.compact(id, { config: store.readConfig(), instructions: body.instructions });
        return sendJson(res, 200, { ok: true, native: out.native });
      } catch (e) {
        return sendJson(res, 409, { ok: false, error: String(e.message || e) });
      }
    }

    // `#` in the composer: a briefing of this session, written to a file
    // another session's agent can read, plus where its transcript lives.
    if (req.method === "GET" && verb === "reference") {
      try {
        const run = store.loadRun(id);
        if (!run) throw new Error("no such run");
        const meta = tasks.exists(id) ? tasks.readMeta(id) || {} : {};
        const title = meta.title || run.who || id;
        const transcript = path.join(store.PATHS.runs, `${id}.json`);
        const text = require("./agents").briefing(run, {
          meta,
          report: tasks.exists(id) ? tasks.readReport(id) : null,
          title: `# Referenced session: ${title}`,
          intro: `Session id \`${id}\`. This is a summary of another Bridge session, for context: don't act on it unless asked. The full transcript is the JSON file below.`,
          transcript,
          now: false,
          lines: 40,
        });
        const dir = path.join(env.dataDir, "references");
        fs.mkdirSync(dir, { recursive: true });
        const file = path.join(dir, `${id}.md`);
        fs.writeFileSync(file, text);
        return sendJson(res, 200, { ok: true, path: file, transcript, title, worktree: meta.worktree || "" });
      } catch (e) {
        return sendJson(res, 400, { ok: false, error: String(e.message || e) });
      }
    }

    if (req.method === "POST" && verb === "stop") {
      sendJson(res, 200, { ok: jobs.stop(id) });
      return;
    }

    // Same chat, same session, real terminal. The dashboard is the better
    // place to *watch* a run; it is a worse place to take one over, and until
    // now the only way out was to go digging for the session id by hand.
    if (req.method === "GET" && verb === "terminal") {
      try {
        sendJson(res, 200, { ok: true, ...jobs.terminalInfo(id, { config: store.readConfig() }) });
      } catch (e) {
        sendJson(res, 404, { ok: false, error: String(e.message || e) });
      }
      return;
    }

    // The session's working folder: what changed, per-file diffs, and the
    // commit / push / PR actions you take on them from the app.
    if (verb === "changes" || verb === "diff" || verb === "commit" || verb === "push" || verb === "pr") {
      const changes = require("./changes");
      try {
        const run = store.loadRun(id);
        if (!run) throw new Error("no such run");
        const meta = tasks.exists(id) ? tasks.readMeta(id) || {} : {};
        const dir = meta.worktree && fs.existsSync(meta.worktree) ? meta.worktree : jobs.resolveWorkdir(store.readConfig(), run);
        const body = req.method === "POST" ? JSON.parse((await readBody(req)) || "{}") : {};
        if (req.method === "GET" && verb === "pr") {
          return sendJson(res, 200, { ok: true, ...(await changes.activity(run.prUrl || meta.prUrl, { refresh: url.searchParams.get("refresh") === "1" })) });
        }
        if (req.method === "GET" && verb === "changes") return sendJson(res, 200, { ok: true, ...(await changes.status(dir)) });
        if (req.method === "GET" && verb === "diff") return sendJson(res, 200, { ok: true, diff: await changes.diff(dir, url.searchParams.get("file")) });
        if (req.method === "POST" && verb === "commit") return sendJson(res, 200, { ok: true, ...(await changes.commit(dir, body.message)) });
        if (req.method === "POST" && verb === "push") return sendJson(res, 200, { ok: true, ...(await changes.push(dir)) });
        if (req.method === "POST" && verb === "pr") {
          const prUrl = await changes.openPr(dir, body);
          const fresh = store.loadRun(id);
          fresh.prUrl = prUrl;
          store.saveRun(fresh);
          if (tasks.exists(id)) tasks.writeMeta(id, { prUrl });
          bus.broadcast("runs", { runs: store.listRunSummaries() });
          return sendJson(res, 200, { ok: true, prUrl });
        }
      } catch (e) {
        return sendJson(res, 400, { ok: false, error: String(e.message || e) });
      }
    }

    // Pinned to the top of its project in the sidebar.
    if (req.method === "POST" && (verb === "pin" || verb === "project")) {
      try {
        const body = JSON.parse((await readBody(req)) || "{}");
        const out = verb === "pin" ? { pinned: store.setPinned(id, !!body.pinned) } : { project: store.setProject(id, String(body.project || "")) };
        bus.broadcast("runs", { runs: store.listRunSummaries() });
        sendJson(res, 200, { ok: true, ...out });
      } catch (e) {
        sendJson(res, 400, { ok: false, error: String(e.message || e) });
      }
      return;
    }

    // The board column you dragged this chat to ("" = automatic).
    if (req.method === "POST" && verb === "board") {
      try {
        const body = JSON.parse((await readBody(req)) || "{}");
        const board = store.setBoard(id, body.column);
        bus.broadcast("runs", { runs: store.listRunSummaries() });
        sendJson(res, 200, { ok: true, board });
      } catch (e) {
        sendJson(res, 400, { ok: false, error: String(e.message || e) });
      }
      return;
    }

    // Clears the unread dot. Cheap enough to fire on every chat open.
    if (req.method === "POST" && verb === "seen") {
      const run = store.loadRun(id);
      if (run) {
        run.seenAt = Math.floor(Date.now() / 1000);
        store.saveRun(run);
      }
      sendJson(res, 200, { ok: true });
      return;
    }

    // What archiving would do with the chat's worktree (the archive dialog asks first).
    if (req.method === "GET" && verb === "archive") {
      try {
        sendJson(res, 200, { ok: true, worktree: env.demo ? require("./demo").archive(id) : await harness.worktreeState(id) });
      } catch (e) {
        sendJson(res, 400, { ok: false, error: String(e.message || e) });
      }
      return;
    }

    // Archive a chat, or bring it back ({ archived: false }); `deleteWorktree`
    // removes a worktree Bridge made, refusing (409, `refused`) on uncommitted
    // or unpushed work unless `force`.
    if (req.method === "POST" && verb === "archive") {
      try {
        const body = JSON.parse((await readBody(req)) || "{}");
        const on = body.archived !== false;
        if (on && projects.isOrchestrator(id)) {
          sendJson(res, 409, { ok: false, error: "the orchestrator chat can't be archived" });
          return;
        }
        if (on && jobs.isRunning(id)) {
          sendJson(res, 409, { ok: false, error: "stop the running job first" });
          return;
        }
        sendJson(res, 200, { ok: true, ...(await harness.archive(id, on, { deleteWorktree: !!body.deleteWorktree, force: !!body.force })) });
      } catch (e) {
        sendJson(res, e.refused ? 409 : 400, { ok: false, error: String(e.message || e), ...(e.refused ? { refused: true } : {}) });
      }
      return;
    }

    if (req.method === "DELETE" && !verb) {
      if (projects.isOrchestrator(id)) {
        sendJson(res, 409, { ok: false, error: "the orchestrator chat can't be deleted" });
        return;
      }
      if (jobs.isRunning(id)) {
        sendJson(res, 409, { ok: false, error: "stop the running job first" });
        return;
      }
      store.deleteRun(id);
      harness.discard(id);
      bus.broadcast("runs", { runs: store.listRunSummaries() });
      sendJson(res, 200, { ok: true });
      return;
    }
  }

  // --- toggles + settings --------------------------------------------------
  // Common rules and the pipeline share one shape: { text, default, custom }.
  const editable = { "/api/rules": rules, "/api/pipeline": pipeline }[p];
  if (editable && (req.method === "GET" || req.method === "POST")) {
    try {
      if (req.method === "GET") return sendJson(res, 200, { ok: true, ...editable.get() });
      const body = JSON.parse((await readBody(req)) || "{}");
      sendJson(res, 200, { ok: true, ...(body.reset ? editable.reset() : editable.save(body.text)) });
    } catch (e) {
      sendJson(res, 400, { ok: false, error: String(e.message || e) });
    }
    return;
  }

  if (req.method === "POST" && p === "/api/config") {
    try {
      const incoming = JSON.parse((await readBody(req)) || "{}");
      const config = store.writeConfig(incoming);
      const h = incoming.harness || {};
      if (h.pipelineProject != null || h.linearTeam != null || h.pipelineModel != null) refreshIdentity();
      bus.broadcast("state", snapshot());
      sendJson(res, 200, { ok: true, config });
    } catch (e) {
      sendJson(res, 400, { ok: false, error: String(e.message || e) });
    }
    return;
  }

  // --- static --------------------------------------------------------------
  if (req.method === "GET" && LEGACY_WEB) {
    serveStatic(res, p);
    return;
  }

  res.writeHead(404, { "Content-Type": "text/plain" });
  res.end("not found");
}

/* ---------------------------------------------------- watching the files */

// config.json can be edited by hand while the dashboard is open; stat-polling
// one small file costs nothing and keeps every tab honest.
let configStamp = 0;

function pollFiles() {
  let mtime = 0;
  try {
    mtime = fs.statSync(store.PATHS.config).mtimeMs;
  } catch {}
  if (mtime !== configStamp) {
    configStamp = mtime;
    bus.broadcast("state", snapshot());
  }
}

/* -------------------------------------------------------------------- go */

store.ensureRunsDir();
// Every session we could have been asked a question by died when this process
// did, so nothing on disk is still waiting for an answer. Sweep before the
// first render or the sidebar comes up claiming chats need you.
store.clearPendingAsks();
// After the sweep: recovery reads the run files and the task folders, re-arms
// nothing (the server is the watcher) and turns whatever died with the last
// process into an outcome you can resume from.
harness.start();
watcher.start();
setInterval(pollFiles, 1500).unref();
pollFiles();

// Almost always means a dashboard from an earlier terminal is still alive —
// it survives the shell that started it. Say so instead of dumping a stack.
server.on("error", (err) => {
  if (err.code !== "EADDRINUSE") throw err;
  console.error(`port ${PORT} is already in use — a dashboard is probably already running.`);
  console.error(`  open it:   http://localhost:${PORT}`);
  console.error(`  stop it:   npm stop   (the background copy npm start runs)`);
  console.error(`  find it:   lsof -nP -iTCP:${PORT} -sTCP:LISTEN`);
  console.error(`  replace:   kill $(lsof -t -iTCP:${PORT} -sTCP:LISTEN) && node server`);
  console.error(`  or move:   BRIDGE_PORT=4320 node server`);
  process.exit(1);
});

/** Work out identities, repo and PATH again; re-render the pipeline skill when they moved. */
async function refreshIdentity() {
  const before = JSON.stringify(identity.summary().derived);
  await identity.resolve().catch(() => null);
  if (JSON.stringify(identity.summary().derived) !== before && !env.demo) {
    await new Promise((done) => require("child_process").execFile(process.execPath, [path.join(ROOT, "server", "render.js")], { timeout: 20000 }, () => done()));
  }
  bus.broadcast("identity", identity.summary());
}

server.listen(PORT, "127.0.0.1", () => {
  setTimeout(() => refreshIdentity(), 1500);
  const config = store.readConfig();
  console.log(`bridge server  ->  http://localhost:${PORT}/api${LEGACY_WEB ? `  (legacy web UI: http://localhost:${PORT})` : ""}`);
  console.log(`  runs:      ${store.PATHS.runs}`);
  console.log(`  config:    ${store.PATHS.config}`);
  console.log(`  follow-up: ${jobs.resolveWorkdir(config)}  (model: ${config.followup.model})`);
});
