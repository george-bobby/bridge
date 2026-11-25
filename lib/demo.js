/**
 * Demo mode: a fictional team ("Acme storefront") with sessions in every
 * state, pull requests, Linear issues with sub-issues, and dev servers. Used by
 * `npm run demo` to try the app without touching GitHub, Linear or a real
 * repo, and for the screenshots in docs/. Nothing here calls out.
 */

const fs = require("fs");
const path = require("path");

const DAY = 86400;
const now = () => Math.floor(Date.now() / 1000);
const iso = (secondsAgo) => new Date((now() - secondsAgo) * 1000).toISOString();
const REPO = "/Users/you/Development/storefront";
const WT = "/Users/you/Development/storefront-worktrees";
const GH = "https://github.com/acme/storefront/pull";
const LINEAR = "https://linear.app/acme/issue";

/* ------------------------------------------------------------- GitHub */

const pr = (n, title, o = {}) => ({
  number: n,
  title,
  url: `${GH}/${n}`,
  repo: "acme/storefront",
  author: o.author || "alex-rivera",
  avatar: "",
  draft: !!o.draft,
  state: o.state || "OPEN",
  review: o.review || "",
  checks: o.checks || "SUCCESS",
  mergeable: o.mergeable || "MERGEABLE",
  branch: o.branch || "",
  additions: o.add || 0,
  deletions: o.del || 0,
  comments: o.comments || 0,
  createdAt: iso((o.ago || 3600) + DAY),
  updatedAt: iso(o.ago || 3600),
  mergedAt: o.state === "MERGED" ? iso(o.ago || DAY) : null,
  issueKey: (title.match(/\b([A-Z]+-\d+)\b/) || [])[1] || "",
});

function pulls() {
  return {
    login: "alex-rivera",
    mine: [
      pr(482, "feat(checkout): Apple Pay in the payment step (WEB-124)", { branch: "alex/web-124-apple-pay", review: "REVIEW_REQUIRED", add: 612, del: 48, comments: 9, ago: 1500 }),
      pr(479, "feat(api): rate-limit the search endpoint per API key (WEB-131)", { branch: "alex/web-131-rate-limit-search", checks: "FAILURE", review: "CHANGES_REQUESTED", add: 288, del: 31, comments: 14, ago: 5400 }),
      pr(476, "test(e2e): stabilise the checkout flow suite (WEB-133)", { branch: "alex/web-133-flaky-e2e", draft: true, checks: "PENDING", add: 74, del: 102, comments: 2, ago: 9000 }),
      pr(473, "fix(cart): show VAT-inclusive prices for EU shoppers", { branch: "alex/eu-vat-cart", mergeable: "CONFLICTING", checks: "SUCCESS", review: "APPROVED", add: 131, del: 22, comments: 6, ago: 20000 }),
    ],
    review: [
      pr(485, "feat(checkout): promo codes with stacking rules (WEB-123)", { author: "maya-chen", branch: "maya/web-123-promo-codes", review: "REVIEW_REQUIRED", add: 540, del: 87, comments: 4, ago: 2600 }),
      pr(488, "chore(deps): bump Next.js to 15.2", { author: "sam-ortiz", branch: "sam/next-15-2", checks: "PENDING", review: "REVIEW_REQUIRED", add: 41, del: 39, comments: 1, ago: 7200 }),
    ],
    merged: [
      pr(470, "fix(theme): keep the dark-mode choice across reloads (WEB-118)", { state: "MERGED", review: "APPROVED", add: 36, del: 12, comments: 3, ago: DAY }),
      pr(468, "feat(checkout): address autocomplete (WEB-121)", { state: "MERGED", review: "APPROVED", add: 402, del: 66, comments: 11, ago: 3 * DAY }),
      pr(451, "fix(email): currency symbol in order confirmations", { state: "MERGED", review: "APPROVED", add: 22, del: 9, comments: 2, ago: 7 * DAY }),
      pr(465, "feat(checkout): saved cards (WEB-122)", { state: "MERGED", review: "APPROVED", add: 517, del: 93, comments: 17, ago: 5 * DAY }),
    ],
    at: Date.now(),
  };
}

