/**
 * The Vercel and Datadog feeds against a stubbed fetch: a SAML team a token
 * can't read is reported, not silently empty, and Datadog's two halves fail
 * on their own. Model providers report prices, limits and spend, each
 * failing on its own.
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
  OPENROUTER_KEY: "or-key",
  ANTHROPIC_KEY: "an-key",
});
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

test("Models: OpenRouter prices per 1M tokens and spend, Anthropic limits; a failing provider keeps the other", async () => {
  assert.strictEqual(process.env.OPENROUTER_KEY, undefined, "the key never reaches a session's env");
  stub((u, init) => {
    if (u.host === "openrouter.ai") {
      assert.strictEqual(init.headers.Authorization, "Bearer or-key");
      if (u.pathname === "/api/v1/key") return reply(200, { data: { label: "dev", usage: 12.5, usage_daily: 1, limit: 50, limit_remaining: 37.5, is_free_tier: false } });
      if (u.pathname === "/api/v1/credits") return reply(200, { data: { total_credits: 20, total_usage: 12.5 } });
      return reply(200, {
        data: [
          { id: "old/m", name: "Old", created: 1, context_length: 8192, pricing: { prompt: "0", completion: "0" } },
          { id: "openai/x", name: "X", created: 2, context_length: 400000, top_provider: { max_completion_tokens: 128000 }, pricing: { prompt: "0.00000125", completion: "0.00001" }, architecture: { modality: "text->text" } },
          { id: "openrouter/auto", name: "Auto", created: 0, pricing: { prompt: "-1", completion: "-1" } },
        ],
      });
    }
    assert.strictEqual(init.headers["x-api-key"], "an-key");
    return reply(200, { data: [{ id: "claude-x", display_name: "Claude X", created_at: "2026-01-01T00:00:00Z", max_input_tokens: 1000000, max_tokens: 128000, capabilities: { vision: { supported: true }, batch: false } }] });
  });
  const m = await sources.models({ refresh: true });
  const [or, an] = m.providers;
  assert.deepStrictEqual(or.models.map((x) => [x.id, x.input, x.output, x.context, x.maxOutput]), [
    ["openai/x", 1.25, 10, 400000, 128000],
    ["old/m", 0, 0, 8192, 0],
    ["openrouter/auto", null, null, 0, 0],
  ], "newest first; a variable price is null, not negative");
  assert.deepStrictEqual([or.account.spent, or.account.remaining, or.account.balance], [12.5, 37.5, 7.5]);
  assert.deepStrictEqual([an.models[0].context, an.models[0].maxOutput, an.models[0].capabilities], [1000000, 128000, ["vision"]]);

  stub((u) => (u.host === "openrouter.ai" ? reply(401, { error: { message: "No auth credentials found" } }) : reply(200, { data: [] })));
  const half = await sources.models({ refresh: true });
  assert.strictEqual(half.providers[0].error, "No auth credentials found");
  assert.strictEqual(half.providers[1].error, undefined);
});
