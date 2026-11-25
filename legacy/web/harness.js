/* bridge — the harness layer of the dashboard.
 *
 * Loaded after app.js and built on its globals (S, $, el, api, md, toast,
 * openRun, ...). It wraps a handful of app.js's render functions rather than
 * editing them, so the chat client underneath stays exactly what it was:
 *
 *   - the Orchestrator chat, pinned at the top of the sidebar
 *   - task rows carrying their report status
 *   - the Inbox view: decisions waiting on you, to-dos, task status and
 *     recent activity
 *   - a task panel in the inspector: report TL;DR, worktree, relaunch, cleanup
 *   - relay / harness messages drawn as what they are, not as your words
 *   - a free-text top box: anything that isn't a Slack link goes to the
 *     orchestrator, which writes the brief and spawns the worker
 *   - Harness settings: mode, relay, caps, stall time, write policy
 */

const ORCH = "orchestrator";
const H = {
  inbox: { decisions: [], todos: [], counts: { decisions: 0, todos: 0 }, mode: "normal" },
  task: null, // GET /api/tasks/:id for the open chat
  taskFor: "",
  events: [],
};

const STATUS_LABEL = {
  "ready-for-review": "ready",
  "needs-input": "needs input",
  blocked: "blocked",
  "pushed-follow-up": "pushed",
  "idle-without-report": "no report",
  "worker-stalled": "stalled",
  "worker-gone": "lost",
  "usage-limit": "limit",
  queued: "queued",
  working: "working",
  cleaned: "cleaned",
  stopped: "stopped",
  unknown: "reported",
};
// Own tone classes (hs-*): app.css's `.badge.waiting` is laid out as a pip.
const STATUS_TONE = {
  "ready-for-review": "hs-good",
  "pushed-follow-up": "hs-good",
  "needs-input": "hs-warn",
  blocked: "hs-bad",
  "idle-without-report": "hs-warn",
  "worker-stalled": "hs-warn",
  "worker-gone": "hs-bad",
  "usage-limit": "hs-bad",
  queued: "hs-accent",
  working: "hs-warn",
};

const isSlackLink = (s) => /^https:\/\/[^/]*slack\.com\/archives\//i.test(String(s).trim());
const tomorrow = () => new Date(Date.now() + 86400000).toISOString().slice(0, 10);

/* ------------------------------------------------------------- messages */

const _renderMessage = renderMessage;
renderMessage = function (m, run) {
  if (m.role !== "relay" && m.role !== "harness") return _renderMessage(m, run);
  const node = el("div", "msg hmsg " + m.role);
  node.style.paddingLeft = "45px";
  const card = el("div", "hcard");
  const head = el("div", "hh");
  head.appendChild(el("span", "lbl", m.role === "relay" ? "harness → orchestrator" : "harness → worker"));
  head.appendChild(el("span", "t", clock(m.ts)));
  card.appendChild(head);
  const body = el("div", "hb");
  body.innerHTML = md(String(m.text || "").replace(/^\[harness\]\s*/, ""));
  card.appendChild(body);
  node.appendChild(card);
  return node;
};

/* -------------------------------------------------------------- sidebar */

const _chatRow = chatRow;
chatRow = function (r) {
  const row = _chatRow(r);
  if (r.kind === "task") {
    const sb = row.querySelector(".startbtn");
    if (sb) sb.remove(); // a task starts at spawn, or from the queue
  }
  const st = r.task && r.task.status;
  if (st && STATUS_LABEL[st] && !isAwaiting(r) && !isLive(r)) {
    const b = row.querySelector(".r3 .badge");
    if (b) {
      b.className = "badge " + (STATUS_TONE[st] || "");
      b.textContent = STATUS_LABEL[st];
    }
  }
  if (r.kind === "task" && r.task && r.task.branch) {
    const chan = row.querySelector(".r3 .chan");
    if (chan && !isAwaiting(r)) chan.textContent = r.task.branch;
    else if (!chan) row.querySelector(".r3").appendChild(el("span", "chan", r.task.branch));
  }
  return row;
};

function orchestratorRow() {
  const r = S.runs.find((x) => x.runId === ORCH);
  const btn = el("button", "chatrow orchrow");
  btn.dataset.id = ORCH;
  btn.setAttribute("aria-current", String(S.currentId === ORCH));
  const r1 = el("div", "r1");
  r1.appendChild(el("span", "who", "Orchestrator"));
  if (r && isAwaiting(r)) r1.appendChild(el("span", "waiting"));
  else if (r && r.unread && S.currentId !== ORCH) r1.appendChild(el("span", "unread"));
  r1.appendChild(el("span", "when", r ? agoOf(r.updatedAt) : ""));
  btn.appendChild(r1);
  const live = r && isLive(r);
  const n = H.inbox.counts.decisions || 0;
  btn.appendChild(
    el(
      "div",
      "snippet",
      live ? "working…" : r && r.lastText && r.lastRole === "assistant" ? r.lastText : "Hand it work; it spawns and watches workers."
    )
  );
  const r3 = el("div", "r3");
  r3.appendChild(el("span", "badge " + (live ? "hs-warn" : "hs-good"), live ? "running" : H.inbox.mode));
  if (n) r3.appendChild(el("span", "chan", `${n} waiting on you`));
  btn.appendChild(r3);
  btn.onclick = (e) => {
    e.stopPropagation();
    openRun(ORCH);
  };
  return btn;
}

