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
  checkCounts: { SUCCESS: { pass: 7, fail: 0, pending: 0, skipped: 1 }, FAILURE: { pass: 5, fail: 2, pending: 0, skipped: 1 }, PENDING: { pass: 4, fail: 0, pending: 3, skipped: 0 } }[o.checks || "SUCCESS"],
  mergeable: o.mergeable || "MERGEABLE",
  branch: o.branch || "",
  additions: o.add || 0,
  deletions: o.del || 0,
  comments: o.comments || 0,
  createdAt: iso((o.ago || 3600) + DAY),
  updatedAt: iso(o.ago || 3600),
  mergedAt: o.state === "MERGED" ? iso(o.ago || DAY) : null,
  issueKey: (title.match(/\b([A-Z]+-\d+)\b/) || [])[1] || "",
  previews: o.preview ? [{ provider: o.preview[0], url: o.preview[1], state: o.preview[2] || "ready", env: o.preview[0] === "vercel" ? "Preview – storefront" : "deploy-preview" }] : [],
});
const vercelPreview = (branch, state) => ["vercel", `https://storefront-git-${branch.replace(/[^a-z0-9]+/gi, "-").toLowerCase()}-acme.vercel.app`, state];
const netlify = (n, state) => ["netlify", `https://deploy-preview-${n}--acme-storefront.netlify.app`, state];