/* ------------------------------------------------------------- Linear */

const STATES = {
  backlog: ["Backlog", "backlog", "#bec2c8", 0],
  todo: ["Todo", "unstarted", "#e2e2e2", 1],
  progress: ["In Progress", "started", "#f2c94c", 2],
  review: ["In Review", "started", "#0f783c", 3],
  done: ["Done", "completed", "#5e6ad2", 4],
};
const PEOPLE = { me: "Alex Rivera", maya: "Maya Chen", sam: "Sam Ortiz", priya: "Priya Raman" };

const child = (key, title, state, who, priority = 3) => ({
  key,
  title,
  url: `${LINEAR}/${key}`,
  priority,
  priorityLabel: ["No priority", "Urgent", "High", "Medium", "Low"][priority],
  state: STATES[state][0],
  stateType: STATES[state][1],
  stateColor: STATES[state][2],
  assignee: who ? PEOPLE[who] : "",
  assigneeAvatar: "",
  mine: who === "me",
});

const issue = (key, title, state, o = {}) => ({
  ...child(key, title, state, "me", o.priority ?? 3),
  branch: `alex/${key.toLowerCase()}-${title.toLowerCase().replace(/[^a-z0-9]+/g, "-").slice(0, 30).replace(/-$/, "")}`,
  statePos: STATES[state][3],
  team: "WEB",
  project: o.project || "",
  cycle: o.cycle === undefined ? 14 : o.cycle,
  labels: o.labels || [],
  description: o.description || "",
  updatedAt: iso(o.ago || 3600),
  createdAt: iso((o.ago || 3600) + 7 * DAY),
  parent: o.parent || null,
  children: o.children || [],
});

function linear() {
  const checkout = { key: "WEB-120", title: "Checkout v2", url: `${LINEAR}/WEB-120`, state: "In Progress", stateType: "started", stateColor: "#f2c94c" };
  return {
    configured: true,
    viewer: PEOPLE.me,
    org: "acme",
    issues: [
      issue("WEB-120", "Checkout v2", "progress", {
        priority: 2,
        project: "Checkout v2",
        ago: 1800,
        description: "Rebuild checkout as a single page: autocomplete, saved cards, promo codes, wallets.",
        children: [
          child("WEB-121", "Address autocomplete", "done", "me", 3),
          child("WEB-122", "Saved cards", "done", "me", 2),
          child("WEB-123", "Promo codes with stacking rules", "review", "maya", 3),
          child("WEB-124", "Apple Pay in the payment step", "review", "me", 2),
          child("WEB-125", "Order summary redesign", "todo", "", 3),
          child("WEB-126", "Guest checkout", "backlog", "sam", 4),
        ],
      }),
      issue("WEB-124", "Apple Pay in the payment step", "review", { priority: 2, project: "Checkout v2", parent: checkout, ago: 1500 }),
      issue("WEB-131", "Rate-limit the search API", "progress", { priority: 1, labels: [{ name: "backend", color: "#4ea7fc" }], ago: 5400, description: "Search is being scraped. Add a limit that doesn't punish B2B customers behind shared NAT." }),
      issue("WEB-133", "Flaky checkout e2e suite", "todo", { priority: 2, labels: [{ name: "bug", color: "#eb5757" }], ago: 9000 }),
      issue("WEB-127", "Move product images to the new CDN", "todo", { priority: 3, labels: [{ name: "infra", color: "#bb87fc" }], ago: 2 * DAY, description: "Serve product images from the new CDN with responsive sizes. Keep the old URLs redirecting for a month." }),
      issue("WEB-140", "Accessibility audit fixes", "backlog", {
        priority: 0,
        cycle: null,
        ago: 4 * DAY,
        children: [
          child("WEB-141", "Focus rings on every control", "todo", "priya", 3),
          child("WEB-142", "Announce cart updates to screen readers", "backlog", "", 3),
          child("WEB-143", "Colour contrast on sale badges", "done", "priya", 4),
        ],
      }),
      issue("WEB-118", "Dark mode resets on reload", "done", { priority: 4, ago: DAY }),
    ],
    at: Date.now(),
  };
}