const _renderSidebar = renderSidebar;
renderSidebar = function () {
  const all = S.runs;
  S.runs = all.filter((r) => r.runId !== ORCH);
  try {
    _renderSidebar();
  } finally {
    S.runs = all;
  }
  const list = $("chatlist");
  const pin = el("div", "pinned");
  pin.appendChild(orchestratorRow());
  list.prepend(pin);
};

const _paintTitle = paintTitle;
paintTitle = function () {
  _paintTitle();
  const n = H.inbox.counts.decisions || 0;
  if (n && !/Needs you/.test(document.title)) document.title = `(${n}) Inbox · Bridge`;
};

/* ------------------------------------------------------------ inspector */

async function loadTask(id, force) {
  if (!force && H.taskFor === id && H.task) return H.task;
  try {
    const t = await api(`/api/tasks/${encodeURIComponent(id)}`);
    H.task = t;
    H.taskFor = id;
  } catch {
    H.task = null;
    H.taskFor = id;
  }
  return H.task;
}

const _renderInspector = renderInspector;
renderInspector = function () {
  const run = S.run;
  if (!run) return _renderInspector();
  if (run.kind === "orchestrator") return renderOrchInspector();
  if (run.kind === "task") {
    $("inspTitle").textContent = "Task";
    $("inspSub").textContent = run.runId;
    $("inspBody").innerHTML = "";
  } else {
    _renderInspector(); // Slack runs keep their pipeline stages
  }
  const host = el("div", "taskpanel");
  $("inspBody").appendChild(host);
  const draw = (t) => {
    if (S.run !== run) return;
    host.innerHTML = "";
    if (!t) {
      if (run.kind === "task") host.appendChild(el("div", "insp-empty", "No task folder for this chat."));
      return;
    }
    drawTask(host, run, t);
  };
  if (H.taskFor === run.runId && H.task) draw(H.task);
  loadTask(run.runId, true).then(draw);
};