function pulls() {
  return {
    login: "alex-rivera",
    mine: [
      pr(482, "feat(checkout): Apple Pay in the payment step (WEB-124)", { branch: "alex/web-124-apple-pay", preview: vercelPreview("alex/web-124-apple-pay"), review: "REVIEW_REQUIRED", add: 612, del: 48, comments: 9, ago: 1500 }),
      pr(479, "feat(api): rate-limit the search endpoint per API key (WEB-131)", { branch: "alex/web-131-rate-limit-search", preview: vercelPreview("alex/web-131-rate-limit-search"), checks: "FAILURE", review: "CHANGES_REQUESTED", add: 288, del: 31, comments: 14, ago: 5400 }),
      pr(476, "test(e2e): stabilise the checkout flow suite (WEB-133)", { branch: "alex/web-133-flaky-e2e", preview: vercelPreview("alex/web-133-flaky-e2e", "building"), draft: true, checks: "PENDING", add: 74, del: 102, comments: 2, ago: 9000 }),
      pr(473, "fix(cart): show VAT-inclusive prices for EU shoppers", { branch: "alex/eu-vat-cart", preview: netlify(473), mergeable: "CONFLICTING", checks: "SUCCESS", review: "APPROVED", add: 131, del: 22, comments: 6, ago: 20000 }),
    ],
    review: [
      pr(485, "feat(checkout): promo codes with stacking rules (WEB-123)", { author: "maya-chen", branch: "maya/web-123-promo-codes", preview: vercelPreview("maya/web-123-promo-codes"), review: "REVIEW_REQUIRED", add: 540, del: 87, comments: 4, ago: 2600 }),
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

/** A PR's activity in `gh pr view --json` shape, run through the same
 *  shaping as the real one (server/changes.js). */
function prActivity(url) {
  const n = Number((String(url).match(/\/pull\/(\d+)/) || [])[1]);
  const p = pulls().mine.concat(pulls().review, pulls().merged).find((x) => x.number === n);
  if (!p) return null;
  const run = (name, conclusion, workflowName = "CI") => ({ __typename: "CheckRun", name, workflowName, status: conclusion ? "COMPLETED" : "IN_PROGRESS", conclusion: conclusion || "", detailsUrl: `${url}/checks` });
  const fixtures = {
    479: {
      checks: [run("lint", "SUCCESS"), run("unit", "SUCCESS"), run("e2e (chromium)", "FAILURE"), run("typecheck", "SUCCESS")],
      reviews: [{ author: { login: "sam-ortiz" }, state: "CHANGES_REQUESTED", body: "The limiter keys on `req.ip`, which is the load balancer behind our proxy. Use `X-Forwarded-For` (first hop) or key on the API key.", submittedAt: iso(5000) }],
      comments: [
        { author: { login: "priya-raman" }, body: "Could we return `Retry-After` with the 429? The mobile client already honours it.", createdAt: iso(4700), url: `${url}#issuecomment-1` },
        { author: { login: "alex-rivera" }, body: "Good call, adding it. Waiting on the per-key vs per-IP decision before reworking the keying.", createdAt: iso(4300), url: `${url}#issuecomment-2` },
      ],
      inline: [{ user: { login: "sam-ortiz" }, body: "This window resets on deploy since it's in-process. Redis?", path: "src/api/search/limit.ts", line: 42, created_at: iso(4990), html_url: `${url}#discussion_r1` }],
    },
    482: {
      checks: [run("lint", "SUCCESS"), run("unit", "SUCCESS"), run("e2e (chromium)", "SUCCESS"), run("e2e (webkit)", "SUCCESS")],
      reviews: [],
      comments: [{ author: { login: "maya-chen" }, body: "Tried it in Safari with the sandbox card, works. Needs someone from payments to sign off.", createdAt: iso(1200), url: `${url}#issuecomment-3` }],
      inline: [],
    },
  };
  const f = fixtures[n] || { checks: [run("ci", p.checks === "FAILURE" ? "FAILURE" : "SUCCESS")], reviews: [], comments: [], inline: [] };
  const raw = {
    number: p.number, title: p.title, url: p.url, state: p.state, isDraft: p.draft, reviewDecision: p.review, mergeable: p.mergeable,
    additions: p.additions, deletions: p.deletions, headRefName: p.branch, baseRefName: "main", updatedAt: p.updatedAt,
    comments: f.comments, reviews: f.reviews, statusCheckRollup: f.checks,
  };
  return { ...require("./changes").shapeActivity(raw, f.inline), previews: p.previews };
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
  slackUrl: o.slackUrl || "",
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
      issue("WEB-131", "Rate-limit the search API", "progress", { priority: 1, labels: [{ name: "backend", color: "#4ea7fc" }], ago: 5400, slackUrl: "https://acme.slack.com/archives/C02/p1732530002000200", description: "Search is being scraped. Add a limit that doesn't punish B2B customers behind shared NAT." }),
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
  ...(o.tasks ? { tasks: o.tasks } : {}),
});
const think = (text, tokens) => ({ kind: "thinking", text, tokens, streaming: false });
const say = (text) => ({ kind: "text", text, streaming: false });
const tool = (name, detail, result = "", ok = true) => ({ kind: "tool", name, detail, result, ok, resultLines: result ? result.split("\n").length : 0 });
/** Where the demo's background command writes; seed() fills it in. */
let demoDir = require("os").tmpdir();
const BG_OUT = () => path.join(demoDir, "tasks", "bk9x2m4q.output");
const csvTasks = () => [
  {
    id: "a3f9c2e1", toolUseId: "tu-demo-callers", type: "agent", subagentType: "Explore", description: "Find every caller of paginateRows", status: "completed",
    prompt: "Find every caller of paginateRows() in src/ and say which exports each one feeds. Read-only: don't edit anything.",
    startedAt: (now() - 2280) * 1000, endedAt: (now() - 2190) * 1000, tokens: 18400, toolUses: 4, lastTool: "Read",
    summary: "Three callers, all exports: `csv.ts:31` (CSV download), `xlsx.ts:27` (XLSX download) and `api/orders.ts:88` (the API's `?format=csv`). Each slices rows with the page bounds it returns, so one fix in `paginateRows()` covers all three.",
    steps: [
      tool("Grep", "paginateRows src/", "src/export/paginate.ts:14\nsrc/export/csv.ts:31\nsrc/export/xlsx.ts:27\nsrc/api/orders.ts:88"),
      tool("Read", "src/export/csv.ts", "for (const [from, to] of paginateRows(rows.length, PAGE)) {\n  out.push(...rows.slice(from, to).map(toCsvLine));\n}"),
      tool("Read", "src/export/xlsx.ts", "paginateRows(total, 50).forEach(([a, b]) => sheet.addRows(rows.slice(a, b)));"),
      tool("Read", "src/api/orders.ts", "if (q.format === 'csv') return streamCsv(paginateRows(count, 100), rows);"),
      say("Three callers, all exports. One fix in `paginateRows()` covers CSV, XLSX and the API."),
    ],
  },
  {
    id: "b71d04aa", toolUseId: "tu-demo-repro", type: "agent", subagentType: "general-purpose", description: "Write a failing test for the last page", status: "running", background: true,
    prompt: "Add a test to src/export/paginate.test.ts that exports 41 rows with a page size of 20 and expects 3 pages. Run it and confirm it fails on main.",
    startedAt: (now() - 400) * 1000, tokens: 9600, toolUses: 3, lastTool: "Bash", activity: "Running the export tests",
    steps: [
      tool("Read", "src/export/paginate.test.ts", "describe('paginateRows', () => {\n  it('splits evenly', () => { … })\n})"),
      tool("Edit", "src/export/paginate.test.ts"),
      { kind: "tool", name: "Bash", detail: "npx vitest run src/export/paginate.test.ts", id: "tu-demo-sub-run" },
    ],
  },
  {
    id: "bk9x2m4q", toolUseId: "tu-demo-bg", type: "bash", background: true, description: "Export suite in watch mode", command: "npm test -- export --watch", status: "running",
    startedAt: (now() - 360) * 1000, outputFile: BG_OUT(),
  },
];

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
            { ...tool("Agent", "Find every caller of paginateRows", "Three callers, all exports: csv.ts, xlsx.ts and api/orders.ts."), id: "tu-demo-callers" },
            { ...tool("Agent", "Write a failing test for the last page", "Async agent launched successfully."), id: "tu-demo-repro" },
            { ...tool("Bash", "npm test -- export --watch", "Command running in background with ID: bk9x2m4q."), id: "tu-demo-bg", raw: JSON.stringify({ command: "npm test -- export --watch", run_in_background: true }) },
            { ...tool("AskUserQuestion", "Scope of the fix"), ask: csvAsk },
          ],
          { kind: "pipeline", label: "pipeline", state: "running", model: "opus", tasks: csvTasks() },
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
        user("Add Apple Pay to the checkout payment step (WEB-124), behind the `wallets` flag. Use the existing Stripe Payment Request integration.", 3 * 3600),
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
        event("Report: PR #482 opened", 1500, "outcome"),
        user('Does the button show up on Chrome for desktop too, or only Safari?', 1400),
        claude(1360, [say('Only where `canMakePayment()` says Apple Pay is available: Safari on macOS and iOS. Chrome gets Google Pay through the same Payment Request Button when the flag is on, which is what we want.')], { cost: 0.3, ms: 40000, turns: 3, workdir: `${WT}/alex-web-124-apple-pay` }),
        user("Let's keep Google Pay out of this PR. Can you scope it to Apple Pay only?", 1280),
        claude(1240, [say("Done. `paymentRequest` now passes `wallets: { applePay: 'auto', googlePay: 'never' }`, so Chrome falls back to the card form. Tests updated.")], { cost: 0.3, ms: 40000, turns: 3, workdir: `${WT}/alex-web-124-apple-pay` }),
        user('What happens if the user cancels the Apple Pay sheet?', 1160),
        claude(1120, [say('The `cancel` event resets `submitting` and keeps the card form visible below the button. No order is created until `paymentmethod` fires, so a cancel leaves nothing behind.')], { cost: 0.3, ms: 40000, turns: 3, workdir: `${WT}/alex-web-124-apple-pay` }),
        user('Add a test for the cancel path.', 1040),
        claude(1000, [say('Added `wallets.test.tsx › cancel keeps the card form`: it fires `cancel` on the mocked request and asserts no `createOrder` call. 21 tests pass.')], { cost: 0.3, ms: 40000, turns: 3, workdir: `${WT}/alex-web-124-apple-pay` }),
        user('The domain association file: is it served with the right content type?', 920),
        claude(880, [say("It's served as `application/octet-stream` by the static handler, which Apple accepts. I added a test that fetches `/.well-known/apple-developer-merchantid-domain-association` and checks a 200.")], { cost: 0.3, ms: 40000, turns: 3, workdir: `${WT}/alex-web-124-apple-pay` }),
        user('Can we log when Apple Pay is offered vs used, for the rollout dashboard?', 800),
        claude(760, [say("Two analytics events: `wallet_offered` when the button renders and `wallet_used` on `paymentmethod`, both with `{ wallet: 'apple_pay' }`. They go through the existing `track()` helper.")], { cost: 0.3, ms: 40000, turns: 3, workdir: `${WT}/alex-web-124-apple-pay` }),
        user('Rename the events to checkout_wallet_offered and checkout_wallet_used to match our naming.', 680),
        claude(640, [say('Renamed both, and updated the event catalog in `docs/analytics.md`.')], { cost: 0.3, ms: 40000, turns: 3, workdir: `${WT}/alex-web-124-apple-pay` }),
        user('Payments review asked about 3DS. Do we handle it?', 560),
        claude(520, [say("Yes: when the PaymentIntent comes back `requires_action`, we call `stripe.handleNextAction` before confirming the order, same as the card path. Added a test with Stripe's 3DS test card token.")], { cost: 0.3, ms: 40000, turns: 3, workdir: `${WT}/alex-web-124-apple-pay` }),
        user('Squash the fixups and push, then summarize the PR for the reviewer.', 440),
        claude(400, [say('Pushed a clean history (3 commits) to **#482**.\n\n- Apple Pay only (Google Pay off), behind `wallets`\n- Cancel and 3DS paths covered; 23 checkout tests pass\n- `checkout_wallet_offered` / `checkout_wallet_used` events for the rollout dashboard')], { cost: 0.3, ms: 40000, turns: 3, workdir: `${WT}/alex-web-124-apple-pay` }),
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
        user("Rate-limit `/api/search` (WEB-131). Scrapers are hammering it.", 6 * 3600),
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
  fs.writeFileSync(marker, "Demo data from server/demo.js. Rebuilt on every `npm run demo`.\n");
  writeSessions(dataDir);
  fs.writeFileSync(path.join(tdir, "bk9x2m4q.output"), [" RUN  v3.2.4 /Users/you/Development/storefront", "", " ✓ src/export/csv.test.ts (6 tests) 41ms", " ✓ src/export/xlsx.test.ts (4 tests) 58ms", " ✗ src/export/paginate.test.ts > paginateRows > emits the final partial page", "   → expected [ [0, 20], [20, 40] ] to deeply equal [ [0, 20], [20, 40], [40, 41] ]", "", " Test Files  1 failed | 2 passed (3)", "      Tests  1 failed | 10 passed (11)", "", " Watching for file changes..."].join("\n") + "\n");
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
  demoDir = dataDir;
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
      return { ts, user: "", threadTs: ts, channelId: "C0DEMO", channel: t.channel, who: m[0], avatar: "", text: m[1], permalink: `https://acme.slack.com/archives/C0DEMO/p${ts.replace(".", "")}` };
    }),
  thread: async ({ channelId, threadTs }) => {
    const t = THREADS[threadTs] || { channel: "#general", messages: [["Someone", "(a thread from the demo workspace)", 600]] };
    return { channelId, threadTs, channel: t.channel, messages: t.messages.map(([who, text, ago], i) => ({ ts: `${now() - ago}.00000${i}`, user: "", who, avatar: "", text, files: [] })) };
  },
  reply: async () => {
    throw new Error("the demo workspace doesn't post replies");
  },
  history: async () => [],
  replies: async () => [],
  channels: async () => [
    { id: "C0BUGS", name: "#eng-bugs", private: false },
    { id: "C0OPS", name: "#ops", private: false },
    { id: "C0SUPPORT", name: "#support", private: false },
  ],
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
      { id: "cursor", label: "Cursor", status: "ok", plan: "Enterprise", account: "alex@acme.dev", fetchedAt: Date.now(), windows: [
        { id: "spend", label: "Monthly spend", short: "mo", usedPct: 31, resetsAt: h(17 * 24), duration: 2592000 },
      ], details: [{ label: "Spend", value: "$310.40 of $1,000.00" }, { label: "Team", value: "Acme" }], local: local(3, 240_000, 0) },
      { id: "devin", label: "Devin", status: "ok", plan: "", account: "", fetchedAt: Date.now(), windows: [], details: [{ label: "Plan usage", value: "Devin doesn't publish plan limits; ACUs below are from turns Bridge ran", info: true }], local: local(4, 510_000, 0, 1.8) },
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

