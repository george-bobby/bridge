/**
 * Auto-archive of merged chats (harness.autoArchive), in-process on scratch
 * data with a fixture pulls feed: the wait in days, off, running and
 * hand-unarchived chats left alone.
 */

const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const os = require("os");
const path = require("path");

const tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "bridge-archive-")));
Object.assign(process.env, { BRIDGE_DATA_DIR: path.join(tmp, "data"), BRIDGE_ENV_FILE: path.join(tmp, "none.env"), BRIDGE_DEMO: "" });

const store = require("../server/store");
const harness = require("../server/harness");
test.after(() => fs.rmSync(tmp, { recursive: true, force: true }));

const DAY = 86400_000;
const NOW = Date.parse("2026-11-28T12:00:00Z");
const GH = "https://github.com/acme/web/pull";
const chat = (id, prUrl) => store.saveRun({ ...store.blankRun(id), kind: "task", prUrl });
const merged = (n, ago) => ({ url: `${GH}/${n}`, state: "MERGED", mergedAt: new Date(NOW - ago).toISOString() });
const archived = (id) => !!store.loadRun(id).archivedAt;
const pulls = { merged: [merged(1, 2 * DAY), merged(2, 3 * 3600_000), merged(3, 5 * DAY)] };

test("defaults to one day, clamps to the feed's 14-day window, 0 is off", () => {
  assert.strictEqual(store.readConfig().harness.autoArchiveDays, 1);
  assert.strictEqual(store.writeConfig({ harness: { autoArchiveDays: 40 } }).harness.autoArchiveDays, 14);
  assert.strictEqual(store.writeConfig({ harness: { autoArchiveDays: -2 } }).harness.autoArchiveDays, 0);
  assert.strictEqual(store.writeConfig({ harness: { autoArchiveDays: "" } }).harness.autoArchiveDays, 0, "blank keeps the value");
});

test("archives chats whose PR merged at least N days ago, and only those", () => {
  chat("old", `${GH}/1/`); // trailing slash: matched like the app does
  chat("fresh", `${GH}/2`);
  chat("open", `${GH}/9`);
  chat("none", "");
  chat("back", `${GH}/3`);
  store.setArchived("back", true);
  store.setArchived("back", false); // unarchived by hand: stays

  store.writeConfig({ harness: { autoArchiveDays: 0 } });
  assert.deepStrictEqual(harness.autoArchive(pulls, NOW), [], "off");

  store.writeConfig({ harness: { autoArchiveDays: 1 } });
  assert.deepStrictEqual(harness.autoArchive(pulls, NOW), ["old"]);
  assert.ok(archived("old"));
  for (const id of ["fresh", "open", "none", "back"]) assert.ok(!archived(id), `${id} kept`);

  assert.deepStrictEqual(harness.autoArchive(pulls, NOW + DAY), ["fresh"], "a day later the fresh one goes too");
  assert.deepStrictEqual(harness.autoArchive(pulls, NOW + DAY), [], "nothing twice");

  store.writeConfig({ harness: { autoArchiveDays: 3 } });
  chat("two-days", `${GH}/1`);
  assert.deepStrictEqual(harness.autoArchive(pulls, NOW), [], "merged 2 days ago waits for 3");
  assert.deepStrictEqual(harness.autoArchive({}, NOW), [], "no feed, nothing");
});