function drawTask(host, run, t) {
  const m = t.meta || {};
  const p = t.parsed;
  const live = isLive(run);
  const st = live ? "working" : m.status || (p && p.status) || "";

  const top = el("div", "tp-status");
  top.appendChild(el("span", "badge " + (STATUS_TONE[st] || ""), STATUS_LABEL[st] || st || "new"));
  if (m.phase) top.appendChild(el("span", "tp-phase", m.phase));
  if (m.declared && m.declared.state === "waiting") top.appendChild(el("span", "tp-phase", `waiting: ${m.declared.text}`));
  host.appendChild(top);

  if (p && p.tldr) {
    const tl = el("div", "tp-tldr");
    tl.innerHTML = md(p.tldr);
    host.appendChild(tl);
  }

  const facts = el("dl", "tp-facts");
  const fact = (k, v, mono) => {
    if (!v) return;
    facts.appendChild(el("dt", null, k));
    const dd = el("dd", mono ? "mono" : "", v);
    dd.title = v;
    facts.appendChild(dd);
  };
  fact("Branch", m.branch, true);
  fact("Worktree", m.worktree, true);
  if (t.worktree && t.worktree.exists) {
    fact("State", [t.worktree.dirty ? `${t.worktree.dirtyFiles} uncommitted` : "clean", t.worktree.unpushed ? `${t.worktree.unpushed} unpushed` : "pushed"].join(" · "));
  }
  fact("Repo", m.repo, true);
  host.appendChild(facts);

  const pr = [p && p.fields && p.fields.pr, m.prUrl].find((u) => /^https?:\/\//.test(u || ""));
  if (pr) {
    const a = el("a", "linkchip", "Pull request");
    a.href = pr;
    a.target = "_blank";
    a.rel = "noopener noreferrer";
    host.appendChild(a);
  }

  if (t.report) {
    const det = el("details", "tp-report");
    det.appendChild(el("summary", null, "Report"));
    const b = el("div", "text");
    b.innerHTML = md(t.report.replace(/^---[\s\S]*?\n---\n/, ""));
    det.appendChild(b);
    host.appendChild(det);
  }
  if (t.brief) {
    const det = el("details", "tp-report");
    det.appendChild(el("summary", null, "Brief"));
    const b = el("div", "text");
    b.innerHTML = md(t.brief);
    det.appendChild(b);
    host.appendChild(det);
  }

  const acts = el("div", "insp-actions");
  if (!live && !["cleaned"].includes(m.status) && (run.sessionId || run.kind === "task")) {
    const rl = el("button", "btn", m.status === "queued" ? "Start now" : "Relaunch");
    rl.title = "Resume this worker's session where it left off";
    rl.onclick = async () => {
      rl.disabled = true;
      try {
        await api(`/api/tasks/${encodeURIComponent(run.runId)}/relaunch`, { method: "POST", body: JSON.stringify({}) });
        toast("Relaunched.");
      } catch (e) {
        toast(e.message, true);
      }
      rl.disabled = false;
    };
    acts.appendChild(rl);
  }
  if (!live && m.worktree && m.status !== "cleaned") {
    const cl = el("button", "btn", "Clean up worktree");
    cl.title = "Remove the worktree and keep the branch. Refuses if there is uncommitted or unpushed work.";
    cl.onclick = () => cleanupTask(run.runId, cl);
    acts.appendChild(cl);
  }
  if (acts.children.length) host.appendChild(acts);
}

async function cleanupTask(id, btn) {
  btn.disabled = true;
  try {
    const out = await api(`/api/tasks/${encodeURIComponent(id)}/cleanup`, { method: "POST", body: JSON.stringify({}) });
    toast(`Worktree removed; branch ${out.branch || ""} kept.`);
  } catch (e) {
    if (/refusing/.test(e.message)) {
      const yes = await askConfirm({
        title: "Discard work in this worktree?",
        body: e.message.replace(/ Push or commit first.*$/, "") + " Cleaning up anyway deletes it for good. The branch is kept.",
        confirm: "Delete anyway",
      });
      if (yes) {
        try {
          await api(`/api/tasks/${encodeURIComponent(id)}/cleanup`, { method: "POST", body: JSON.stringify({ force: true }) });
          toast("Worktree removed.");
        } catch (e2) {
          toast(e2.message, true);
        }
      }
    } else toast(e.message, true);
  }
  btn.disabled = false;
  if (S.run && S.run.runId === id) loadTask(id, true).then(() => renderInspector());
}

function renderOrchInspector() {
  $("inspTitle").textContent = "Orchestrator";
  $("inspSub").textContent = isLive(S.run) ? "working…" : "idle";
  const body = $("inspBody");
  body.innerHTML = "";

  body.appendChild(modeSwitch());

  const sum = el("div", "tp-facts-wrap");
  api("/api/tasks")
    .then((out) => {
      const open = out.tasks.filter((t) => !["cleaned"].includes(t.status));
      const live = open.filter((t) => t.live).length;
      const queued = open.filter((t) => t.status === "queued").length;
      sum.innerHTML = "";
      const dl = el("dl", "tp-facts");
      for (const [k, v] of [
        ["Working", `${out.working} of ${out.harness.maxWorkers}`],
        ["Live jobs", String(live)],
        ["Queued", String(queued)],
        ["Waiting on you", String(H.inbox.counts.decisions || 0)],
        ["To-dos", String(H.inbox.counts.todos || 0)],
      ]) {
        dl.appendChild(el("dt", null, k));
        dl.appendChild(el("dd", null, v));
      }
      sum.appendChild(dl);
      const all = el("button", "btn ghost", "All tasks");
      all.onclick = () => openInbox("tasks");
      if (open.length) sum.appendChild(all);
    })
    .catch(() => {});
  body.appendChild(sum);

  // Spawning straight from a brief, for when you already know exactly what you
  // want and don't need the orchestrator to write it up.
  const det = el("details", "tp-report spawnbox");
  det.appendChild(el("summary", null, "Spawn a worker directly"));
  const ta = el("textarea");
  ta.rows = 6;
  ta.placeholder = "Goal, context, constraints, definition of done…";
  const repo = el("input", "mono");
  repo.value = (S.meta && S.meta.workdir) || "";
  repo.placeholder = "/abs/path/to/repo";
  const go = el("button", "btn primary", "Spawn");
  go.onclick = async () => {
    if (!ta.value.trim()) return ta.focus();
    go.disabled = true;
    try {
      const out = await api("/api/tasks", { method: "POST", body: JSON.stringify({ repo: repo.value.trim(), brief: ta.value }) });
      toast(out.state === "queued" ? "Queued: over the worker cap." : `Spawned on ${out.branch}.`);
      ta.value = "";
      openRun(out.taskId);
    } catch (e) {
      toast(e.message, true);
    }
    go.disabled = false;
  };
  det.appendChild(ta);
  det.appendChild(repo);
  det.appendChild(go);
  body.appendChild(det);
}

function modeSwitch() {
  const wrap = el("div", "modeswitch");
  const tip = {
    normal: "Every outcome is relayed to the orchestrator.",
    quiet: "Only what needs you (questions, blocks, stalls) is relayed.",
    away: "Nothing is relayed; it's held and briefed when you come back.",
  };
  for (const m of ["normal", "quiet", "away"]) {
    const b = el("button", "seg" + (H.inbox.mode === m ? " on" : ""), m);
    b.title = tip[m];
    b.onclick = async () => {
      try {
        await api("/api/mode", { method: "POST", body: JSON.stringify({ mode: m }) });
        H.inbox.mode = m;
        toast(`Mode: ${m}. ${tip[m]}`);
        refreshHarnessViews();
      } catch (e) {
        toast(e.message, true);
      }
    };
    wrap.appendChild(b);
  }
  return wrap;
}

/* ---------------------------------------------------------------- inbox */

// The Inbox is a view in the main pane: one tab per list, one row per item,
// and the selected row opens in place with its actions.

const IB_TABS = [
  ["decisions", "Needs you"],
  ["todos", "To-dos"],
  ["tasks", "Tasks"],
  ["activity", "Activity"],
];
Object.assign(H, { view: false, tab: "decisions", sel: "", since: "8h", tasks: null, catchup: null, prev: "", drafts: {}, items: [] });

function openInbox(tab) {
  if (!H.view) H.prev = S.currentId || "";
  H.view = true;
  if (tab) H.tab = tab;
  S.currentId = null;
  S.run = null;
  $("app").classList.add("reading");
  history.replaceState(null, "", "#inbox");
  renderChat();
  renderInspector();
  renderSidebar();
  renderInbox(true);
}

function closeInbox(restore) {
  H.view = false;
  $("inboxView").hidden = true;
  paintInboxBtn();
  if (restore && H.prev && S.runs.some((r) => r.runId === H.prev)) return openRun(H.prev);
  $("app").classList.remove("reading");
  history.replaceState(null, "", location.pathname);
  renderChat();
}

const _renderChat = renderChat;
renderChat = function () {
  _renderChat();
  $("inboxView").hidden = !H.view;
  if (H.view) {
    $("chatEmpty").style.display = "none";
    $("chatPane").style.display = "none";
  }
};

const _openRun = openRun;
openRun = function (id, o) {
  if (H.view && id) closeInbox(false);
  return _openRun(id, o);
};

function paintInboxBtn() {
  const n = (H.inbox.counts.decisions || 0) + (H.inbox.counts.todos || 0);
  const b = $("inboxCount");
  if (!b) return;
  b.textContent = n ? String(n) : "";
  b.hidden = !n;
  $("inboxBtn").classList.toggle("hot", (H.inbox.counts.decisions || 0) > 0);
  $("inboxBtn").classList.toggle("on", H.view);
}

const _renderPanels = renderPanels;
renderPanels = function () {
  _renderPanels();
  renderHarnessSettings();
};

const post = (p, body) => api(p, { method: "POST", body: JSON.stringify(body || {}) });

async function loadTab(tab) {
  try {
    if (tab === "tasks") H.tasks = await api("/api/tasks");
    if (tab === "activity") H.catchup = await api(`/api/catchup?since=${H.since}`);
  } catch (e) {
    toast(e.message, true);
  }
  if (H.view && H.tab === tab) drawInbox();
}

/** Redraw, and refetch whatever the open tab reads from the server. */
function renderInbox(fetch) {
  if (!H.view) return;
  drawInbox();
  if (fetch !== false && (H.tab === "tasks" || H.tab === "activity")) loadTab(H.tab);
}

function briefMe() {
  post(`/api/runs/${ORCH}/followup`, {
    text: `Catch me up on the last ${H.since}: what needs me first, then what moved. A few lines.`,
    queue: true,
  })
    .then(() => openRun(ORCH))
    .catch((e) => toast(e.message, true));
}

function drawInbox() {
  const host = $("inboxView");
  // A redraw (any SSE push) mustn't eat what you're typing.
  const a = document.activeElement;
  const refocus = a && host.contains(a) && a.dataset.draft;
  host.innerHTML = "";

  const head = el("div", "ibhead");
  head.appendChild(el("h2", null, "Inbox"));
  head.appendChild(modeSwitch());
  const brief = el("button", "btn", "Brief me");
  brief.title = `Ask the orchestrator for a few-line catch-up on the last ${H.since}`;
  brief.onclick = briefMe;
  head.appendChild(brief);
  const x = el("button", "iconbtn", "×");
  x.title = "Close (I)";
  x.onclick = () => closeInbox(true);
  head.appendChild(x);
  host.appendChild(head);

  const tabs = el("div", "ibtabs");
  const count = {
    decisions: H.inbox.counts.decisions || 0,
    todos: H.inbox.counts.todos || 0,
    tasks: H.tasks ? H.tasks.tasks.filter((t) => t.status !== "cleaned").length : "",
  };
  IB_TABS.forEach(([k, label]) => {
    const b = el("button", "ibtab" + (H.tab === k ? " on" : ""));
    b.appendChild(el("span", null, label));
    if (count[k]) b.appendChild(el("span", "n" + (k === "decisions" ? " hot" : ""), String(count[k])));
    b.onclick = () => {
      H.tab = k;
      H.sel = "";
      renderInbox(true);
    };
    tabs.appendChild(b);
  });
  host.appendChild(tabs);

  const list = el("div", "iblist");
  host.appendChild(list);
  H.items = [];
  ({ decisions: drawDecisions, todos: drawTodos, tasks: drawTasks, activity: drawActivity })[H.tab](list);

  if (refocus) {
    const n = host.querySelector(`[data-draft="${CSS.escape(refocus)}"]`);
    if (n) {
      n.focus();
      n.setSelectionRange(n.value.length, n.value.length);
    }
  }
}

/** One inbox row. Clicking selects it and opens `body` beneath; `open` jumps to the chat. */
function ibRow(list, { id, taskId, badge, tone, title, preview, at, body }) {
  H.items.push({ id, taskId });
  const sel = H.sel === id;
  const wrap = el("div", "ibitem" + (sel ? " sel" : ""));
  wrap.dataset.id = id;
  const row = el("button", "ibrow");
  if (badge) row.appendChild(el("span", "badge " + (tone || ""), badge));
  row.appendChild(el("span", "ti", title));
  row.appendChild(el("span", "pv", String(preview || "").replace(/\s+/g, " ")));
  row.appendChild(el("span", "when", at ? agoOf(at) : ""));
  row.onclick = () => {
    H.sel = sel ? "" : id;
    drawInbox();
  };
  wrap.appendChild(row);
  if (sel && body) {
    const d = el("div", "ibdetail");
    body(d);
    wrap.appendChild(d);
  }
  list.appendChild(wrap);
}

const draftBox = (key, placeholder) => {
  const ta = el("textarea");
  ta.rows = 2;
  ta.placeholder = placeholder;
  ta.dataset.draft = key;
  ta.value = H.drafts[key] || "";
  ta.oninput = () => (H.drafts[key] = ta.value);
  return ta;
};

const openChatBtn = (taskId) => {
  const b = el("button", "btn ghost", "Open chat");
  b.onclick = () => openRun(taskId);
  return b;
};

function drawDecisions(list) {
  if (!H.inbox.decisions.length) return list.appendChild(el("div", "ibempty", "Nothing waiting on you. Workers' questions and action requests land here."));
  for (const d of H.inbox.decisions) {
    ibRow(list, {
      id: d.id,
      taskId: d.taskId,
      badge: d.kind === "resume" ? "worker" : d.kind,
      tone: d.kind === "question" ? "hs-warn" : d.kind === "action" ? "hs-accent" : "hs-bad",
      title: d.title || d.taskId,
      preview: d.text,
      at: d.createdAt,
      body: (c) => decisionBody(c, d),
    });
  }
}

function decisionBody(c, d) {
  const b = el("div", "text");
  b.innerHTML = md(d.text);
  c.appendChild(b);
  const send = async (body, msg) => {
    try {
      await post(`/api/decisions/${encodeURIComponent(d.id)}`, body);
      delete H.drafts[d.id];
      H.sel = "";
      toast(msg);
    } catch (e) {
      toast(e.message, true);
    }
  };
  const row = el("div", "ibacts");
  if (d.kind === "question") {
    const ta = draftBox(d.id, "Your answer, in your words. It goes straight back to the worker.");
    const ok = el("button", "btn primary", "Send answer");
    ta.onkeydown = (e) => {
      if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) ok.click();
    };
    c.appendChild(ta);
    ok.onclick = () => (ta.value.trim() ? send({ action: "answer", answer: ta.value.trim() }, "Answer sent to the worker.") : ta.focus());
    row.appendChild(ok);
  } else if (d.kind === "action") {
    const ok = el("button", "btn primary", "Have the worker do it");
    ok.title = "The worker makes the call; you'll see the exact payload once more to approve.";
    ok.onclick = () => send({ action: "answer" }, "Sent. Approve the exact payload when it comes up.");
    row.appendChild(ok);
  } else {
    const ok = el("button", "btn primary", "Resume");
    ok.onclick = () => send({ action: "answer" }, "Resumed.");
    row.appendChild(ok);
  }
  const later = el("input");
  later.type = "date";
  later.value = tomorrow();
  later.title = "Ask me again on this day";
  const lb = el("button", "btn", "Later");
  lb.onclick = () => send({ action: "defer", answer: later.value }, `Deferred to ${later.value}.`);
  const dis = el("button", "btn ghost", "Dismiss");
  dis.onclick = () => send({ action: "dismiss" }, "Dismissed.");
  row.append(lb, later, dis, el("span", "spacer"), openChatBtn(d.taskId));
  c.appendChild(row);
}