/* ---------------------------------------------------------------- MCP */

const mcpTool = (name, description, o = {}) => ({ name, title: "", description, readOnly: !!o.ro, destructive: !!o.danger, params: (o.params || []).map(([n, type, required, d]) => ({ name: n, type, required, description: d || "" })) });
const MCP_TOOLS = {
  github: [
    mcpTool("search_issues", "Search issues and pull requests across GitHub", { ro: true, params: [["q", "string", true, "GitHub search syntax"], ["per_page", "number", false]] }),
    mcpTool("get_pull_request", "Details of one pull request", { ro: true, params: [["owner", "string", true], ["repo", "string", true], ["number", "number", true]] }),
    mcpTool("create_pull_request", "Open a pull request", { params: [["title", "string", true], ["head", "string", true], ["base", "string", true], ["body", "string", false]] }),
    mcpTool("merge_pull_request", "Merge a pull request", { danger: true, params: [["number", "number", true], ["method", "string", false, "merge, squash or rebase"]] }),
  ],
  linear: [
    mcpTool("list_issues", "Issues matching a filter", { ro: true, params: [["team", "string", false], ["assignee", "string", false]] }),
    mcpTool("get_issue", "One issue with its comments", { ro: true, params: [["id", "string", true]] }),
    mcpTool("create_issue", "Create an issue", { params: [["title", "string", true], ["team", "string", true], ["description", "string", false]] }),
    mcpTool("update_issue", "Change an issue's state, assignee or labels", { params: [["id", "string", true], ["state", "string", false]] }),
  ],
  postgres: [mcpTool("query", "Run a read-only SQL query", { ro: true, params: [["sql", "string", true]] }), mcpTool("list_tables", "Tables in the public schema", { ro: true })],
  playwright: [
    mcpTool("browser_navigate", "Open a URL", { params: [["url", "string", true]] }),
    mcpTool("browser_snapshot", "Accessibility snapshot of the page", { ro: true }),
    mcpTool("browser_click", "Click an element", { params: [["ref", "string", true]] }),
    mcpTool("browser_take_screenshot", "Screenshot the page", { ro: true }),
  ],
  sentry: [mcpTool("search_issues", "Sentry issues by query", { ro: true, params: [["query", "string", true]] }), mcpTool("get_event", "One event with its stack trace", { ro: true, params: [["id", "string", true]] })],
  docs: [mcpTool("search", "Search the docs", { ro: true, params: [["query", "string", true]] })],
};
const mcpServer = (agent, name, o) => ({
  name, agent, type: o.url ? "http" : "stdio", command: o.command || "", args: o.args || [], envKeys: o.envKeys || [], cwd: "", url: o.url || "", headerKeys: o.headerKeys || [], bearerEnv: "",
  scope: o.scope || "user", source: o.source, enabled: o.enabled !== false, editable: o.editable !== false, removable: o.editable !== false, toggleable: o.toggleable !== false,
  sharedWith: o.sharedWith || [], note: o.note || "", status: o.enabled === false ? "disabled" : o.status || "connected", error: o.error || "", serverInfo: null,
  toolCount: MCP_TOOLS[o.tools] ? MCP_TOOLS[o.tools].length : null, tools: MCP_TOOLS[o.tools] ? MCP_TOOLS[o.tools].map((t) => ({ name: t.name, readOnly: t.readOnly, destructive: t.destructive })) : null, disabledTools: [], checkedAt: Date.now(),
});
const mcpState = {
  claude: [
    mcpServer("claude", "github", { command: "npx", args: ["-y", "@modelcontextprotocol/server-github"], envKeys: ["GITHUB_TOKEN"], source: "~/.claude.json", tools: "github" }),
    mcpServer("claude", "postgres", { command: "uvx", args: ["mcp-postgres", "--read-only"], envKeys: ["DATABASE_URL"], source: "~/.claude.json", tools: "postgres" }),
    mcpServer("claude", "playwright", { command: "npx", args: ["@playwright/mcp@latest"], source: "~/.claude.json · this project", scope: "local", tools: "playwright" }),
    mcpServer("claude", "sentry", { url: "https://mcp.sentry.dev/mcp", source: "~/.claude.json", status: "needs-auth", error: "mcp.sentry.dev wants a sign-in (401)" }),
    mcpServer("claude", "claude.ai Linear", { url: "https://mcp.linear.app/mcp", scope: "claudeai", source: "claude.ai connector", editable: false, note: "Managed on claude.ai. On/off applies to this project", tools: "linear" }),
    mcpServer("claude", "claude.ai Docs", { url: "https://docs.acme.dev/mcp", scope: "claudeai", source: "claude.ai connector", editable: false, enabled: false, note: "Managed on claude.ai. On/off applies to this project" }),
  ],
  codex: [
    mcpServer("codex", "github", { command: "npx", args: ["-y", "@modelcontextprotocol/server-github"], envKeys: ["GITHUB_TOKEN"], source: "~/.codex/config.toml", tools: "github" }),
    mcpServer("codex", "docs", { url: "https://docs.acme.dev/mcp", source: "~/.codex/config.toml", tools: "docs" }),
    mcpServer("codex", "postgres", { command: "uvx", args: ["mcp-postgres", "--read-only"], envKeys: ["DATABASE_URL"], source: "~/.codex/config.toml", enabled: false }),
  ],
  cursor: [
    mcpServer("cursor", "linear", { url: "https://mcp.linear.app/mcp", source: "~/.cursor/mcp.json", status: "signed-in", tools: "linear", sharedWith: ["devin"] }),
    mcpServer("cursor", "playwright", { command: "npx", args: ["@playwright/mcp@latest"], source: "~/.cursor/mcp.json", tools: "playwright", sharedWith: ["devin"] }),
    mcpServer("cursor", "sentry", { url: "https://mcp.sentry.dev/mcp", source: "~/.cursor/mcp.json", status: "failed", error: "couldn't reach mcp.sentry.dev (ENOTFOUND)", sharedWith: ["devin"] }),
  ],
  devin: [
    mcpServer("devin", "linear", { url: "https://mcp.linear.app/mcp", scope: "shared", source: "~/.cursor/mcp.json", status: "oauth", error: "Signs in through Devin; Bridge can't see its login", tools: "linear", sharedWith: ["cursor"], note: "Devin loads this from Cursor's ~/.cursor/mcp.json: changes apply to Cursor too" }),
    mcpServer("devin", "playwright", { command: "npx", args: ["@playwright/mcp@latest"], scope: "shared", source: "~/.cursor/mcp.json", tools: "playwright", sharedWith: ["cursor"], note: "Devin loads this from Cursor's ~/.cursor/mcp.json: changes apply to Cursor too" }),
    mcpServer("devin", "github", { url: "https://api.githubcopilot.com/mcp/", scope: "plugin", source: "Plugin github", editable: false, tools: "github", note: "From a Devin plugin. Disabling adds an override to ~/.config/devin/mcp_config.json" }),
  ],
};
const MCP_FILES = { claude: ["~/.claude.json"], codex: ["~/.codex/config.toml"], cursor: ["~/.cursor/mcp.json"], devin: ["~/.config/devin/mcp_config.json", "~/.cursor/mcp.json"] };
const MCP_LABEL = { claude: "Claude", codex: "Codex", cursor: "Cursor", devin: "Devin" };
const mcpFind = (agent, name) => {
  const s = (mcpState[agent] || []).find((x) => x.name === name);
  if (!s) throw new Error(`no MCP server called ${name}`);
  return s;
};
const mcp = {
  list: async (agent) => ({ agent, label: MCP_LABEL[agent], installed: true, servers: mcpState[agent], checking: false, files: MCP_FILES[agent], dir: REPO }),
  all: async () => ({ agents: Object.keys(mcpState).map((a) => ({ agent: a, label: MCP_LABEL[a], installed: true, servers: mcpState[a], checking: false, files: MCP_FILES[a], dir: REPO })) }),
  tools: async (agent, name) => {
    const s = mcpFind(agent, name);
    const key = Object.keys(MCP_TOOLS).find((k) => s.tools && MCP_TOOLS[k].length === s.toolCount && MCP_TOOLS[k][0].name === s.tools[0].name);
    return key ? { name, tools: MCP_TOOLS[key], source: "server" } : { name, tools: [], source: "none", status: s.status, error: s.error || "Couldn't list this server's tools" };
  },
  save: async (agent, { name, original, form }) => {
    const list = mcpState[agent];
    if (!original && list.some((x) => x.name === name)) throw new Error(`${MCP_LABEL[agent]} already has a server called ${name}`);
    const prev = original ? mcpFind(agent, original) : null;
    const next = mcpServer(agent, name, { command: form.command, args: form.args, url: form.type === "stdio" ? "" : form.url, envKeys: (form.env || []).map((e) => e.key).filter(Boolean), headerKeys: (form.headers || []).map((e) => e.key).filter(Boolean), source: MCP_FILES[agent][0], status: "unknown" });
    if (prev) list.splice(list.indexOf(prev), 1, { ...next, enabled: prev.enabled, status: prev.enabled ? "unknown" : "disabled" });
    else list.push(next);
    return { name };
  },
  remove: async (agent, name) => {
    const list = mcpState[agent];
    list.splice(list.indexOf(mcpFind(agent, name)), 1);
    return { removed: name };
  },
  setEnabled: async (agent, name, on) => {
    const s = mcpFind(agent, name);
    s.enabled = on;
    s.status = on ? (s.toolCount ? "connected" : "unknown") : "disabled";
    return { name, enabled: on };
  },
  login: () => ({ started: true }),
};

