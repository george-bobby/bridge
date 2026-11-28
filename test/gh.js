#!/usr/bin/env node
/**
 * A fake `gh` for the accounts tests (BRIDGE_GH): two logged-in accounts,
 * a token each, `api user` answering for whichever token GH_TOKEN holds, and
 * `auth git-credential get` handing git that token.
 */
const ACCOUNTS = { alex: { id: 7, name: "Alex Rivera", email: "alex@example.com", token: "tok-alex" }, "alex-work": { id: 42, name: "", email: null, token: "tok-work" } };
const a = process.argv.slice(2);
const has = (...w) => w.every((x, i) => a[i] === x);
const byToken = () => Object.entries(ACCOUNTS).find(([, v]) => v.token === process.env.GH_TOKEN);

if (has("auth", "status")) {
  process.stdout.write(JSON.stringify({ hosts: { "github.com": [{ login: "alex", active: true, state: "success" }, { login: "alex-work", active: false, state: "success" }] } }));
} else if (has("auth", "token")) {
  const u = ACCOUNTS[a[a.indexOf("--user") + 1]];
  if (!u) process.exit(1);
  process.stdout.write(`${u.token}\n`);
} else if (has("api", "user")) {
  const hit = byToken();
  if (!hit) process.exit(1);
  process.stdout.write(JSON.stringify({ login: hit[0], id: hit[1].id, name: hit[1].name || null, email: hit[1].email }));
} else if (has("auth", "git-credential", "get")) {
  const hit = byToken();
  if (!hit) process.exit(1);
  process.stdout.write(`protocol=https\nhost=github.com\nusername=${hit[0]}\npassword=${hit[1].token}\n`);
} else {
  process.exit(1);
}