function drawTodos(list) {
  const add = el("form", "todoadd");
  const inp = el("input");
  inp.placeholder = "Add a to-do only you can do…";
  inp.dataset.draft = "todo:new";
  inp.value = H.drafts["todo:new"] || "";
  inp.oninput = () => (H.drafts["todo:new"] = inp.value);
  add.appendChild(inp);
  add.onsubmit = async (e) => {
    e.preventDefault();
    const text = inp.value.trim();
    if (!text) return;
    try {
      const out = await post("/api/todos", { text, key: "" });
      if (out.duplicate) toast("That's already on the list.", true);
      delete H.drafts["todo:new"];
      inp.value = "";
    } catch (err) {
      toast(err.message, true);
    }
  };
  list.appendChild(add);
  if (!H.inbox.todos.length) list.appendChild(el("div", "ibempty", "No to-dos. PR reviews from finished tasks are added here."));
  for (const t of H.inbox.todos) {
    H.items.push({ id: t.key, taskId: t.taskId });
    const r = el("div", "ibitem todorow" + (H.sel === t.key ? " sel" : ""));
    r.dataset.id = t.key;
    const cb = el("input");
    cb.type = "checkbox";
    cb.title = "Done";
    cb.onchange = async () => {
      try {
        await post("/api/todos/done", { key: t.key });
      } catch (e) {
        toast(e.message, true);
        cb.checked = false;
      }
    };
    r.appendChild(cb);
    r.appendChild(el("span", "ti", t.text));
    if (t.url) {
      const a = el("a", "linkchip", "open");
      a.href = t.url;
      a.target = "_blank";
      a.rel = "noopener noreferrer";
      r.appendChild(a);
    }
    if (t.taskId) {
      const o = el("button", "linkchip", "chat");
      o.onclick = () => openRun(t.taskId);
      r.appendChild(o);
    }
    r.appendChild(el("span", "when", agoOf(t.createdAt)));
    list.appendChild(r);
  }
}