/** New task's workspace pickers: the storefront repo's branches and worktrees. */
const git = () => ({
  repo: REPO,
  default: "main",
  current: "main",
  branches: [
    { name: "main", remote: false, date: now() - 3600, subject: "Merge #479: faster product grid", worktree: REPO, default: true },
    { name: "alex/web-124-apple-pay", remote: false, date: now() - 5400, subject: "Apple Pay behind the wallets flag", worktree: `${WT}/alex-web-124-apple-pay`, default: false },
    { name: "alex/web-131-rate-limit", remote: false, date: now() - 9000, subject: "Rate-limit search per API key", worktree: `${WT}/alex-web-131-rate-limit`, default: false },
    { name: "release/2026.11", remote: false, date: now() - 2 * DAY, subject: "Cut 2026.11", worktree: "", default: false },
    { name: "origin/maya/vat-cart", remote: true, date: now() - 3 * DAY, subject: "Show VAT-inclusive prices in the cart", worktree: "", default: false },
    { name: "origin/kai/sitemap-cdn", remote: true, date: now() - 4 * DAY, subject: "Sitemap: use CDN URLs", worktree: "", default: false },
  ],
  worktrees: [
    { path: REPO, branch: "main", head: "a41c9e2", main: true, name: "storefront" },
    { path: `${WT}/alex-web-124-apple-pay`, branch: "alex/web-124-apple-pay", head: "7d02b1f", main: false, name: "alex-web-124-apple-pay" },
    { path: `${WT}/alex-web-131-rate-limit`, branch: "alex/web-131-rate-limit", head: "c93e0aa", main: false, name: "alex-web-131-rate-limit" },
  ],
});

