// The run caches (summaries, costs, usage, search) answer from what's on
// disk: any write, by Bridge or anything else, must show on the next read,
// and a warm read must never parse a transcript again.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "bridge-cache-"));
process.env.BRIDGE_DATA_DIR = tmp;
process.env.BRIDGE_ENV_FILE = path.join(tmp, "none.env");
process.env.TARGET_REPO = path.join(tmp, "repo");
fs.mkdirSync(path.join(tmp, "repo"), { recursive: true });
const store = require("../server/store");
const projects = require("../server/projects");
test.after(() => fs.rmSync(tmp, { recursive: true, force: true }));

const file = (id) => path.join(store.PATHS.runs, `${id}.json`);
const now = () => Math.floor(Date.now() / 1000);

test("warm reads reuse the index instead of re-parsing transcripts", () => {
  const run = store.blankRun("big");
  run.messages = [{ role: "assistant", text: "needle " + "x".repeat(512 * 1024), ts: now(), cost: 1.5, agent: "codex", usage: { input: 10, output: 20 } }];
  store.saveRun(run);
  assert.equal(store.listRunSummaries()[0].messages, 1);
  assert.equal(store.summariseCost().total, 1.5);
  assert.equal(store.summariseUsage().codex.week.tokens, 30);
  assert.equal(store.searchRuns("needle")[0].runId, "big");
  // The first summary seeds data/projects.json, which re-stamps once.
  store.listRunSummaries();

  const original = fs.readFileSync;
  let reads = 0;
  fs.readFileSync = function (p, ...rest) {
    if (String(p).startsWith(store.PATHS.runs + path.sep)) reads++;
    return original.call(this, p, ...rest);
  };
  try {
    store.listRunSummaries();
    store.summariseCost();
    store.summariseUsage();
    store.searchRuns("needle");
    assert.equal(store.runSummary("big").runId, "big");
    assert.deepEqual(store.listRunSessions(), [{ runId: "big", sessionId: "", agentSessions: {}, imported: null }]);
  } finally {
    fs.readFileSync = original;
  }
  assert.equal(reads, 0, "a warm read never re-reads a transcript");
});

test("writes by anyone, new files, broken files and deletes all show", () => {
  const run = store.loadRun("big");
  run.who = "replaced";
  run.messages[0].cost = 2.5;
  run.messages[0].text = "haystack";
  const before = fs.statSync(file("big"));
  // An outside atomic replace that keeps the old mtime still changes the inode.
  fs.writeFileSync(file("big") + ".swap", JSON.stringify(run));
  fs.utimesSync(file("big") + ".swap", before.atime, before.mtime);
  fs.renameSync(file("big") + ".swap", file("big"));
  assert.equal(store.listRunSummaries()[0].who, "replaced");
  assert.equal(store.summariseCost().total, 2.5);
  assert.deepEqual(store.searchRuns("needle"), []);
  assert.equal(store.searchRuns("haystack").length, 1);

  fs.writeFileSync(file("outside"), JSON.stringify({ runId: "outside", who: "added", messages: [] }));
  fs.writeFileSync(file("broken"), "{");
  assert.equal(store.listRunSummaries().length, 2);
  fs.unlinkSync(file("outside"));
  fs.unlinkSync(file("broken"));
  assert.equal(store.listRunSummaries().length, 1);

  const gone = store.blankRun("gone");
  gone.messages = [{ role: "assistant", ts: now(), cost: 5, agent: "cursor" }];
  store.saveRun(gone);
  assert.equal(store.summariseCost().total, 7.5);
  store.deleteRun("gone");
  assert.equal(store.summariseCost().total, 2.5);
  assert.equal(store.summariseUsage().cursor, undefined);
});

test("a task's meta.json and the project list refresh the summary on their own", () => {
  const meta = path.join(tmp, "tasks", "big", "meta.json");
  fs.mkdirSync(path.dirname(meta), { recursive: true });
  fs.writeFileSync(meta, JSON.stringify({ status: "working", prUrl: "https://example.test/1" }));
  assert.equal(store.listRunSummaries()[0].task.status, "working");
  fs.writeFileSync(meta, JSON.stringify({ status: "ready-for-review", prUrl: "https://example.test/22" }));
  assert.equal(store.listRunSummaries()[0].prUrl, "https://example.test/22");
  fs.unlinkSync(meta);
  assert.equal(store.listRunSummaries()[0].task, null);

  // A run moved to a project that isn't in the list yet is Default's, until the list has it.
  const big = store.loadRun("big");
  store.saveRun({ ...big, project: "other" });
  assert.equal(store.listRunSummaries()[0].project, "default");
  fs.writeFileSync(projects.FILE, JSON.stringify([{ id: "other", name: "Other", path: tmp }]));
  assert.equal(store.listRunSummaries()[0].project, "other");
});

test("board and pin moves show at once", () => {
  store.setBoard("big", "review");
  store.setPinned("big", true);
  const s = store.listRunSummaries()[0];
  assert.equal(s.board, "review");
  assert.equal(s.pinned, true);
});