function ports() {
  return {
    servers: [
      { pid: 41210, command: "node", cwd: `${WT}/alex-web-124-apple-pay/web`, ports: [3000] },
      { pid: 41388, command: "python3.12", cwd: `${WT}/alex-web-131-rate-limit-search/api`, ports: [8000] },
    ],
    at: Date.now(),
  };
}

/* ------------------------------------------------------------ sessions */

let seq = 0;
const id = () => `d${(++seq).toString(36)}`;
const user = (text, ago) => ({ id: id(), role: "user", text, ts: now() - ago });
const event = (text, ago, phase = "phase") => ({ id: id(), role: "event", phase, text, ts: now() - ago });
const claude = (ago, steps, o = {}) => ({
  id: id(),
  role: "assistant",
  kind: o.kind || "followup",
  label: o.label || "worker",
  ts: now() - ago,
  model: o.model || "opus",
  state: o.state || "done",
  text: steps.filter((s) => s.kind === "text").map((s) => s.text).join("\n\n"),
  steps,
  cost: o.cost || 0,
  durationMs: o.ms || 0,
  turns: o.turns || 0,
  usage: { input: 0, output: o.out || 0, cacheRead: 0, cacheWrite: 0, thinking: 0 },
  workdir: o.workdir || REPO,
});
const think = (text, tokens) => ({ kind: "thinking", text, tokens, streaming: false });
const say = (text) => ({ kind: "text", text, streaming: false });
const tool = (name, detail, result = "", ok = true) => ({ kind: "tool", name, detail, result, ok, resultLines: result ? result.split("\n").length : 0 });

function run(runId, o) {
  return {
    runId,
    createdAt: now() - o.age,
    updatedAt: now() - (o.updated ?? Math.floor(o.age / 3)),
    who: o.who,
    channel: o.channel || "",
    threadTs: runId,
    text: o.text,
    permalink: o.permalink || "",
    action: o.action || "pending",
    phase: o.phase || "queued",
    prUrl: o.prUrl || "",
    linearUrl: o.linearUrl || "",
    outcome: o.outcome || "",
    kind: o.kind || "slack",
    sessionId: o.messages && o.messages.length ? `demo-${runId}` : null,
    opts: o.opts || {},
    cost: (o.messages || []).reduce((n, m) => n + (m.cost || 0), 0),
    seenAt: o.seen ? now() : 0,
    messages: o.messages || [],
    ...(o.board ? { board: { column: o.board, at: Date.now() } } : {}),
    ...(o.project ? { project: o.project } : {}),
    ...(o.pinned ? { pinned: true } : {}),
    ...(o.pendingAsk ? { pendingAsk: o.pendingAsk } : {}),
  };
}