/** Chats from the agents' own histories (Import chat), all fictional. */
const historyChats = () => [
  { agent: "claude", id: "5b1f0c3e-7a2d-4f61-9e0b-2c8d4a6e1f90", title: "Debounce the search box on the catalog page", prompt: "The catalog search fires a request on every keystroke. Debounce it to 250ms and cancel stale requests.", cwd: REPO, branch: "main", createdAt: now() - 3 * 86400, updatedAt: now() - 2 * 3600 },
  { agent: "codex", id: "01a2b3c4-d5e6-4f70-8a9b-0c1d2e3f4a5b", title: "Why does the nightly export job time out?", prompt: "Why does the nightly export job time out? Look at the cron logs and the export worker.", cwd: REPO, branch: "", createdAt: now() - 5 * 86400, updatedAt: now() - 26 * 3600 },
  { agent: "cursor", id: "c0ffee12-3456-4789-abcd-ef0123456789", title: "Dark mode for the order emails", prompt: "Add a dark-mode variant to the order confirmation email templates.", cwd: `${WT}/web-140-dark-emails`, branch: "", createdAt: now() - 7 * 86400, updatedAt: now() - 3 * 86400 },
  { agent: "devin", id: "quiet-harbor", title: "Upgrade the payments SDK to v5", prompt: "Upgrade the payments SDK to v5 and fix the breaking changes.", cwd: REPO, branch: "", createdAt: now() - 9 * 86400, updatedAt: now() - 4 * 86400 },
  { agent: "claude", id: "8e2d6a10-4b3c-4d9e-a1f2-7c6b5a4d3e21", title: "Flaky checkout e2e test on CI", prompt: "The checkout e2e test fails one run in five on CI. Find out why.", cwd: "/Users/you/Development/mobile", branch: "main", createdAt: now() - 12 * 86400, updatedAt: now() - 6 * 86400 },
];

