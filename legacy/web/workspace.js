/* The workspace layer: the full-width views that sit beside the chat client.
 *
 *   Overview  what is running, what needs you, PRs and issues at a glance
 *   Board     every session as a card in Backlog / In progress / Needs you /
 *             In review / Done. A card follows its run until you drag it;
 *             then your column wins until you unpin it.
 *   PRs       your open PRs, reviews asked of you, recently merged (via gh)
 *   Linear    issues assigned to you (via LINEAR_API_KEY on the server)
 *
 * Loaded after app.js and harness.js and built on their globals, wrapping
 * render functions the same way harness.js does.
 */

const W = { view: "chats", pulls: null, linear: null, ports: null, err: {}, loading: {}, showAllDone: false, drag: "", hits: new Map() };

const VIEWS = [
  ["home", "Overview", "1"],
  ["board", "Board", "2"],
  ["chats", "Chats", "3"],
  ["prs", "Pull requests", "4"],
  ["linear", "Linear", "5"],
];

const COLUMNS = [
  { key: "backlog", label: "Backlog", hint: "not started" },
  { key: "doing", label: "In progress", hint: "a session is working" },
  { key: "needs", label: "Needs you", hint: "blocked on an answer or idle" },
  { key: "review", label: "In review", hint: "PR open" },
  { key: "done", label: "Done", hint: "merged, shipped or closed" },
];

const NEEDS_STATUS = ["needs-input", "blocked", "worker-stalled", "worker-gone", "usage-limit", "idle-without-report"];

/* ------------------------------------------------------------- linking */