function sessions() {
  const csvAsk = {
    id: "ask-csv-1",
    tool: "AskUserQuestion",
    display: "AskUserQuestion",
    state: "pending",
    askedAt: now() - 240,
    questions: [
      {
        header: "Scope",
        question: "The off-by-one is in paginateRows(). Fix only the CSV export, or every paginated export?",
        multiSelect: false,
        options: [
          { label: "Every export", description: "CSV, XLSX and the API's ?format=csv share paginateRows(); one fix covers all three." },
          { label: "CSV only", description: "Smallest change. XLSX and the API keep dropping the last row until a follow-up." },
        ],
      },
    ],
  };
  return [
    run("1732530001.000100", {
      who: "Jordan Lee",
      channel: "#eng-bugs",
      age: 2400,
      updated: 240,
      text: "CSV export drops the last row whenever a filter is applied. Repro: Orders, filter status = paid, export. 41 rows on screen, 40 in the file.",
      permalink: "https://acme.slack.com/archives/C01/p1732530001000100",
      action: "running",
      phase: "root-cause",
      pendingAsk: { id: csvAsk.id, msgId: "x", tool: "AskUserQuestion", summary: "Scope: fix only CSV, or every export?", askedAt: csvAsk.askedAt },
      messages: [
        { id: id(), role: "slack", who: "Jordan Lee", text: "CSV export drops the last row whenever a filter is applied. Repro: Orders, filter status = paid, export. 41 rows on screen, 40 in the file.", ts: now() - 2400 },
        claude(
          2300,
          [
            think("The count is off by exactly one only when a filter is set, so it's probably the page-boundary maths when the filtered total isn't a multiple of the page size.", 412),
            tool("Grep", "paginateRows src/", "src/export/paginate.ts:14\nsrc/export/csv.ts:31\nsrc/export/xlsx.ts:27\nsrc/api/orders.ts:88"),
            tool("Read", "src/export/paginate.ts", "export function paginateRows(total: number, size: number) {\n  const pages = Math.floor(total / size);\n  return Array.from({ length: pages }, (_, i) => [i * size, (i + 1) * size]);\n}"),
            say("Found it. `paginateRows()` uses `Math.floor(total / size)`, so a final partial page is never emitted. With no filter the total happens to be a multiple of 50, which is why it only shows up filtered.\n\nThe same helper feeds CSV, XLSX and the API's `?format=csv`."),
            { ...tool("AskUserQuestion", "Scope of the fix"), ask: csvAsk },
          ],
          { kind: "pipeline", label: "pipeline", state: "running", model: "opus" },
        ),
      ],
    }),
    run("1732530002.000200", {
      who: "Maya Chen",
      channel: "#support",
      age: 1500,
      updated: 20,
      text: "EU customers are seeing prices without VAT on the cart page, but checkout charges the VAT-inclusive total.",
      permalink: "https://acme.slack.com/archives/C02/p1732530002000200",
      action: "running",
      phase: "build",
      messages: [
        { id: id(), role: "slack", who: "Maya Chen", text: "EU customers are seeing prices without VAT on the cart page, but checkout charges the VAT-inclusive total.", ts: now() - 1500 },
        claude(1400, [tool("Bash", "rg -n 'formatPrice\\(' src/cart", "src/cart/LineItem.tsx:22\nsrc/cart/Summary.tsx:40"), tool("Edit", "src/cart/LineItem.tsx"), say("Cart line items call `formatPrice(net)`; switching them to the VAT-inclusive helper the checkout already uses.")], {
          kind: "pipeline",
          label: "pipeline",
          state: "running",
        }),
      ],
    }),
    run("t-241125-web-124-apple-pay", {
      kind: "task",
      pinned: true,
      who: "WEB-124 Apple Pay in the payment step",
      age: 3 * 3600,
      updated: 1500,
      text: "Add Apple Pay to the checkout payment step behind the wallets flag.",
      prUrl: `${GH}/482`,
      linearUrl: `${LINEAR}/WEB-124`,
      action: "acted",
      phase: "review",
      seen: true,
      messages: [
        user("**Brief**\n\nAdd Apple Pay to the checkout payment step (WEB-124), behind the `wallets` flag. Use the existing Stripe Payment Request integration.", 3 * 3600),
        claude(
          3 * 3600 - 60,
          [
            think("Stripe's Payment Request Button already supports Apple Pay; the work is the domain association file, the flag, and wiring the result into our order submit.", 980),
            { ...tool("TodoWrite", "3 todos"), raw: JSON.stringify({ todos: [{ content: "Serve the Apple Pay domain association file", status: "completed" }, { content: "Render the Payment Request Button behind wallets", status: "completed" }, { content: "Run checkout tests and verify in Safari", status: "in_progress" }] }) },
            tool("Read", "src/checkout/PaymentStep.tsx", "…"),
            tool("Write", "public/.well-known/apple-developer-merchantid-domain-association"),
            { ...tool("Edit", "src/checkout/PaymentStep.tsx", "ok"), raw: JSON.stringify({ file_path: "src/checkout/PaymentStep.tsx", old_string: "  return <CardForm onPay={submit} />;", new_string: "  if (flags.wallets && canMakePayment) return <PaymentRequestButton request={request} onPay={submit} />;\n  return <CardForm onPay={submit} />;" }) },
            tool("Bash", "pnpm test checkout", "PASS  src/checkout/__tests__/payment.test.tsx (14 tests)\nPASS  src/checkout/__tests__/wallets.test.tsx (6 tests)\n\nTests: 20 passed, 20 total"),
            tool("Bash", "gh pr create --title 'feat(checkout): Apple Pay in the payment step (WEB-124)'", "https://github.com/acme/storefront/pull/482"),
            say("Apple Pay is live behind `wallets`.\n\n- Payment Request Button renders when the browser supports it, falling back to the card form\n- Domain association file served from `/.well-known/`\n- 20 checkout tests pass; verified on Safari with a sandbox card\n\nOpened **#482**. It needs a reviewer from payments."),
          ],
          { cost: 4.12, ms: 612000, turns: 38, out: 18400, workdir: `${WT}/alex-web-124-apple-pay` },
        ),
        event("**report** · ready-for-review · PR #482 opened", 1500, "outcome"),
      ],
    }),
    run("t-241125-web-131-rate-limit", {
      kind: "task",
      who: "WEB-131 Rate-limit the search API",
      age: 6 * 3600,
      updated: 5000,
      text: "Rate-limit /api/search without breaking B2B customers behind shared NAT.",
      prUrl: `${GH}/479`,
      linearUrl: `${LINEAR}/WEB-131`,
      action: "acted",
      messages: [
        user("**Brief**\n\nRate-limit `/api/search` (WEB-131). Scrapers are hammering it.", 6 * 3600),
        claude(6 * 3600 - 60, [tool("Read", "src/api/search.ts"), tool("Edit", "src/api/middleware/rateLimit.ts"), say("Token bucket in Redis, 60 req/min. One open question in the report: limit per API key or per IP?")], { cost: 2.38, ms: 410000, turns: 22 }),
      ],
    }),
    run("t-241124-web-127-cdn", {
      kind: "task",
      who: "WEB-127 Move product images to the new CDN",
      age: 2 * DAY,
      text: "Serve product images from the new CDN with responsive sizes.",
      linearUrl: `${LINEAR}/WEB-127`,
    }),
    run("1732530003.000300", {
      who: "Priya Raman",
      channel: "#design",
      age: 3 * DAY,
      text: "Dark mode resets to light every time I reload the page.",
      prUrl: `${GH}/470`,
      action: "acted",
      outcome: "True positive: theme read before hydration. Fixed in #470.",
      seen: true,
      messages: [claude(3 * DAY - 300, [say("The theme is read from `localStorage` after hydration, so the server-rendered light theme wins on reload. Fixed in **#470**.")], { cost: 1.06, ms: 190000, turns: 12, kind: "pipeline", label: "pipeline" })],
    }),
    run("1732530004.000400", {
      who: "Sam Ortiz",
      channel: "#eng-bugs",
      age: 5 * DAY,
      text: "Search feels slow for long queries, maybe 2s?",
      action: "skipped",
      outcome: "Not reproducible: p95 is 180ms; the 2s was a cold dev server.",
      seen: true,
      messages: [claude(5 * DAY - 300, [say("Couldn't reproduce: production p95 for queries over 40 characters is 180ms. The 2s was a cold local dev server.")], { cost: 0.42, ms: 95000, turns: 6, kind: "pipeline", label: "pipeline" })],
    }),
    run("1732530007.000700", {
      who: "Kai Nakamura",
      channel: "#mobile",
      age: 7200,
      updated: 600,
      text: "iOS app crashes on launch for some iOS 17 users since 4.12.",
      permalink: "https://acme.slack.com/archives/C03/p1732530007000700",
      action: "acted",
      project: "mobile",
      prUrl: "",
      messages: [claude(7000, [tool("Bash", "grep -rn 'UIScene' ios/App", "ios/App/SceneDelegate.swift:18"), say("4.12 calls a scene API that only exists on iOS 18. Guarded it with `#available(iOS 18, *)`; build passes on the iOS 17 simulator.")], { cost: 1.73, ms: 300000, turns: 15, kind: "pipeline", label: "pipeline", workdir: "/Users/you/Development/mobile" })],
    }),
    run("1732530005.000500", {
      who: "Jordan Lee",
      channel: "#eng-bugs",
      age: 8 * DAY,
      text: "Order confirmation emails show the wrong currency symbol for CAD.",
      action: "acted",
      prUrl: `${GH}/451`,
      seen: true,
      messages: [claude(8 * DAY - 300, [say("Fixed: the email template hard-coded `$`. Now uses `Intl.NumberFormat` with the order's currency.")], { cost: 0.88, ms: 150000, turns: 9, kind: "pipeline", label: "pipeline" })],
    }),
  ];
}