const history = {
  AGENTS: ["claude", "codex", "cursor", "devin"],
  known: (runs) => require("./history").known(runs),
  list({ agents, q = "", runs = [] } = {}) {
    const have = history.known(runs);
    const words = String(q).toLowerCase().split(/\s+/).filter(Boolean);
    const all = historyChats().filter((c) => !agents || agents.includes(c.agent));
    const chats = all.filter((c) => words.every((w) => `${c.title} ${c.prompt} ${c.cwd}`.toLowerCase().includes(w))).map((c) => ({ ...c, size: 0, gone: false, runId: have.get(`${c.agent}:${c.id}`) || "" }));
    const counts = {};
    for (const c of all) counts[c.agent] = (counts[c.agent] || 0) + 1;
    return { chats, counts, sqlite: true };
  },
  read(agent, id) {
    const c = historyChats().find((x) => x.agent === agent && x.id === id);
    if (!c) throw new Error("no such chat");
    const at = c.updatedAt;
    const step = (name, detail, result) => ({ kind: "tool", name, detail, id: `${id}-${name}`, raw: JSON.stringify({ command: detail }), result, ok: true, resultLines: result.split("\n").length });
    return {
      cwd: c.cwd,
      messages: [
        { role: "user", text: c.prompt, ts: at - 600, imported: true },
        { role: "assistant", kind: "imported", label: "imported", agent, model: "", state: "done", workdir: c.cwd, ts: at - 540, imported: true, text: "Found it.", steps: [step("Bash", "rg -n 'search' src/catalog", "src/catalog/Search.tsx:14:  onChange={(e) => fetchResults(e.target.value)}"), { kind: "text", text: "Found it: every keystroke calls `fetchResults`. I'll wrap it in a 250ms debounce and abort the previous request." }] },
      ],
    };
  },
};

