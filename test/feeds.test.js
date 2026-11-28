/**
 * The Vercel and Datadog feeds against a stubbed fetch: a SAML team a token
 * can't read is reported, not silently empty, and Datadog's two halves fail
 * on their own. Modal runs a fake `modal` CLI (test/modal.js) on the token
 * pair from .env, and billing fails on its own.
 */

const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const os = require("os");
const path = require("path");

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "bridge-feeds-"));
Object.assign(process.env, {
  BRIDGE_ENV_FILE: path.join(tmp, "none.env"),
  BRIDGE_DATA_DIR: tmp,
  VERCEL_TOKEN: "tok-user, tok-acme",
  DD_API_KEY: "k",
  DD_APP_KEY: "a",
  DD_SITE: "us5.datadoghq.com",
  MODAL_TOKEN_ID: "ak-test",
  MODAL_TOKEN_SECRET: "as-test",
  BRIDGE_MODAL: path.join(tmp, "modal"),
});
fs.writeFileSync(process.env.BRIDGE_MODAL, `#!/bin/sh\nexec "${process.execPath}" "${path.join(__dirname, "modal.js")}" "$@"\n`, { mode: 0o755 });
const sources = require("../server/sources");

let calls = [];
const reply = (status, body) => ({ ok: status < 300, status, json: async () => body });
function stub(handler) {
  calls = [];
  globalThis.fetch = async (url, init = {}) => {
    calls.push({ url: String(url), init });
    return handler(new URL(url), init);
  };
}

test.after(() => fs.rmSync(tmp, { recursive: true, force: true }));

test("Vercel: a SAML team is read with its own token and the unreadable one is reported", async () => {
  const saml = { error: { code: "forbidden", message: 'Not authorized: Trying to access resource under scope "corp". You must re-authenticate to this scope or use a token with access to this scope.' } };
  stub((u, init) => {
    const tok = init.headers.Authorization.slice(7);
    if (u.pathname === "/v2/user") return reply(200, { user: { username: "me" } });
    if (u.pathname === "/v2/teams") return reply(200, { teams: [{ id: "t_acme", slug: "acme" }, { id: "t_corp", slug: "corp" }] });
    const team = u.searchParams.get("teamId");
    if (team === "t_corp") return reply(403, saml);
    if (team === "t_acme" && tok !== "tok-acme") return reply(403, saml);
    const d = (id) => ({ uid: id, name: "web", url: `${id}.vercel.app`, state: "READY", target: "production", created: Date.now() });
    return reply(200, { deployments: team ? [d("dpl_acme")] : [] });
  });
  const v = await sources.vercel({ refresh: true });
  assert.deepStrictEqual(v.deployments.map((d) => d.id), ["dpl_acme"]);
  assert.deepStrictEqual(v.blocked.map((b) => [b.team, b.saml]), [["corp", true]], "acme was read by the second token, corp by none");
  assert.deepStrictEqual(v.teams, ["acme", "corp"]);
});