const tasks = [
  { id: "t-241125-web-124-apple-pay", title: "WEB-124 Apple Pay in the payment step", branch: "alex/web-124-apple-pay", worktree: `${WT}/alex-web-124-apple-pay`, status: "ready-for-review", prUrl: `${GH}/482` },
  { id: "t-241125-web-131-rate-limit", title: "WEB-131 Rate-limit the search API", branch: "alex/web-131-rate-limit-search", worktree: `${WT}/alex-web-131-rate-limit-search`, status: "needs-input", prUrl: `${GH}/479`, phase: "waiting on a decision" },
  { id: "t-241124-web-127-cdn", title: "WEB-127 Move product images to the new CDN", branch: "alex/web-127-cdn", worktree: `${WT}/alex-web-127-cdn`, status: "new" },
];

/** Write the demo team into `dataDir`, replacing whatever was there. */
function seed(dataDir) {
  const marker = path.join(dataDir, ".bridge-demo");
  if (fs.existsSync(dataDir) && fs.readdirSync(dataDir).length && !fs.existsSync(marker)) {
    throw new Error(`${dataDir} isn't a demo folder; refusing to replace it`);
  }
  fs.rmSync(dataDir, { recursive: true, force: true });
  const runs = path.join(dataDir, "runs");
  const tdir = path.join(dataDir, "tasks");
  fs.mkdirSync(runs, { recursive: true });
  fs.mkdirSync(tdir, { recursive: true });
  fs.writeFileSync(marker, "Demo data from lib/demo.js. Rebuilt on every `npm run demo`.\n");
  writeSessions(dataDir);
  for (const t of tasks) {
    fs.mkdirSync(path.join(tdir, t.id), { recursive: true });
    fs.writeFileSync(path.join(tdir, t.id, "meta.json"), JSON.stringify({ kind: "task", repo: REPO, base: "main", createdAt: now() - DAY, ...t }, null, 1));
  }
  fs.writeFileSync(
    path.join(tdir, "t-241125-web-124-apple-pay", "report.md"),
    "---\nstatus: ready-for-review\npr: https://github.com/acme/storefront/pull/482\n---\n\n## TL;DR\nApple Pay ships behind `wallets`; 20 checkout tests pass and it was verified in Safari with a sandbox card. PR #482 needs a reviewer from payments.\n",
  );
  fs.writeFileSync(
    path.join(tdir, "decisions.json"),
    JSON.stringify([
      {
        id: "d-demo1",
        key: "t-241125-web-131-rate-limit:question:1",
        taskId: "t-241125-web-131-rate-limit",
        kind: "question",
        text: "Should search limits apply **per API key** or **per IP**? Per key is fairer to B2B customers behind shared NAT; per IP also covers anonymous scrapers.",
        state: "open",
        createdAt: now() - 4800,
      },
    ]),
  );
  fs.writeFileSync(path.join(tdir, "todos.json"), JSON.stringify([{ key: "merge-482", text: "Merge #482 once payments approves", taskId: "t-241125-web-124-apple-pay", url: `${GH}/482`, done: false, createdAt: now() - 1400 }]));
  fs.writeFileSync(
    path.join(dataDir, "projects.json"),
    JSON.stringify([
      { id: "storefront", name: "storefront", path: REPO, createdAt: Date.now() },
      { id: "mobile", name: "mobile", path: "/Users/you/Development/mobile", createdAt: Date.now() },
    ]),
  );
  fs.writeFileSync(
    path.join(dataDir, "config.json"),
    JSON.stringify({ followup: { workdir: REPO, model: "opus", permissionMode: "bypassPermissions", effort: "medium" }, harness: { relay: false } }),
  );
}