const normUrl = (u) => String(u || "").replace(/[#?].*$/, "").replace(/\/+$/, "").toLowerCase();

function prIndex() {
  const m = new Map();
  if (!W.pulls) return m;
  for (const list of ["merged", "review", "mine"]) for (const pr of W.pulls[list]) m.set(normUrl(pr.url), pr);
  return m;
}

const runTitle = (r) => (r.kind === "task" && r.task && r.task.title) || r.who || "someone";

/** The Linear key a session is about, from its ticket link, branch or title. */
function runIssueKey(r) {
  const from = [r.linearUrl, r.task && r.task.branch && r.task.branch.toUpperCase(), runTitle(r), r.text].join(" ");
  const m = from.match(/\/issue\/([A-Za-z][A-Za-z0-9]{1,9}-\d+)/) || from.match(/\b([A-Z][A-Z0-9]{1,9}-\d+)\b/);
  return m ? m[1].toUpperCase() : "";
}

function autoColumn(r, prs) {
  const st = (r.task && r.task.status) || "";
  const pr = r.prUrl ? prs.get(normUrl(r.prUrl)) : null;
  if (pr && pr.state !== "OPEN") return "done";
  if (isAwaiting(r) || NEEDS_STATUS.includes(st)) return "needs";
  if (isLive(r) || st === "working" || st === "queued") return "doing";
  if (st === "cleaned" || st === "stopped") return "done";
  if (r.prUrl) {
    // Loaded and not among the open ones: merged or closed more than 14 days ago.
    if (W.pulls && !pr) return "done";
    return "review";
  }
  if (st === "ready-for-review" || st === "pushed-follow-up") return "review";
  if (r.action === "acted" || r.action === "skipped" || r.action === "error") return "done";
  if (!r.worked) return "backlog";
  return "needs";
}

const boardRuns = () => S.runs.filter((r) => r.kind !== "orchestrator");
const columnOf = (r, prs) => r.board || autoColumn(r, prs);

/* --------------------------------------------------------------- fetch */

async function loadSource(name, refresh) {
  if (W.loading[name]) return;
  W.loading[name] = true;
  if (W.view !== "chats") drawWorkspace();
  try {
    W[name] = await api(`/api/sources/${name}${refresh ? "?refresh=1" : ""}`);
    W.err[name] = W[name].stale || "";
  } catch (e) {
    W.err[name] = e.message;
  }
  W.loading[name] = false;
  if (W.view !== "chats") drawWorkspace();
}

const refreshSources = (refresh) => {
  loadSource("pulls", refresh);
  loadSource("linear", refresh);
  loadSource("ports", refresh);
};

/* --------------------------------------------------------- dev servers */

const servers = () => (W.ports && W.ports.servers) || [];
const inside = (cwd, dir) => !!dir && (cwd === dir || cwd.startsWith(dir.replace(/\/+$/, "") + "/"));

/** Dev servers started inside this session's own worktree. A chat working in
 *  the shared main checkout claims none: every chat there would claim them all. */
function serversForRun(r) {
  const dir = (r.task && r.task.worktree) || (r.workdir && r.workdir !== (S.meta && S.meta.workdir) ? r.workdir : "");
  return dir ? servers().filter((x) => inside(x.cwd, dir)) : [];
}

function serversForBranch(branch) {
  if (!branch) return [];
  const tail = branch.split("/").pop();
  const flat = branch.replace(/\//g, "-");
  return servers().filter((x) => x.cwd.includes("/" + flat) || x.cwd.includes("/" + tail + "/") || x.cwd.endsWith("/" + tail));
}

function portChips(list) {
  const out = [];
  for (const sv of list) for (const port of sv.ports.slice(0, 3)) {
    const a = link(`http://localhost:${port}`, `:${port}`, "wschip port");
    a.title = `${sv.command} in ${sv.cwd}`;
    out.push(a);
  }
  return out;
}

/* ---------------------------------------------------------------- views */

function setView(view, { push = true } = {}) {
  if (!VIEWS.some(([k]) => k === view)) view = "chats";
  if (view !== "chats" && H.view) closeInbox(false);
  W.view = view;
  $("app").classList.toggle("wide", view !== "chats");
  if (push) history.replaceState(null, "", view === "chats" ? location.pathname + (S.currentId ? "#" + S.currentId : "") : "#" + view);
  paintViewNav();
  renderChat();
  if (view !== "chats") {
    drawWorkspace();
    if (view !== "board" || !W.pulls) refreshSources(false);
  }
}

function paintViewNav() {
  for (const b of $("viewNav").querySelectorAll("button")) b.setAttribute("aria-selected", String(b.dataset.view === W.view));
}

(function buildViewNav() {
  const nav = el("nav", "seg viewnav");
  nav.id = "viewNav";
  for (const [key, label, n] of VIEWS) {
    const b = el("button", null, label);
    b.dataset.view = key;
    b.title = `${label} (${n})`;
    b.onclick = () => setView(key);
    nav.appendChild(b);
  }
  document.querySelector(".topbar .brand").after(nav);
  const host = el("div", "wsview");
  host.id = "wsView";
  host.hidden = true;
  document.querySelector(".main .view").appendChild(host);
})();

const _wsRenderChat = renderChat;
renderChat = function () {
  _wsRenderChat();
  const wide = W.view !== "chats";
  $("wsView").hidden = !wide;
  if (wide) {
    $("chatEmpty").style.display = "none";
    $("chatPane").style.display = "none";
    $("inboxView").hidden = true;
  }
};

const _wsOpenRun = openRun;
openRun = function (id, o) {
  if (W.view !== "chats" && id) setView("chats", { push: false });
  return _wsOpenRun(id, o);
};

const _wsOpenInbox = openInbox;
openInbox = function (tab) {
  if (W.view !== "chats") setView("chats", { push: false });
  return _wsOpenInbox(tab);
};

const _wsRenderSidebar = renderSidebar;
renderSidebar = function () {
  _wsRenderSidebar();
  if (W.view === "board" || W.view === "home") drawWorkspace();
};

function drawWorkspace() {
  const host = $("wsView");
  if (W.view === "chats" || !host) return;
  // Never redraw under a drag or a half-typed card.
  if (W.drag) return;
  const a = document.activeElement;
  const draft = a && host.contains(a) && a.tagName === "TEXTAREA" ? { v: a.value, s: a.selectionStart } : null;
  host.innerHTML = "";
  ({ home: drawHome, board: drawBoard, prs: drawPulls, linear: drawLinear })[W.view](host);
  if (draft) {
    const t = host.querySelector("textarea");
    if (t) {
      t.value = draft.v;
      t.focus();
      t.setSelectionRange(draft.s, draft.s);
    }
  }
}

function wsHead(host, title, sub, extra) {
  const head = el("div", "wshead");
  const t = el("div", "wstitle");
  t.appendChild(el("h2", null, title));
  if (sub) t.appendChild(el("div", "wssub", sub));
  head.appendChild(t);
  head.appendChild(el("div", "spacer"));
  if (extra) for (const n of extra) head.appendChild(n);
  host.appendChild(head);
  return head;
}

function refreshBtn(names) {
  const b = el("button", "btn" + (names.some((n) => W.loading[n]) ? " spin" : ""));
  b.innerHTML =
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12a9 9 0 1 1-2.6-6.4"/><path d="M21 3v6h-6"/></svg>';
  b.appendChild(document.createTextNode(" Refresh"));
  b.onclick = () => names.forEach((n) => loadSource(n, true));
  return b;
}

function errorNote(host, name) {
  if (!W.err[name]) return;
  host.appendChild(el("div", "wserr", (W[name] ? "Showing the last copy: " : "") + W.err[name]));
}

const link = (href, text, cls) => {
  const a = el("a", cls || "wslink", text);
  a.href = href;
  a.target = "_blank";
  a.rel = "noopener";
  a.onclick = (e) => e.stopPropagation();
  return a;
};

const agoIso = (iso) => (iso ? agoOf(Date.parse(iso) / 1000) : "");

/* ------------------------------------------------------------ PR chips */

const CHECKS = {
  SUCCESS: ["ok", "checks pass"],
  FAILURE: ["bad", "checks failing"],
  ERROR: ["bad", "checks errored"],
  PENDING: ["warn", "checks running"],
  EXPECTED: ["warn", "checks waiting"],
};
const REVIEW = {
  APPROVED: ["ok", "approved"],
  CHANGES_REQUESTED: ["bad", "changes requested"],
  REVIEW_REQUIRED: ["", "review required"],
};

function chip(text, tone, title) {
  const c = el("span", "wschip" + (tone ? " " + tone : ""), text);
  if (title) c.title = title;
  return c;
}

function prChips(pr) {
  const out = [];
  if (pr.state === "MERGED") out.push(chip("merged", "merged"));
  else if (pr.state === "CLOSED") out.push(chip("closed"));
  else {
    if (pr.draft) out.push(chip("draft"));
    if (CHECKS[pr.checks]) out.push(chip(CHECKS[pr.checks][1], CHECKS[pr.checks][0]));
    if (REVIEW[pr.review]) out.push(chip(REVIEW[pr.review][1], REVIEW[pr.review][0]));
    if (pr.mergeable === "CONFLICTING") out.push(chip("conflicts", "bad"));
  }
  return out;
}

const prAttention = (pr) =>
  pr.state === "OPEN" && (pr.checks === "FAILURE" || pr.checks === "ERROR" || pr.review === "CHANGES_REQUESTED" || pr.mergeable === "CONFLICTING");

/* --------------------------------------------------------------- board */

function drawBoard(host) {
  const prs = prIndex();
  const cols = new Map(COLUMNS.map((c) => [c.key, []]));
  for (const r of boardRuns()) if (matchesQuery(r)) cols.get(columnOf(r, prs)).push(r);
  for (const list of cols.values()) list.sort((a, b) => (b.updatedAt || 0) - (a.updatedAt || 0));

  const q = el("input", "wsq");
  q.type = "search";
  q.placeholder = "Filter cards…";
  q.value = S.q;
  q.oninput = () => {
    S.q = q.value;
    $("q").value = q.value;
    drawWorkspace();
    const n = $("wsView").querySelector(".wsq");
    n.focus();
    n.setSelectionRange(n.value.length, n.value.length);
  };
  wsHead(host, "Board", "Drag a card to set its status. Cards follow their session until you move them.", [q, refreshBtn(["pulls"])]);

  const board = el("div", "kanban");
  for (const c of COLUMNS) {
    const list = cols.get(c.key);
    const col = el("section", "kcol");
    col.dataset.col = c.key;
    const h = el("header", "kcolhead");
    h.appendChild(el("span", "kdot " + c.key));
    h.appendChild(el("span", "klabel", c.label));
    h.appendChild(el("span", "kcount", String(list.length)));
    h.title = c.hint;
    col.appendChild(h);
    const body = el("div", "kbody");
    if (c.key === "backlog") body.appendChild(newCardBox());
    const shown = c.key === "done" && !W.showAllDone ? list.slice(0, 25) : list;
    for (const r of shown) body.appendChild(card(r, prs));
    if (shown.length < list.length) {
      const more = el("button", "kmore", `Show ${list.length - shown.length} more`);
      more.onclick = () => {
        W.showAllDone = true;
        drawWorkspace();
      };
      body.appendChild(more);
    }
    if (!list.length && c.key !== "backlog") body.appendChild(el("div", "kempty", "Drop a card here"));
    col.appendChild(body);
    wireDrop(col);
    board.appendChild(col);
  }
  host.appendChild(board);
}

function card(r, prs) {
  const c = el("article", "kcard");
  c.draggable = true;
  c.dataset.id = r.runId;
  if (isAwaiting(r)) c.classList.add("hot");
  if (isLive(r)) c.classList.add("live");

  const top = el("div", "kc-top");
  top.appendChild(el("span", "kc-kind " + (r.kind === "task" ? "task" : "slack"), r.kind === "task" ? "Task" : "Slack"));
  const key = runIssueKey(r);
  if (key) top.appendChild(el("span", "kc-key", key));
  top.appendChild(el("span", "spacer"));
  if (r.board) {
    const pin = el("button", "kc-pin", "pinned");
    pin.title = "You placed this card. Click to let it follow its session again.";
    pin.onclick = (e) => {
      e.stopPropagation();
      moveCard(r.runId, "");
    };
    top.appendChild(pin);
  }
  top.appendChild(el("span", "kc-when", agoOf(r.updatedAt || r.createdAt)));
  c.appendChild(top);

  c.appendChild(el("div", "kc-title", runTitle(r)));
  const snippet = r.kind === "task" ? r.lastText || r.text : slackPlain(r.text || "");
  if (snippet) c.appendChild(el("div", "kc-text", String(snippet).trim().slice(0, 180)));
  const said = r.task && ((r.task.declared && r.task.declared.text) || r.task.phase);
  if (said) c.appendChild(el("div", "kc-status", said));

  const foot = el("div", "kc-foot");
  const st = r.task && r.task.status;
  if (isAwaiting(r)) foot.appendChild(chip(r.askedFor ? "needs you" : "waiting on you", "warn", r.askedFor || ""));
  else if (isLive(r)) foot.appendChild(chip("running", "live"));
  else if (st && STATUS_LABEL[st]) foot.appendChild(chip(STATUS_LABEL[st], (STATUS_TONE[st] || "").replace("hs-", "")));
  else if (r.action && r.action !== "pending") foot.appendChild(chip(r.action));
  const pr = r.prUrl ? prs.get(normUrl(r.prUrl)) : null;
  if (r.prUrl) {
    const m = r.prUrl.match(/\/pull\/(\d+)/);
    foot.appendChild(link(r.prUrl, "PR #" + (m ? m[1] : "?"), "wschip pr"));
    if (pr) for (const x of prChips(pr).slice(0, 2)) foot.appendChild(x);
  }
  for (const x of portChips(serversForRun(r))) foot.appendChild(x);
  if (r.cost) foot.appendChild(el("span", "kc-cost", money(r.cost)));
  c.appendChild(foot);

  c.onclick = () => openRun(r.runId);
  c.addEventListener("dragstart", (e) => {
    W.drag = r.runId;
    e.dataTransfer.effectAllowed = "move";
    e.dataTransfer.setData("text/plain", r.runId);
    requestAnimationFrame(() => c.classList.add("dragging"));
  });
  c.addEventListener("dragend", () => {
    c.classList.remove("dragging");
    W.drag = "";
    drawWorkspace();
  });
  return c;
}

function wireDrop(col) {
  col.addEventListener("dragover", (e) => {
    if (!W.drag) return;
    e.preventDefault();
    e.dataTransfer.dropEffect = "move";
    col.classList.add("over");
  });
  col.addEventListener("dragleave", (e) => {
    if (!col.contains(e.relatedTarget)) col.classList.remove("over");
  });
  col.addEventListener("drop", (e) => {
    e.preventDefault();
    col.classList.remove("over");
    const id = e.dataTransfer.getData("text/plain") || W.drag;
    W.drag = "";
    const r = S.runs.find((x) => x.runId === id);
    if (!r) return;
    const target = col.dataset.col;
    // Dropping where it would land on its own unpins it rather than pinning it.
    moveCard(id, target === autoColumn(r, prIndex()) ? "" : target);
  });
}

async function moveCard(id, column) {
  const r = S.runs.find((x) => x.runId === id);
  if (r) r.board = column;
  drawWorkspace();
  try {
    await api(`/api/runs/${encodeURIComponent(id)}/board`, { method: "POST", body: JSON.stringify({ column }) });
  } catch (e) {
    toast(e.message, true);
  }
}

function newCardBox() {
  const box = el("form", "knew");
  const ta = el("textarea");
  ta.rows = 2;
  ta.placeholder = "New task: describe it and press ⌘↵ to start a session…";
  const go = el("button", "btn primary", "Start");
  go.type = "submit";
  box.appendChild(ta);
  box.appendChild(go);
  const submit = async (e) => {
    e && e.preventDefault();
    const text = ta.value.trim();
    if (!text) return;
    go.disabled = true;
    try {
      const out = await api("/api/tasks", { method: "POST", body: JSON.stringify({ brief: text }) });
      ta.value = "";
      toast(out.state === "queued" ? "Queued: every worker slot is busy." : "Session started.");
    } catch (err) {
      toast(err.message, true);
    }
    go.disabled = false;
  };
  box.onsubmit = submit;
  ta.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) submit(e);
  });
  return box;
}