function drawTasks(list) {
  if (!H.tasks) return list.appendChild(el("div", "ibempty", "Loading…"));
  const open = H.tasks.tasks.filter((t) => t.status !== "cleaned");
  const c = H.tasks.harness;
  list.appendChild(el("div", "ibsum", `${H.tasks.working} working · cap ${c.maxWorkers} total, ${c.maxPerRepo} per repo · ${open.filter((t) => t.status === "queued").length} queued`));
  if (!open.length) return list.appendChild(el("div", "ibempty", "No tasks. Tell the orchestrator what to do from the top box."));
  for (const t of open) {
    const st = t.live ? "working" : t.status;
    const waiting = t.declared && t.declared.state === "waiting" ? `waiting: ${t.declared.text}` : "";
    ibRow(list, {
      id: t.id,
      taskId: t.id,
      badge: t.live && t.awaiting ? "asking" : STATUS_LABEL[st] || st || "new",
      tone: t.live && t.awaiting ? "hs-warn" : STATUS_TONE[st] || "",
      title: t.title,
      preview: waiting || t.phase || t.tldr || t.branch,
      at: t.updatedAt,
      body: (d) => taskBody(d, t),
    });
  }
}

function taskBody(c, t) {
  if (t.tldr) {
    const b = el("div", "text");
    b.innerHTML = md(t.tldr);
    c.appendChild(b);
  }
  const facts = el("dl", "tp-facts");
  for (const [k, v] of [
    ["Branch", t.branch],
    ["Repo", t.repo],
    ["Phase", t.phase],
    ["Live", t.live ? `yes${t.idleSec != null ? `, idle ${t.idleSec}s` : ""}${t.tool ? `, in ${t.tool}` : ""}` : ""],
    ["Queued", t.queuedFollowups ? `${t.queuedFollowups} follow-up(s)` : ""],
  ]) {
    if (!v) continue;
    facts.appendChild(el("dt", null, k));
    facts.appendChild(el("dd", "mono", v));
  }
  c.appendChild(facts);
  for (const n of t.notes || []) c.appendChild(el("div", "ibnote", n));

  const key = `fu:${t.id}`;
  const ta = draftBox(key, t.live ? "Follow-up for this worker (delivered when its turn ends)…" : "Follow-up for this worker…");
  c.appendChild(ta);

  const acts = el("div", "ibacts");
  const fu = el("button", "btn primary", "Send follow-up");
  fu.onclick = async () => {
    if (!ta.value.trim()) return ta.focus();
    try {
      const out = await post(`/api/runs/${encodeURIComponent(t.id)}/followup`, { text: ta.value.trim(), queue: true });
      delete H.drafts[key];
      toast(out.queued ? "Queued: delivered when the worker's turn ends." : "Sent.");
      loadTab("tasks");
    } catch (e) {
      toast(e.message, true);
    }
  };
  ta.onkeydown = (e) => {
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) fu.click();
  };
  acts.appendChild(fu);
  if (!t.live) {
    const rl = el("button", "btn", t.status === "queued" ? "Start now" : "Relaunch");
    rl.title = "Resume this worker's session where it left off";
    rl.onclick = async () => {
      rl.disabled = true;
      try {
        await post(`/api/tasks/${encodeURIComponent(t.id)}/relaunch`);
        toast("Relaunched.");
        loadTab("tasks");
      } catch (e) {
        toast(e.message, true);
      }
      rl.disabled = false;
    };
    acts.appendChild(rl);
  }
  if (!t.live && t.worktree) {
    const cl = el("button", "btn", "Clean up");
    cl.title = "Remove the worktree and keep the branch. Refuses if there is uncommitted or unpushed work.";
    cl.onclick = () => cleanupTask(t.id, cl).then(() => loadTab("tasks"));
    acts.appendChild(cl);
  }
  if (t.pr) {
    const a = el("a", "linkchip", "Pull request");
    a.href = t.pr;
    a.target = "_blank";
    a.rel = "noopener noreferrer";
    acts.appendChild(a);
  }
  acts.append(el("span", "spacer"), openChatBtn(t.id));
  c.appendChild(acts);
}

