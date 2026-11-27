const test = require("node:test");
const assert = require("node:assert");
const { parseReport } = require("../server/tasks");

test("parseReport reads the contract and is lenient about the rest", () => {
  const r = parseReport(`---
status: needs-input
pr: none (not opened)
---
## TL;DR
Half done.

## Open questions
- CSV or JSON? I recommend CSV
  because the export page already speaks it.
- Allow-list next=?

## Action requests
- None. Pushing was not requested; say so and I will push.
`);
  assert.equal(r.status, "needs-input");
  assert.equal(r.tldr, "Half done.");
  assert.equal(r.questions.length, 2);
  assert.match(r.questions[0], /because the export page/);
  assert.deepEqual(r.actions, []);
  assert.equal(r.fields.pr, "none (not opened)");

  assert.equal(parseReport("just prose, no frontmatter").status, "unknown");
  assert.deepEqual(parseReport("## Open questions\nNone\n").questions, []);
  assert.deepEqual(parseReport("## Action requests\n1. Post 'hi' in #eng\n").actions, ["Post 'hi' in #eng"]);
});

test("asks carry their options; old one-line asks still read", () => {
  const { parseAsk } = require("../server/tasks");
  const r = parseReport(`## Open questions
- Per API key or per IP?
  Why: B2B customers share an IP.
  A) Per key (recommended)
  B) Per IP
- Also limit v1?
  - A) Yes
  - B) No [recommended]

## For you
- Add \`CDN_TOKEN\` to .env.
`);
  assert.equal(r.questions.length, 2);
  assert.deepEqual(r.yours, ["Add `CDN_TOKEN` to .env."]);
  const a = parseAsk(r.questions[0]);
  assert.equal(a.question, "Per API key or per IP?");
  assert.equal(a.detail, "B2B customers share an IP.");
  assert.deepEqual(a.options, [
    { key: "A", label: "Per key", recommended: true },
    { key: "B", label: "Per IP", recommended: false },
  ]);
  assert.deepEqual(parseAsk(r.questions[1]).options.map((o) => [o.key, o.recommended]), [["A", false], ["B", true]]);
  const old = parseAsk("Build Option A? Recommended: yes, steps 1 to 3.");
  assert.equal(old.question, "Build Option A? Recommended: yes, steps 1 to 3.");
  assert.deepEqual(old.options, []);
});

test("a task's title skips a pasted file path in front of the ask", () => {
  const tasks = require("../server/tasks");
  assert.strictEqual(tasks.titleFrom("/Users/me/Downloads/CleanShot 2026-11-27 at 12.54.57 AM.png\n\nLet me reorder projects"), "Let me reorder projects");
  assert.strictEqual(tasks.titleFrom("# Fix login\nbody"), "Fix login");
  assert.strictEqual(tasks.titleFrom("Use /tmp/x.png here"), "Use /tmp/x.png here");
  assert.strictEqual(tasks.titleFrom("[Attached image, read it with your file tool: /Users/me/Library/Application Support/Bridge/attachments/pasted-ab12.png]\n\nWhy is this red?"), "Why is this red?");
  assert.strictEqual(tasks.titleFrom("[Attached image, read it with your file tool: /tmp/pasted-ab12.png]"), "Attached image");
  assert.strictEqual(tasks.titleFrom("/tmp/notes.txt"), "Attached file");
  assert.strictEqual(tasks.shownTitle("[Attached image, read it with your file tool: /tmp/a.png]", "[Attached image, read it with your file tool: /tmp/a.png]\nFix it"), "Fix it");
  assert.strictEqual(tasks.shownTitle("/Users/me/a.png", "/Users/me/a.png\nReal ask"), "Real ask");
  assert.strictEqual(tasks.shownTitle("Already fine", "whatever"), "Already fine");
});