/** The chats alone. Rewritten after the server boots, because boot clears
 *  every pending question (their sessions died with the last server). */
function writeSessions(dataDir) {
  seq = 0;
  for (const r of sessions()) fs.writeFileSync(path.join(dataDir, "runs", `${r.runId}.json`), JSON.stringify(r, null, 1));
}

/* -------------------------------------------------------------- Slack */

const THREADS = {
  "1732530001.000100": { channel: "#eng-bugs", messages: [
    ["Jordan Lee", "CSV export drops the last row whenever a filter is applied. Repro: Orders, filter status = paid, export. 41 rows on screen, 40 in the file.", 2400],
    ["Priya Raman", "Same on XLSX for me, fwiw", 2200],
    ["Jordan Lee", "@Alex Rivera can you take this one? A customer is reconciling against it.", 2100],
  ] },
  "1732530002.000200": { channel: "#support", messages: [
    ["Maya Chen", "EU customers are seeing prices without VAT on the cart page, but checkout charges the VAT-inclusive total.", 1500],
    ["Maya Chen", "Three tickets today. @Alex Rivera is this the same as last month's rounding fix?", 1400],
  ] },
  "1732530006.000600": { channel: "#ops", messages: [
    ["Kai Nakamura", "The nightly sitemap job failed twice this week. @Alex Rivera could it be the new CDN URLs?", 900],
  ] },
};