/* ----------------------------------------------------------------- PRs */

function sessionForPr(pr) {
  const u = normUrl(pr.url);
  return S.runs.find((r) => normUrl(r.prUrl) === u) || S.runs.find((r) => r.task && r.task.branch && r.task.branch === pr.branch) || null;
}

function askOrchestrator(text) {
  return api(`/api/runs/${ORCH}/followup`, { method: "POST", body: JSON.stringify({ text, queue: true }) })
    .then((out) => {
      toast(out.queued ? "Queued for the orchestrator." : "Sent to the orchestrator.");
      openRun(ORCH);
    })
    .catch((e) => toast(e.message, true));
}

function prActions(pr, mine) {
  const box = el("div", "wsacts");
  const s = sessionForPr(pr);
  if (s) {
    const b = el("button", "btn", "Open session");
    b.onclick = () => openRun(s.runId);
    box.appendChild(b);
  }
  if (pr.state === "OPEN") {
    const acts = mine
      ? [
          (pr.checks === "FAILURE" || pr.checks === "ERROR") && ["Fix CI", `Spawn a worker for ${pr.url} (branch ${pr.branch}): checks are failing. Check out the existing PR branch, find why CI fails, fix it and push to the same branch.`],
          pr.comments > 0 && ["Resolve comments", `Spawn a worker for ${pr.url} (branch ${pr.branch}): check out the existing PR branch and run /resolve on it.`],
          pr.mergeable === "CONFLICTING" && ["Fix conflicts", `Spawn a worker for ${pr.url} (branch ${pr.branch}): check out the PR branch, merge the base branch in, resolve the conflicts, verify, and push.`],
        ]
      : [["Review", `Spawn a worker to review ${pr.url}: run /review on it and report findings. Do not approve or merge.`]];
    for (const a of acts.filter(Boolean)) {
      const b = el("button", "btn", a[0]);
      b.title = "Ask the orchestrator to spawn a worker for this";
      b.onclick = (e) => {
        e.stopPropagation();
        askOrchestrator(a[1]);
      };
      box.appendChild(b);
    }
  }
  return box;
}

