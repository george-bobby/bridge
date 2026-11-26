/**
 * The native Slack connector: your own Slack account through a user token.
 *
 * A user token (`xoxp-…`) acts as you, so there is no bot to invite and
 * nothing to add to a channel: it reads what you can read and posts as you.
 * Getting one takes a Slack app installed to yourself once, from the manifest
 * in docs/manifest.json.
 *
 *   status     who the token is, and in which workspace
 *   mentions   recent messages that mention you, newest first
 *   thread     a thread's messages, with names
 *   reply      post in a thread, as you (only ever on your click)
 *   history    a watched channel's new top-level messages
 *   replies    a thread's messages after a ts (keeps a chat in step with Slack)
 *   channels   the channels you're in, for the watch list in Settings
 *
 * The token lives in .env as SLACK_USER_TOKEN, is read by the server only,
 * and is removed from the environment sessions inherit.
 */

const env = require("./env");

const token = () => env.slackUserToken;
const configured = () => /^xox[pe]-/.test(token() || "");

async function call(method, params = {}) {
  if (!configured()) throw new Error("Slack isn't connected: add SLACK_USER_TOKEN in Settings");
  const body = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) if (v !== undefined && v !== "") body.set(k, String(v));
  const res = await fetch(`https://slack.com/api/${method}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token()}`, "Content-Type": "application/x-www-form-urlencoded" },
    body,
    signal: AbortSignal.timeout(20_000),
  });
  const out = await res.json().catch(() => ({}));
  if (!out.ok) {
    const e = new Error(out.error === "missing_scope" ? `Slack token is missing the ${out.needed || "required"} scope` : `Slack: ${out.error || res.status}`);
    e.slack = out.error;
    throw e;
  }
  return out;
}

/* ------------------------------------------------------------- caches */

let me = null;
let meAt = 0;
const users = new Map();
const channels = new Map();

async function status() {
  if (!configured()) return { configured: false };
  if (!me || Date.now() - meAt > 10 * 60_000) {
    const a = await call("auth.test");
    me = { configured: true, team: a.team, teamId: a.team_id, user: a.user, userId: a.user_id, url: a.url };
    meAt = Date.now();
  }
  return me;
}

async function user(id) {
  if (!id) return { name: "someone", avatar: "" };
  if (!users.has(id)) {
    users.set(
      id,
      call("users.info", { user: id })
        .then((u) => ({ name: u.user.profile.display_name || u.user.real_name || u.user.name, real: u.user.real_name || "", avatar: u.user.profile.image_72 || "" }))
        .catch(() => ({ name: id, avatar: "" })),
    );
  }
  return users.get(id);
}

async function channel(id) {
  if (!channels.has(id)) {
    channels.set(
      id,
      call("conversations.info", { channel: id })
        .then((c) => (c.channel.is_im ? "Direct message" : `#${c.channel.name}`))
        .catch(() => ""),
    );
  }
  return channels.get(id);
}