/* ------------------------------------------- Vercel, incident.io, Granola */

function vercel() {
  const d = (n, project, branch, state, ago, o = {}) => ({
    id: `dpl_${n}`, project, url: `https://${project}-${n}-acme.vercel.app`, inspect: `https://vercel.com/acme/${project}/${n}`,
    state, target: o.target || "preview", branch, message: o.message || "", pr: o.pr || null, repo: `acme/${project}`,
    creator: o.creator || "alex-rivera", team: "acme", createdAt: (now() - ago) * 1000,
  });
  return {
    configured: true, user: "alex-rivera", teams: ["acme"],
    deployments: [
      d("9fk2a", "storefront", "alex/web-133-flaky-e2e", "building", 240, { message: "test(e2e): retry the payment iframe once", pr: 476 }),
      d("7hq1c", "storefront", "alex/web-124-apple-pay", "ready", 1500, { message: "feat(checkout): Apple Pay in the payment step", pr: 482 }),
      d("6bb0d", "storefront", "main", "ready", 3600, { target: "production", message: "Merge #470: keep the dark-mode choice", creator: "sam-ortiz" }),
      d("5xx8e", "storefront", "alex/web-131-rate-limit-search", "failed", 5400, { message: "feat(api): per-key limiter", pr: 479 }),
      d("4mm2f", "docs", "maya/checkout-guide", "ready", 9000, { message: "docs: the new checkout guide", creator: "maya-chen" }),
      d("3pp7g", "storefront", "maya/web-123-promo-codes", "ready", 2600, { message: "feat(checkout): promo codes", pr: 485, creator: "maya-chen" }),
      d("2zz5h", "admin", "main", "ready", DAY, { target: "production", message: "chore: bump deps", creator: "priya-raman" }),
      d("1aa3k", "storefront", "sam/next-15-2", "canceled", 7300, { message: "chore(deps): Next.js 15.2", pr: 488, creator: "sam-ortiz" }),
    ].sort((a, b) => b.createdAt - a.createdAt),
    at: Date.now(),
  };
}

