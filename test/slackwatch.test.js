/**
 * The Slack watcher against a fixture connector, in-process, on scratch data:
 * watermark, filing into the Inbox vs into a chat, channels, triage relay.
 */

const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const os = require("os");
const path = require("path");

const tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "sb-slackwatch-")));
Object.assign(process.env, { SB_DATA_DIR: path.join(tmp, "data"), BRIDGE_ENV_FILE: path.join(tmp, "none.env"), SLACK_USER_NAME: "Alex", BRIDGE_DEMO: "" });

const store = require("../lib/store");
const tasks = require("../lib/tasks");
const harness = require("../lib/harness");
const watch = require("../lib/slackwatch");

const T = Math.floor(Date.now() / 1000);
const ts = (n) => `${T + n}.000100`;
const link = (c, t) => `https://acme.slack.com/archives/${c}/p${t.replace(".", "")}`;
const fake = {
  ms: [],
  hist: {},
  rep: {},
  configured: () => true,
  status: async () => ({ configured: true, userId: "UME" }),
  mentions: async () => [...fake.ms].sort((a, b) => Number(b.ts) - Number(a.ts)),
  history: async ({ channelId, oldest }) => (fake.hist[channelId] || []).filter((m) => Number(m.ts) > Number(oldest)),
  replies: async ({ threadTs, oldest }) => (fake.rep[threadTs] || []).filter((m) => Number(m.ts) > Number(oldest)),
};
const mention = (n, { user = "UBOB", thread = n, who = "Bob", channelId = "C1" } = {}) => ({
  ts: ts(n),
  user,
  threadTs: ts(thread),
  channelId,
  channel: "#eng",
  who,
  text: `ping ${n}`,
  permalink: link(channelId, ts(n)) + (thread !== n ? `?thread_ts=${ts(thread)}&cid=${channelId}` : ""),
});

watch.useConnector(fake);
store.writeConfig({ harness: { slackWatch: "triage", mode: "away", relay: true } });
const awayQueue = () => JSON.parse(fs.readFileSync(path.join(tasks.DIR, "away-queue.json"), "utf8"));

test("a first poll only sets the watermark", async () => {
  fake.ms = [mention(-100)];
  await watch.poll();
  assert.equal(watch.open().length, 0);
  assert.ok(watch.status().watching);
});

test("a new mention becomes one Inbox item per thread; your own are ignored", async () => {
  fake.ms.push(mention(10), mention(11, { user: "UME", who: "Alex" }));
  const out = await watch.poll();
  assert.equal(out.fresh, 1);
  const [item] = watch.open();
  assert.equal(item.who, "Bob");
  assert.equal(item.kind, "mention");
  fake.ms.push(mention(12, { thread: 10 }));
  await watch.poll();
  assert.equal(watch.open().length, 1);
  assert.equal(watch.open()[0].count, 2);
  assert.equal(harness.inbox().counts.slack, 1);
});

test("triage mode hands new items to the orchestrator, held while away", () => {
  const held = awayQueue();
  assert.equal(held.length, 1, "the second message in the same thread isn't a new item");
  assert.match(held[0].text, /SLACK 1 new item/);
  assert.match(held[0].text, /untrusted data/);
  assert.ok(held[0].text.includes(watch.open()[0].id));
});

test("a skip verdict stays visible but leaves the count; dismiss closes it", () => {
  const id = watch.open()[0].id;
  watch.triage(id, "skip", "social");
  assert.equal(watch.open()[0].verdict, "skip");
  assert.equal(harness.inbox().counts.slack, 0);
  watch.dismiss(id);
  assert.equal(watch.open().length, 0);
  assert.throws(() => watch.triage(id, "maybe"), /actionable or skip/);
});

test("a thread with a chat: mentions and replies go into the chat, undelivered, not the Inbox", async () => {
  const { run } = store.createFromLink(link("C2", ts(20)));
  await watch.poll(); // first sync of this chat only marks it
  fake.rep[ts(20)] = [{ ts: ts(21), user: "UCAT", who: "Cat", text: "more detail" }];
  fake.ms.push(mention(22, { thread: 20, channelId: "C2", who: "Dan", user: "UDAN" }));
  const out = await watch.poll();
  assert.equal(out.followups, 2);
  const msgs = store.loadRun(run.runId).messages.filter((m) => m.role === "slack");
  assert.deepEqual(msgs.map((m) => [m.who, m.undelivered]), [["Cat", true], ["Dan", true]]);
  assert.equal(watch.open().length, 0);
  await watch.poll();
  assert.equal(store.loadRun(run.runId).messages.filter((m) => m.role === "slack").length, 2, "no duplicates");
});

test("watched channels: marked on first sight, then new top-level posts are filed", async () => {
  store.writeConfig({ harness: { slackChannels: ["C0WATCH"] } });
  await watch.poll();
  fake.hist.C0WATCH = [{ ts: ts(40), user: "UEVE", threadTs: ts(40), channelId: "C0WATCH", channel: "#ops", who: "Eve", text: "deploy is red", permalink: link("C0WATCH", ts(40)) }];
  await watch.poll();
  const item = watch.open().find((i) => i.channelId === "C0WATCH");
  assert.equal(item.kind, "channel");
  assert.equal(item.who, "Eve");
});

test("an item whose thread got a chat stays started after that chat is deleted", async () => {
  const item = watch.open().find((i) => i.channelId === "C0WATCH");
  const { run } = store.createFromLink(item.permalink);
  await watch.poll();
  assert.equal(watch.all().find((i) => i.id === item.id).state, "started");
  store.deleteRun(run.runId);
  await watch.poll();
  assert.ok(!watch.open().some((i) => i.id === item.id));
});

test("a failing channel records an error without stopping mentions; a reopened item loses its old verdict", async () => {
  store.writeConfig({ harness: { slackChannels: ["C0WATCH", "C0GONE"] } });
  await watch.poll(); // marks C0GONE
  const history = fake.history;
  fake.history = async (a) => (a.channelId === "C0GONE" ? Promise.reject(new Error("channel_not_found")) : history(a));
  fake.ms.push(mention(50));
  const out = await watch.poll();
  assert.match(out.error, /C0GONE: channel_not_found/);
  const item = watch.open().find((i) => i.threadTs === ts(50));
  assert.ok(item, "the mention was still filed");
  watch.triage(item.id, "skip", "noise");
  watch.dismiss(item.id);
  fake.ms.push(mention(51, { thread: 50 }));
  await watch.poll();
  const back = watch.open().find((i) => i.id === item.id);
  assert.equal(back.verdict, "", "a new ask gets a fresh look");
  fake.history = history;
  store.writeConfig({ harness: { slackChannels: ["C0WATCH"] } });
});

test("a dismiss made while a poll waits on Slack survives the poll", async () => {
  const item = watch.open()[0];
  const mentions = fake.mentions;
  let release;
  fake.mentions = () => new Promise((r) => (release = () => r(mentions())));
  const p = watch.poll();
  await new Promise((r) => setTimeout(r, 10));
  watch.dismiss(item.id);
  release();
  await p;
  fake.mentions = mentions;
  assert.ok(!watch.open().some((i) => i.id === item.id));
});

test("off skips the poll unless forced", async () => {
  store.writeConfig({ harness: { slackWatch: "off" } });
  assert.deepEqual(await watch.poll(), { skipped: true });
  assert.notDeepEqual(await watch.poll({ force: true }), { skipped: true });
});