function prRow(pr, mine) {
  const row = el("div", "wsrow");
  const icon = el("span", "prstate " + (pr.state === "OPEN" ? (pr.draft ? "draft" : "open") : pr.state.toLowerCase()));
  row.appendChild(icon);
  const main = el("div", "wsmain");
  const t = el("div", "wsrowtitle");
  t.appendChild(link(pr.url, pr.title));
  main.appendChild(t);
  const meta = el("div", "wsmeta");
  meta.appendChild(el("span", "mono", `${pr.repo.split("/").pop()}#${pr.number}`));
  if (!mine) meta.appendChild(el("span", null, pr.author));
  meta.appendChild(el("span", "mono dim", pr.branch));
  const diff = el("span", "diffstat");
  diff.appendChild(el("span", "add", "+" + pr.additions));
  diff.appendChild(el("span", "del", "−" + pr.deletions));
  meta.appendChild(diff);
  if (pr.comments) meta.appendChild(el("span", null, `${pr.comments} comments`));
  meta.appendChild(el("span", null, agoIso(pr.mergedAt || pr.updatedAt)));
  main.appendChild(meta);
  const chips = el("div", "wschips");
  for (const c of prChips(pr)) chips.appendChild(c);
  if (pr.issueKey) chips.appendChild(issueChip(pr.issueKey));
  if (pr.state === "OPEN") for (const x of portChips(serversForBranch(pr.branch))) chips.appendChild(x);
  main.appendChild(chips);
  row.appendChild(main);
  row.appendChild(prActions(pr, mine));
  return row;
}