const slack = {
  configured: () => true,
  status: async () => ({ configured: true, team: "Acme", teamId: "T0ACME", user: "alex", userId: "U0ALEX", url: "https://acme.slack.com/" }),
  mentions: async () =>
    Object.entries(THREADS).map(([ts, t]) => {
      const m = t.messages.find((x) => x[1].includes("@Alex")) || t.messages[0];
      return { ts, threadTs: ts, channelId: "C0DEMO", channel: t.channel, who: m[0], avatar: "", text: m[1], permalink: `https://acme.slack.com/archives/C0DEMO/p${ts.replace(".", "")}` };
    }),
  thread: async ({ channelId, threadTs }) => {
    const t = THREADS[threadTs] || { channel: "#general", messages: [["Someone", "(a thread from the demo workspace)", 600]] };
    return { channelId, threadTs, channel: t.channel, messages: t.messages.map(([who, text, ago], i) => ({ ts: `${now() - ago}.00000${i}`, user: "", who, avatar: "", text, files: [] })) };
  },
  reply: async () => {
    throw new Error("the demo workspace doesn't post replies");
  },
  describeThread: async (link) => {
    const t = THREADS[link.threadTs];
    return t ? { who: t.messages[0][0], channel: t.channel, text: t.messages[0][1], userId: "" } : null;
  },
};