function incidents() {
  const i = (n, name, category, status, severity, rank, ago, o = {}) => ({
    id: `01H${n}`, ref: `INC-${n}`, name, summary: o.summary || "", status, category, severity, severityRank: rank,
    lead: o.lead || "", url: `https://app.incident.io/acme/incidents/${n}`, slack: "", createdAt: iso(ago), updatedAt: iso(o.updated || ago / 2),
  });
  return {
    configured: true,
    incidents: [
      i(214, "Checkout 502s for EU shoppers", "live", "Investigating", "Major", 3, 1900, { lead: "Sam Ortiz", summary: "The EU edge returns 502 on POST /checkout for ~4% of requests since the 14:10 deploy." }),
      i(213, "Search latency above 2s p95", "live", "Monitoring", "Minor", 1, 7200, { lead: "Alex Rivera", summary: "Rate limiter rollout; watching p95 after the Redis fix." }),
      i(212, "Order emails show the wrong currency for CAD", "learning", "Post-incident", "Minor", 1, 2 * DAY, { lead: "Priya Raman" }),
      i(209, "Image CDN cache misses after the move", "closed", "Closed", "Minor", 1, 5 * DAY, { lead: "Maya Chen" }),
      i(205, "Login loop on Safari 17", "closed", "Closed", "Major", 3, 9 * DAY, { lead: "Kai Nakamura" }),
    ],
    at: Date.now(),
  };
}

const NOTES = [
  ["not_1", "Checkout sync", 3 * 3600, ["Alex Rivera", "Maya Chen", "Sam Ortiz"], "## Decisions\n- Ship Apple Pay behind the `wallets` flag on Monday\n- Google Pay waits for the Stripe upgrade\n\n## Action items\n- **Alex**: payments sign-off on #482\n- **Sam**: fix the EU 502s before the rollout"],
  ["not_2", "Search rate limits with the API team", 26 * 3600, ["Alex Rivera", "Priya Raman"], "## Summary\nLimit per API key, not per IP: B2B customers share NAT.\n\n## Next\n- Return `Retry-After` with 429s\n- Redis-backed window"],
  ["not_3", "1:1 Alex / Sam", 3 * DAY, ["Alex Rivera", "Sam Ortiz"], "## Notes\n- On-call handover next week\n- Flaky e2e suite: quarantine, then fix"],
  ["not_4", "Incident review: CAD currency", 4 * DAY, ["Priya Raman", "Alex Rivera", "Kai Nakamura"], "## What happened\nThe email template read the store's default currency.\n\n## Follow-ups\n- Template tests per currency"],
];

function granola() {
  return { configured: true, notes: NOTES.map(([id, title, ago]) => ({ id, title, owner: "Alex Rivera", createdAt: iso(ago), updatedAt: iso(ago - 600) })), at: Date.now() };
}

function granolaNote(id) {
  const n = NOTES.find((x) => x[0] === id);
  if (!n) throw new Error("no such note");
  return { id, title: n[1], url: `https://notes.granola.ai/d/${id}`, attendees: n[3], event: n[1], summary: n[4], createdAt: iso(n[2]) };
}

module.exports = { seed, writeSessions, pulls, linear, ports, slack, usage, agents, prActivity, mcp, git, history, vercel, incidents, granola, granolaNote };