function issueChip(key) {
  const issue = W.linear && W.linear.issues && W.linear.issues.find((i) => i.key === key);
  if (issue) return link(issue.url, key, "wschip issue");
  return chip(key, "issue");
}

function section(host, title, rows, empty) {
  const s = el("section", "wssec");
  const h = el("h3", null, title);
  h.appendChild(el("span", "n", String(rows.length)));
  s.appendChild(h);
  if (!rows.length) s.appendChild(el("div", "wsnone", empty));
  for (const r of rows) s.appendChild(r);
  host.appendChild(s);
  return s;
}

function drawPulls(host) {
  const p = W.pulls;
  wsHead(host, "Pull requests", p ? `as ${p.login} · updated ${agoOf(p.at / 1000)}` : "via gh", [refreshBtn(["pulls"])]);
  errorNote(host, "pulls");
  if (!p) return host.appendChild(el("div", "wsnone pad", W.loading.pulls ? "Loading from GitHub…" : "Nothing loaded yet."));
  const body = el("div", "wsbody");
  const attn = p.mine.filter(prAttention);
  section(body, "Needs attention", attn.map((x) => prRow(x, true)), "Nothing failing, conflicting or sent back.");
  section(body, "Review requested", p.review.map((x) => prRow(x, false)), "No one is waiting on your review.");
  section(body, "Your open PRs", p.mine.filter((x) => !prAttention(x)).map((x) => prRow(x, true)), "No other open PRs.");
  section(body, "Merged in the last 14 days", p.merged.map((x) => prRow(x, true)), "Nothing merged recently.");
  host.appendChild(body);
}