function drawActivity(list) {
  const bar = el("div", "ibsum");
  bar.appendChild(el("span", null, "Since"));
  const seg = el("div", "modeswitch small");
  for (const v of ["3h", "8h", "24h", "3d"]) {
    const b = el("button", "seg" + (H.since === v ? " on" : ""), v);
    b.onclick = () => {
      H.since = v;
      H.catchup = null;
      renderInbox(true);
    };
    seg.appendChild(b);
  }
  bar.appendChild(seg);
  list.appendChild(bar);
  if (!H.catchup) return list.appendChild(el("div", "ibempty", "Loading…"));
  const titles = new Map(H.catchup.tasks.map((t) => [t.id, t.title]));
  const evs = H.catchup.events.filter((e) => e.name !== "nudged").reverse();
  if (!evs.length) return list.appendChild(el("div", "ibempty", `Nothing happened in the last ${H.since}.`));
  for (const e of evs) {
    const r = el("button", "evrow");
    r.appendChild(el("span", "when", agoOf(e.at)));
    r.appendChild(el("span", "badge " + (STATUS_TONE[e.status] || ""), e.name));
    r.appendChild(el("span", "ti", e.taskId === ORCH ? "Orchestrator" : titles.get(e.taskId) || e.taskId));
    r.appendChild(el("span", "tx", e.text || ""));
    r.onclick = () => S.runs.some((x) => x.runId === e.taskId) && openRun(e.taskId);
    list.appendChild(r);
  }
}

