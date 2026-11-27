const test = require("node:test");
const assert = require("node:assert/strict");

const { decide } = require("../server/failover");
const { parse, formatUsage } = require("../bin/bridge");

const provider = (id, usedPct, status = "ok") => ({ id, label: id[0].toUpperCase() + id.slice(1), status, windows: usedPct == null ? [] : [{ id: id === "claude" ? "session" : "primary", short: "5h", usedPct }] });
const usage = (claude = 96) => ({ providers: [provider("claude", claude), provider("codex", 20), provider("cursor", 30), provider("devin", null)] });
const harness = { failover: true, failoverThreshold: 95, failoverOrder: ["devin", "codex", "cursor"] };

test("failover chooses the first available preference at the worker threshold", () => {
  assert.equal(decide({ usage: usage(), harness }).agent, "devin");
  const u = usage();
  u.providers.find((p) => p.id === "devin").status = "unavailable";
  assert.equal(decide({ usage: u, harness }).agent, "codex");
  assert.equal(decide({ usage: usage(), harness, installed: ["cursor"] }).agent, "cursor");
  assert.equal(decide({ usage: usage(94), harness }), null);
  assert.equal(decide({ usage: usage(), harness, currentAgent: "cursor" }), null);
});

test("orchestrators stay on Claude until a window is fully exhausted", () => {
  assert.equal(decide({ usage: usage(99), harness, orchestrator: true }), null);
  assert.equal(decide({ usage: usage(100), harness, orchestrator: true }).agent, "devin");
});

test("CLI parses agent flags and formats one compact usage line per agent", () => {
  assert.deepEqual(parse(["--agent", "codex", "--agent-model=gpt-5", "--no-start"]), { flags: { agent: "codex", "agent-model": "gpt-5", "no-start": true }, pos: [] });
  const u = usage(96);
  u.providers.find((p) => p.id === "cursor").details = [{ label: "Spend", value: "$3.00 of $10.00" }, { label: "Promo credit", value: "$2.00 left" }];
  u.providers.find((p) => p.id === "devin").local = { week: { acu: 1.25 } };
  assert.deepEqual(formatUsage(u), ["Claude: 5h 96%", "Codex: 5h 20%", "Cursor: spend $3.00 of $10.00 · promo credit $2.00 left", "Devin: 1.25 ACUs (7d)"]);
});