/* -------------------------------------------------------------- Linear */

const STATE_ORDER = { started: 0, unstarted: 1, triage: 2, backlog: 3, completed: 4 };
const PRIORITY = ["", "urgent", "high", "medium", "low"];

function sessionForIssue(issue) {
  return S.runs.find((r) => r.kind !== "orchestrator" && runIssueKey(r) === issue.key) || null;
}

async function startIssue(issue, btn) {
  btn.disabled = true;
  const brief = [
    `Linear issue ${issue.key}: ${issue.title}`,
    issue.url,
    "",
    issue.description || "(no description)",
    "",
    "Read the issue and its comments through the Linear connector before starting. Build it, verify it, and open a PR that references the issue key.",
  ].join("\n");
  try {
    const out = await api("/api/tasks", { method: "POST", body: JSON.stringify({ title: `${issue.key} ${issue.title}`, brief, branch: issue.branch || undefined }) });
    toast(out.state === "queued" ? "Queued: every worker slot is busy." : `Session started on ${out.branch}.`);
    openRun(out.taskId);
  } catch (e) {
    // Linear's branch already exists locally: let the server name a fresh one.
    if (/already exists/.test(e.message) && issue.branch) return startIssue({ ...issue, branch: "" }, btn);
    toast(e.message, true);
  }
  btn.disabled = false;
}

function issueRow(issue, prsByKey) {
  const row = el("div", "wsrow");
  const pri = el("span", "pri p" + (issue.priority || 0));
  pri.title = issue.priorityLabel || "No priority";
  row.appendChild(pri);
  const main = el("div", "wsmain");
  const t = el("div", "wsrowtitle");
  t.appendChild(el("span", "mono key", issue.key));
  t.appendChild(link(issue.url, issue.title));
  main.appendChild(t);
  const meta = el("div", "wsmeta");
  const st = el("span", "lstate");
  const dot = el("span", "ldot");
  dot.style.background = issue.stateColor || "var(--muted)";
  st.appendChild(dot);
  st.appendChild(document.createTextNode(issue.state));
  meta.appendChild(st);
  if (issue.project) meta.appendChild(el("span", null, issue.project));
  if (issue.cycle) meta.appendChild(el("span", null, "Cycle " + issue.cycle));
  meta.appendChild(el("span", null, agoIso(issue.updatedAt)));
  main.appendChild(meta);
  const chips = el("div", "wschips");
  for (const l of issue.labels) {
    const c = chip(l.name, "label");
    c.style.setProperty("--lc", l.color);
    chips.appendChild(c);
  }
  for (const pr of prsByKey.get(issue.key) || []) {
    chips.appendChild(link(pr.url, `PR #${pr.number}`, "wschip pr"));
    for (const c of prChips(pr).slice(0, 2)) chips.appendChild(c);
  }
  main.appendChild(chips);
  row.appendChild(main);

  const acts = el("div", "wsacts");
  const s = sessionForIssue(issue);
  if (s) {
    const b = el("button", "btn", "Open session");
    b.onclick = () => openRun(s.runId);
    acts.appendChild(b);
  } else if (issue.stateType !== "completed") {
    const b = el("button", "btn primary", "Start session");
    b.title = "Spawn a Claude worker on this issue in its own worktree";
    b.onclick = () => startIssue(issue, b);
    acts.appendChild(b);
  }
  row.appendChild(acts);
  return row;
}

function prsByIssue() {
  const m = new Map();
  if (!W.pulls) return m;
  for (const pr of [...W.pulls.mine, ...W.pulls.merged]) if (pr.issueKey) m.set(pr.issueKey, [...(m.get(pr.issueKey) || []), pr]);
  return m;
}

function drawLinear(host) {
  const l = W.linear;
  wsHead(host, "Linear", l && l.configured ? `assigned to ${l.viewer} · updated ${agoOf(l.at / 1000)}` : "", [refreshBtn(["linear"])]);
  errorNote(host, "linear");
  if (!l) return host.appendChild(el("div", "wsnone pad", W.loading.linear ? "Loading from Linear…" : "Nothing loaded yet."));
  if (!l.configured) return host.appendChild(el("div", "wsnone pad", "Set LINEAR_API_KEY in .env and restart to see your issues here."));
  const groups = new Map();
  const sorted = [...l.issues].sort(
    (a, b) => (STATE_ORDER[a.stateType] ?? 9) - (STATE_ORDER[b.stateType] ?? 9) || b.statePos - a.statePos || (a.priority || 9) - (b.priority || 9),
  );
  for (const i of sorted) groups.set(i.state, [...(groups.get(i.state) || []), i]);
  const prs = prsByIssue();
  const body = el("div", "wsbody");
  for (const [state, issues] of groups) {
    const ordered = [...issues].sort((a, b) => (a.priority || 9) - (b.priority || 9) || Date.parse(b.updatedAt) - Date.parse(a.updatedAt));
    section(body, state, ordered.map((i) => issueRow(i, prs)), "");
  }
  if (!groups.size) body.appendChild(el("div", "wsnone pad", "Nothing assigned to you in the last 30 days."));
  host.appendChild(body);
}