/** `<@U123>` and `<#C123|name>` to readable names, for display. */
async function humanize(text) {
  let out = String(text || "");
  for (const id of new Set([...out.matchAll(/<@([UW][A-Z0-9]+)(?:\|[^>]*)?>/g)].map((m) => m[1]))) {
    const u = await user(id);
    out = out.replaceAll(new RegExp(`<@${id}(\\|[^>]*)?>`, "g"), `@${u.name}`);
  }
  return out.replace(/<#[A-Z0-9]+\|([^>]+)>/g, "#$1").replace(/<(https?:[^|>]+)\|([^>]+)>/g, "$2").replace(/<(https?:[^>]+)>/g, "$1");
}

/* ------------------------------------------------------------ reading */

async function mentions() {
  const s = await status();
  const out = await call("search.messages", { query: `<@${s.userId}>`, sort: "timestamp", sort_dir: "desc", count: 40 });
  const matches = (out.messages && out.messages.matches) || [];
  return Promise.all(
    matches.map(async (m) => {
      const u = await user(m.user);
      const thread = (String(m.permalink).match(/thread_ts=(\d+\.\d+)/) || [])[1] || m.ts;
      return {
        ts: m.ts,
        user: m.user || "",
        threadTs: thread,
        channelId: m.channel && m.channel.id,
        channel: m.channel && m.channel.is_im ? "Direct message" : m.channel && m.channel.name ? `#${m.channel.name}` : "",
        who: u.name,
        avatar: u.avatar,
        text: await humanize(m.text),
        permalink: m.permalink,
      };
    }),
  );
}

async function thread({ channelId, threadTs }) {
  const out = await call("conversations.replies", { channel: channelId, ts: threadTs, limit: 200 });
  const messages = await Promise.all(
    (out.messages || []).map(async (m) => {
      const u = await user(m.user);
      return { ts: m.ts, user: m.user || "", who: m.user ? u.name : m.username || "bot", avatar: u.avatar, text: await humanize(m.text), files: (m.files || []).map((f) => f.name) };
    }),
  );
  return { channelId, threadTs, channel: await channel(channelId), messages };
}

async function reply({ channelId, threadTs, text }) {
  const t = String(text || "").trim();
  if (!t) throw new Error("empty reply");
  const out = await call("chat.postMessage", { channel: channelId, thread_ts: threadTs, text: t });
  return { ts: out.ts };
}

/** One message as the watcher files it: who, where, and a link back. */
async function shape(m, channelId) {
  const u = await user(m.user);
  const threadTs = m.thread_ts || m.ts;
  const name = await channel(channelId);
  let permalink = "";
  try {
    permalink = (await call("chat.getPermalink", { channel: channelId, message_ts: m.ts })).permalink || "";
  } catch {}
  return { ts: m.ts, user: m.user || "", threadTs, channelId, channel: name, who: m.user ? u.name : m.username || "bot", avatar: u.avatar, text: await humanize(m.text), permalink, bot: !!m.bot_id };
}

const CHATTER = new Set(["channel_join", "channel_leave", "channel_topic", "channel_purpose", "channel_name", "pinned_item", "bot_add", "bot_remove"]);

/** Every page of a cursor-paginated call, up to `max` pages. */
async function pages(method, params, key, max = 10) {
  const all = [];
  let cursor = "";
  for (let i = 0; i < max; i++) {
    const out = await call(method, { ...params, cursor });
    all.push(...(out[key] || []));
    cursor = (out.response_metadata && out.response_metadata.next_cursor) || "";
    if (!cursor) break;
  }
  return all;
}

async function history({ channelId, oldest }) {
  // Every page since the mark: the watermark moves past whatever is returned.
  const msgs = (await pages("conversations.history", { channel: channelId, oldest, limit: 200 }, "messages")).filter((m) => !CHATTER.has(m.subtype) && (!m.thread_ts || m.thread_ts === m.ts));
  return Promise.all(msgs.map((m) => shape(m, channelId)));
}

async function replies({ channelId, threadTs, oldest }) {
  const msgs = (await pages("conversations.replies", { channel: channelId, ts: threadTs, oldest, limit: 200 }, "messages")).filter((m) => m.ts !== threadTs && Number(m.ts) > Number(oldest || 0) && !CHATTER.has(m.subtype));
  return Promise.all(msgs.map(async (m) => ({ ts: m.ts, user: m.user || "", who: m.user ? (await user(m.user)).name : m.username || "bot", text: await humanize(m.text) })));
}

async function listChannels() {
  return (await pages("users.conversations", { types: "public_channel,private_channel", exclude_archived: true, limit: 500 }, "channels", 20)).map((c) => ({ id: c.id, name: `#${c.name}`, private: !!c.is_private })).sort((a, b) => a.name.localeCompare(b.name));
}

/** Who asked and what, for a chat made from a pasted link. Best effort. */
async function describeThread({ channelId, threadTs }) {
  if (!configured()) return null;
  const t = await thread({ channelId, threadTs });
  const root = t.messages[0];
  return root ? { who: root.who, channel: t.channel, text: root.text, userId: root.user } : null;
}

module.exports = { configured, status, mentions, thread, reply, describeThread, history, replies, channels: listChannels };