test("Datadog: alerting monitors and open issues on the configured site; one failing half keeps the other", async () => {
  stub((u, init) => {
    assert.strictEqual(u.host, "api.us5.datadoghq.com");
    assert.strictEqual(init.headers["DD-APPLICATION-KEY"], "a");
    if (u.pathname === "/api/v1/monitor/search") {
      assert.match(u.searchParams.get("query"), /status:\(alert OR warn/);
      return reply(200, { monitors: [{ id: 7, name: "5xx", status: "Alert", last_triggered_ts: 1 }, { id: 8, name: "lag", status: "No Data" }] });
    }
    const body = JSON.parse(init.body);
    assert.strictEqual(init.method, "POST");
    assert.strictEqual(body.data.attributes.persona, "ALL");
    return reply(200, {
      data: [
        { id: "i1", attributes: { total_count: 12 }, relationships: { issue: { data: { id: "i1", type: "issue" } } } },
        { id: "i2", attributes: { total_count: 3 }, relationships: { issue: { data: { id: "i2", type: "issue" } } } },
      ],
      included: [
        { id: "i1", type: "issue", attributes: { error_type: "TypeError", error_message: "boom\nstack", service: "web", state: "OPEN" } },
        { id: "i2", type: "issue", attributes: { error_type: "Old", state: "RESOLVED" } },
      ],
    });
  });
  const d = await sources.datadog({ refresh: true });
  assert.deepStrictEqual(d.monitors.map((m) => [m.id, m.status, m.url]), [[7, "alert", "https://us5.datadoghq.com/monitors/7"], [8, "nodata", "https://us5.datadoghq.com/monitors/8"]]);
  assert.deepStrictEqual(d.issues.map((i) => [i.id, i.message, i.count]), [["i1", "boom", 12]], "resolved issues are dropped");

  stub((u) => (u.pathname.startsWith("/api/v2") ? reply(403, { errors: ["Forbidden"] }) : reply(200, { monitors: [] })));
  const half = await sources.datadog({ refresh: true });
  assert.strictEqual(half.configured, true);
  assert.strictEqual(half.errors.issues, "Forbidden");
});

test("Modal: apps per environment with today's cost and GPUs, live containers, the month's bill; billing fails on its own", async () => {
  assert.strictEqual(process.env.MODAL_TOKEN_ID, undefined, "the token never reaches a session's env");
  const m = await sources.modal({ refresh: true });
  assert.deepStrictEqual([m.configured, m.workspace, m.user, m.environments], [true, "acme", "alex", ["main", "dev"]]);
  assert.deepStrictEqual(m.apps.map((a) => [a.id, a.env, a.state, a.tasks, a.costToday, a.gpus]), [
    ["ap-llm", "main", "deployed", 3, 11, ["GPU H100"]],
    ["ap-idle", "main", "deployed", 0, 0.5, []],
    ["ap-dev", "dev", "stopped", 0, null, []],
  ], "busiest first; an app with no cost today has null, not 0");
  assert.strictEqual(m.apps[0].createdAt, Date.parse("2026-11-20T10:00:00+05:30"));
  assert.strictEqual(m.apps[0].url, "https://modal.com/id/ap-llm");
  assert.deepStrictEqual(m.containers.map((c) => c.id), ["ta-3", "ta-2", "ta-1"], "newest first");
  assert.deepStrictEqual([m.spend.metered, m.spend.billed, m.spend.credits, m.spend.today, m.spend.breakdown.deployed_apps], [120.5, 90.5, 30, 11.5, 100.25]);
  assert.deepStrictEqual(m.gpus, [{ type: "GPU H100", cost: 10 }]);
  assert.strictEqual(m.dashboard, "https://modal.com/apps/acme");

  const app = await sources.modalApp("ap-llm", "main");
  assert.deepStrictEqual([app.version, app.deployedBy, app.history[0].commit], [7, "github-actions", "abc1234"]);
  assert.deepStrictEqual(app.functions.map((f) => [f.name, f.web, f.webUrl, f.schedule, f.gpus, f.stats.failed]), [
    ["generate", false, "", "", ["H100"], 2],
    ["web", true, "https://acme--llm-serve-web.modal.run", "", [], 0],
    ["warm", false, "", "*/10 * * * *", [], 0],
  ]);
  await assert.rejects(sources.modalApp("ap-nope", "main"), /No App with name 'ap-nope' found/, "the CLI's boxed error comes back as its words");
  await assert.rejects(sources.modalApp("../etc", "main"), /bad app id/);

  process.env.FAKE_MODAL_BILLING = "deny";
  try {
    const half = await sources.modal({ refresh: true });
    assert.strictEqual(half.spend, null);
    assert.strictEqual(half.errors.billing, "Workspace manager permissions required");
    assert.strictEqual(half.apps.length, 3, "apps still load");
  } finally {
    delete process.env.FAKE_MODAL_BILLING;
  }
});