// Keys while the Inbox is open: j/k move, Enter opens the chat. Capture phase, so app.js's own j/k (walk the chat list) stays out.
document.addEventListener(
  "keydown",
  (e) => {
    if (!H.view || e.metaKey || e.ctrlKey || e.altKey) return;
    const a = document.activeElement;
    if (/^(INPUT|TEXTAREA|SELECT)$/.test(a.tagName) || a.isContentEditable) return;
    if (document.querySelector(".palette-scrim.open, .confirmscrim.open, .memscrim.open")) return;
    const i = H.items.findIndex((x) => x.id === H.sel);
    let hit = true;
    if (e.key === "j" || e.key === "ArrowDown") H.sel = (H.items[i + 1] || H.items[i] || {}).id || "";
    else if (e.key === "k" || e.key === "ArrowUp") H.sel = (H.items[Math.max(i - 1, 0)] || {}).id || "";
    else if (e.key === "Enter" && i >= 0 && H.items[i].taskId) return void (e.preventDefault(), e.stopPropagation(), openRun(H.items[i].taskId));
    else hit = false;
    if (!hit) return;
    e.preventDefault();
    e.stopPropagation();
    drawInbox();
    const n = H.sel && $("inboxView").querySelector(`[data-id="${CSS.escape(H.sel)}"]`);
    if (n) n.scrollIntoView({ block: "nearest" });
  },
  true
);
/* -------------------------------------------------------------- settings */

const POLICY_ROWS = [
  ["chat", "Slack and chat posts"],
  ["tickets", "Linear and GitHub issue writes"],
  ["docs", "Notion and Google Workspace writes"],
  ["prMerge", "Merging or closing a PR"],
  ["prComments", "PR comments and review replies (/resolve)"],
  ["otherWrites", "Any other connector write or outbound POST"],
  ["destructiveGit", "Force-push, reset --hard, branch -D, clean -f"],
];
const POLICY_DEFAULT = { chat: "ask", tickets: "ask", docs: "ask", prMerge: "ask", prComments: "allow", otherWrites: "ask", destructiveGit: "ask" };