function usage() {
  const h = (n) => Date.now() + n * 3600_000;
  const local = (turns, tokens, cost, acu = 0) => ({ week: { turns, tokens, cost, acu }, month: { turns: turns * 3, tokens: tokens * 3, cost: cost * 3, acu: acu * 3 } });
  return {
    at: Date.now(),
    providers: [
      { id: "claude", label: "Claude", status: "ok", plan: "Max 5x", account: "alex@acme.dev", fetchedAt: Date.now(), windows: [
        { id: "session", label: "Session", short: "5h", usedPct: 49, resetsAt: h(3.2), duration: 18000 },
        { id: "weekly", label: "Weekly", short: "wk", usedPct: 62, resetsAt: h(4 * 24 + 3), duration: 604800 },
        { id: "weekly-opus", label: "Weekly · Opus", short: "wk Opus", usedPct: 18, resetsAt: h(4 * 24 + 3), duration: 604800 },
      ], details: [{ label: "Extra usage", value: "Enabled" }], local: local(24, 3_400_000, 8.23) },
      { id: "codex", label: "Codex", status: "ok", plan: "Pro", account: "alex@acme.dev", fetchedAt: Date.now(), windows: [
        { id: "primary", label: "5-hour", short: "5h", usedPct: 23, resetsAt: h(0.6), duration: 18000 },
        { id: "secondary", label: "Weekly", short: "wk", usedPct: 84, resetsAt: h(5 * 24 + 12), duration: 604800 },
      ], details: [], local: local(6, 820_000, 0) },
      { id: "cursor", label: "Cursor", status: "ok", plan: "", account: "alex@acme.dev", fetchedAt: Date.now(), windows: [
        { id: "total", label: "Monthly", short: "mo", usedPct: 31, resetsAt: h(17 * 24), duration: 2592000 },
        { id: "auto", label: "Cursor models", short: "Cursor models", usedPct: 22, resetsAt: h(17 * 24), duration: 2592000 },
      ], details: [{ label: "Included", value: "$6.20 of $20.00" }], local: local(3, 240_000, 0) },
      { id: "devin", label: "Devin", status: "ok", plan: "", account: "", fetchedAt: Date.now(), windows: [], details: [{ label: "Plan usage", value: "Devin doesn't publish plan limits; ACUs below are from turns Bridge ran" }], local: local(4, 510_000, 0, 1.8) },
    ],
  };
}

const agents = () => [
  {
    id: "claude", label: "Claude", installed: true, version: "2.3.1",
    models: [
      { id: "opus", label: "Opus 5.5", hint: "For complex work and everyday tasks · → claude-opus-5-5 · 1M context", efforts: ["low", "medium", "high", "xhigh"], alias: true, group: "Latest" },
      { id: "sonnet", label: "Sonnet 5.5", hint: "Most efficient for simpler tasks · → claude-sonnet-5-5 · 1M context", efforts: ["low", "medium", "high", "xhigh", "max"], alias: true, group: "Latest" },
      { id: "haiku", label: "Haiku 5.5", hint: "Fastest for quick answers · → claude-haiku-5-5", efforts: ["low", "medium", "high"], alias: true, group: "Latest" },
      { id: "claude-opus-5", label: "Opus 5", hint: "For complex tasks · 1M context", efforts: ["low", "medium", "high", "xhigh", "max"], group: "Versions" },
      { id: "claude-sonnet-4-6", label: "Sonnet 4.6", hint: "claude-sonnet-4-6 · 1M context", efforts: ["low", "medium", "high"], group: "Versions" },
    ],
  },
  { id: "codex", label: "Codex", installed: true, version: "codex-cli 0.172.0", models: [{ id: "gpt-5.3-codex", label: "GPT-5.3 Codex", hint: "Optimised for agentic coding", efforts: ["low", "medium", "high", "xhigh"] }, { id: "gpt-5.6-sol", label: "GPT-5.6 Sol", hint: "Previous generation model for coding and everyday work", efforts: ["low", "medium", "high"] }] },
  { id: "cursor", label: "Cursor", installed: true, version: "2026.11.22", models: [{ id: "auto", label: "Auto", hint: "auto · current, default" }, { id: "composer-2.5", label: "Composer 2.5", hint: "composer-2.5" }, { id: "claude-sonnet-5-thinking-high", label: "Claude Sonnet 5 Thinking", hint: "claude-sonnet-5-thinking-high" }] },
  { id: "devin", label: "Devin", installed: true, version: "devin 3000.14", models: [{ id: "swe-2-medium", label: "SWE-2 Medium", group: "SWE-2", hint: "High cost · 262k context" }, { id: "claude-opus-5-5-medium", label: "Claude Opus 5.5 Medium", group: "Claude Opus 5.5", hint: "High cost · 1M context" }] },
];

module.exports = { seed, writeSessions, pulls, linear, ports, slack, usage, agents };