/* ------------------------------------------------------------ overview */

function tile(label, value, tone, onclick, sub) {
  const t = el("button", "wstile" + (tone ? " " + tone : ""));
  t.appendChild(el("div", "v", String(value)));
  t.appendChild(el("div", "l", label));
  if (sub) t.appendChild(el("div", "s", sub));
  if (onclick) t.onclick = onclick;
  return t;
}

function miniRun(r, prs) {
  const row = el("button", "wsmini");
  row.appendChild(el("span", "kdot " + columnOf(r, prs)));
  row.appendChild(el("span", "t", runTitle(r)));
  const sub = isAwaiting(r) ? r.askedFor || "waiting on you" : [r.channel, (r.lastText || slackPlain(r.text || "")).trim()].filter(Boolean).join(" · ");
  row.appendChild(el("span", "s", sub.slice(0, 140)));
  row.appendChild(el("span", "w", agoOf(r.updatedAt || r.createdAt)));
  row.onclick = () => openRun(r.runId);
  return row;
}

function drawHome(host) {
  const prs = prIndex();
  const runs = boardRuns();
  const by = (k) => runs.filter((r) => columnOf(r, prs) === k);
  const live = runs.filter(isLive);
  const needs = by("needs");
  const p = W.pulls;
  const l = W.linear;
  const decisions = (H.inbox.counts && H.inbox.counts.decisions) || 0;

  const hour = new Date().getHours();
  wsHead(host, hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening", "Everything in flight across Claude, GitHub, Linear and Slack.", [refreshBtn(["pulls", "linear"])]);

  const tiles = el("div", "wstiles");
  tiles.appendChild(tile("Sessions running", live.length, live.length ? "live" : "", () => setView("board"), `${(H.tasks && H.tasks.working) || live.length} workers`));
  tiles.appendChild(tile("Need you", needs.length + decisions, needs.length + decisions ? "warn" : "", () => (decisions ? openInbox("decisions") : setView("board")), `${decisions} decisions in the inbox`));
  tiles.appendChild(tile("Open PRs", p ? p.mine.length : "–", "", () => setView("prs"), p ? `${p.mine.filter(prAttention).length} need attention` : ""));
  tiles.appendChild(tile("Reviews asked of you", p ? p.review.length : "–", p && p.review.length ? "warn" : "", () => setView("prs")));
  const inProg = l && l.issues ? l.issues.filter((i) => i.stateType === "started").length : "–";
  const todo = l && l.issues ? l.issues.filter((i) => i.stateType === "unstarted").length : 0;
  tiles.appendChild(tile("Linear in progress", inProg, "", () => setView("linear"), l && l.issues ? `${todo} to do` : ""));
  tiles.appendChild(tile("Spent today", S.cost ? money(S.cost.today || 0) : "$0", "", () => openPanel("spend")));
  host.appendChild(tiles);

  const grid = el("div", "wsgrid");
  const col1 = el("div", "wscol");
  const pane = (title, rows, empty, more) => {
    const s = el("section", "wspane");
    const h = el("header");
    h.appendChild(el("h3", null, title));
    h.appendChild(el("span", "spacer"));
    if (more) {
      const b = el("button", "linkbtn", more[0]);
      b.onclick = more[1];
      h.appendChild(b);
    }
    s.appendChild(h);
    if (!rows.length) s.appendChild(el("div", "wsnone", empty));
    for (const r of rows) s.appendChild(r);
    return s;
  };
  col1.appendChild(pane("Needs you", needs.slice(0, 8).map((r) => miniRun(r, prs)), "Nothing is waiting on you.", ["Board", () => setView("board")]));
  col1.appendChild(pane("Running now", live.slice(0, 8).map((r) => miniRun(r, prs)), "No session is working right now.", ["Orchestrator", () => openRun(ORCH)]));
  const svRows = servers().map((sv) => {
    const row = el("div", "wsmini static");
    row.appendChild(el("span", "kdot doing"));
    const t = el("span", "t");
    for (const x of portChips([sv])) t.appendChild(x);
    t.appendChild(document.createTextNode(" " + sv.cwd.split("/").slice(-3).join("/")));
    row.appendChild(t);
    row.appendChild(el("span", "w", sv.command));
    row.appendChild(el("span", "s", sv.cwd.replace(/^\/Users\/[^/]+/, "~")));
    return row;
  });
  col1.appendChild(pane("Dev servers", svRows, "No dev server is listening in your folders."));
  col1.appendChild(pane("Slack threads", runs.filter((r) => r.kind !== "task").slice(0, 6).map((r) => miniRun(r, prs)), "Paste a Slack thread link in the box above to start one."));
  grid.appendChild(col1);

  const col2 = el("div", "wscol");
  const prRows = p ? [...p.mine.filter(prAttention), ...p.review, ...p.mine.filter((x) => !prAttention(x))].slice(0, 8).map((x) => prRow(x, x.author === p.login)) : [];
  col2.appendChild(pane("Pull requests", prRows, W.loading.pulls ? "Loading…" : W.err.pulls || "No open PRs.", ["All PRs", () => setView("prs")]));
  const issues = l && l.issues ? l.issues.filter((i) => i.stateType === "started" || i.stateType === "unstarted").sort((a, b) => (STATE_ORDER[a.stateType] ?? 9) - (STATE_ORDER[b.stateType] ?? 9) || (a.priority || 9) - (b.priority || 9)) : [];
  col2.appendChild(pane("Linear", issues.slice(0, 8).map((i) => issueRow(i, prsByIssue())), W.loading.linear ? "Loading…" : W.err.linear || "Nothing in progress or to do.", ["All issues", () => setView("linear")]));
  grid.appendChild(col2);
  host.appendChild(grid);
}

/* ------------------------------------------------------------- palette */

const _wsPaletteItems = paletteItems;
paletteItems = function (q) {
  const views = VIEWS.map(([k, label, n]) => ({ label: `Go to ${label}`, sub: `⌘${n}`, run: () => setView(k) }));
  const s = String(q || "").toLowerCase();
  const base = _wsPaletteItems(q);
  const picked = s ? views.filter((v) => v.label.toLowerCase().includes(s)) : views.slice(0, 2);
  const hits = (W.hits.get(s) || [])
    .filter((h) => !base.some((b) => b.runId === h.runId))
    .map((h) => ({ label: `${h.who} — ${h.snippet}`, sub: h.role === "thread" ? "thread" : "transcript", runId: h.runId, run: () => openRun(h.runId) }));
  return [...picked, ...base, ...hits].slice(0, 20);
};

let searchTimer = null;
const _wsRenderPalette = renderPalette;
renderPalette = function (q) {
  _wsRenderPalette(q);
  const s = String(q || "").trim().toLowerCase();
  if (s.length < 3 || W.hits.has(s)) return;
  clearTimeout(searchTimer);
  searchTimer = setTimeout(async () => {
    try {
      W.hits.set(s, (await api(`/api/search?q=${encodeURIComponent(s)}`)).hits);
    } catch {
      return;
    }
    if ($("paletteInput").value.trim().toLowerCase() === s) _wsRenderPalette($("paletteInput").value);
  }, 180);
};

/* ---------------------------------------------------------------- keys */

document.addEventListener("keydown", (e) => {
  const typing = /^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement.tagName) || document.activeElement.isContentEditable;
  const n = Number(e.key);
  if (!(n >= 1 && n <= VIEWS.length)) return;
  if ((e.metaKey || e.ctrlKey) && !e.shiftKey && !e.altKey) {
    e.preventDefault();
    setView(VIEWS[n - 1][0]);
  } else if (!typing && !e.metaKey && !e.ctrlKey && !e.altKey) {
    e.preventDefault();
    setView(VIEWS[n - 1][0]);
  }
});

// Slack work starts from the top box in any view: the new chat opens in Chats.
window.addEventListener("hashchange", () => {
  const h = location.hash.slice(1);
  if (VIEWS.some(([k]) => k === h) && h !== W.view) setView(h, { push: false });
});

// Keep the live views fresh while they're on screen.
setInterval(() => {
  if (W.view !== "chats" && !document.hidden) refreshSources(false);
}, 60_000);
// Dev servers come and go faster than PRs do.
setInterval(() => {
  if ((W.view === "home" || W.view === "board") && !document.hidden) loadSource("ports", false);
}, 15_000);

(function bootWorkspace() {
  refreshSources(false);
  const h = location.hash.slice(1);
  const saved = localStorage.getItem("bridge-view");
  if (VIEWS.some(([k]) => k === h)) setView(h, { push: false });
  else if (!h && saved && saved !== "chats") setView(saved, { push: false });
  else paintViewNav();
  const _set = setView;
  setView = function (v, o) {
    _set(v, o);
    localStorage.setItem("bridge-view", W.view);
  };
})();