function renderHarnessSettings() {
  const c = S.config && S.config.harness;
  const host = $("harnessSettings");
  if (!c || !host) return;
  host.innerHTML = "";

  const row = (title, desc, control) => {
    const r = el("div", "row");
    const l = el("div", "label");
    l.appendChild(el("div", "t", title));
    if (desc) l.appendChild(el("div", "d", desc));
    r.appendChild(l);
    r.appendChild(control);
    host.appendChild(r);
  };
  const toggle = (on, fn) => {
    const lab = el("label", "sw-toggle");
    const i = el("input");
    i.type = "checkbox";
    i.checked = !!on;
    i.onchange = () => fn(i.checked);
    lab.appendChild(i);
    lab.appendChild(el("span", "track"));
    return lab;
  };
  const num = (v, lo, hi, fn) => {
    const i = el("input", "numin");
    i.type = "number";
    i.min = lo;
    i.max = hi;
    i.value = v;
    i.onchange = () => fn(Number(i.value));
    return i;
  };
  const save = (patch) => saveConfig({ harness: patch });

  row("Relay outcomes to the orchestrator", "Each worker outcome starts a short turn in the Orchestrator chat, which tells you what happened.", toggle(c.relay, (v) => save({ relay: v })));
  row("Workers at once", "Past this, new tasks queue and start when a slot frees. Workers declared waiting don't count.", num(c.maxWorkers, 1, 20, (v) => save({ maxWorkers: v })));
  row("Per repo", "", num(c.maxPerRepo, 1, 20, (v) => save({ maxPerRepo: v })));
  row("Stalled after (minutes)", "Silence before a working worker is flagged. A declared wait gets four times this.", num(c.stallMinutes, 1, 240, (v) => save({ stallMinutes: v })));

  host.appendChild(el("div", "lbl sublbl", "Write policy · Ask shows you the exact payload to approve"));
  for (const [k, label] of POLICY_ROWS) {
    const cur = (c.policy && c.policy[k]) || POLICY_DEFAULT[k];
    const seg = el("div", "modeswitch small");
    for (const v of ["ask", "allow"]) {
      const b = el("button", "seg" + (cur === v ? " on" : ""), v);
      b.onclick = () => save({ policy: { ...(c.policy || {}), [k]: v } });
      seg.appendChild(b);
    }
    row(label, "", seg);
  }
  host.appendChild(el("div", "d", "Kill-by-pattern, env dumps, argv listings and .env reads are always refused; they have no switch."));
}

/* ------------------------------------------------------------- top box */

// Capture phase on the document, so it runs before app.js's own submit handler
// and can keep anything that isn't a Slack link away from it.
document.addEventListener(
  "submit",
  async (e) => {
    if (e.target.id !== "linkForm") return;
    const input = $("linkInput");
    const text = input.value.trim();
    if (!text || isSlackLink(text)) return; // app.js handles links
    e.preventDefault();
    e.stopPropagation();
    const go = $("linkGo");
    go.disabled = true;
    try {
      const out = await api(`/api/runs/${ORCH}/followup`, { method: "POST", body: JSON.stringify({ text, queue: true }) });
      input.value = "";
      paintLinkGo();
      toast(out.queued ? "Queued for the orchestrator: it's mid-turn." : "Sent to the orchestrator.");
      openRun(ORCH);
    } catch (err) {
      toast(err.message, true);
    }
    go.disabled = false;
  },
  true
);

function paintLinkGo() {
  const v = $("linkInput").value.trim();
  $("linkGo").textContent = !v || isSlackLink(v) ? "Run" : "Send";
  $("linkGo").title = !v || isSlackLink(v) ? "Open the chat and run the pipeline" : "Send to the orchestrator, which writes a brief and spawns a worker";
}
$("linkInput").addEventListener("input", paintLinkGo);

/* ----------------------------------------------------------- live feed */

function notifyOutcome(d) {
  if (!d.needsYou || typeof notifyState !== "function" || notifyState() !== "on") return;
  if (document.hasFocus() && d.taskId === S.currentId) return;
  try {
    const n = new Notification(`${d.title || d.taskId} · ${STATUS_LABEL[d.status] || d.name}`, {
      body: d.text || "",
      tag: `outcome-${d.taskId}`,
      renotify: true,
      icon: "/logo.png",
    });
    n.onclick = () => {
      window.focus();
      n.close();
      openRun(d.taskId);
    };
  } catch {}
}

function refreshHarnessViews() {
  paintInboxBtn();
  paintTitle();
  renderSidebar();
  renderInbox(H.tab === "tasks");
  if (S.run && (S.run.kind === "orchestrator" || S.run.kind === "task")) renderInspector();
}

(function connectHarness() {
  const es = new EventSource("/api/events");
  es.addEventListener("inbox", (e) => {
    H.inbox = JSON.parse(e.data);
    refreshHarnessViews();
  });
  es.addEventListener("outcome", (e) => {
    const d = JSON.parse(e.data);
    notifyOutcome(d);
    if (S.run && S.run.runId === d.taskId) loadTask(d.taskId, true).then(() => renderInspector());
    renderInbox(true);
  });
})();

const toggleInbox = () => (H.view ? closeInbox(true) : openInbox());
$("inboxBtn").addEventListener("click", toggleInbox);
document.addEventListener("keydown", (e) => {
  const typing = /^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement.tagName) || document.activeElement.isContentEditable;
  if (typing || e.metaKey || e.ctrlKey) return;
  if (e.key === "i") {
    e.preventDefault();
    toggleInbox();
  }
  if (e.key === "o") {
    e.preventDefault();
    openRun(ORCH);
  }
});

api("/api/inbox")
  .then((out) => {
    H.inbox = out;
    refreshHarnessViews();
    if (location.hash === "#inbox") openInbox();
  })
  .catch(() => {});
