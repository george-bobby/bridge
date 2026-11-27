/** Pure automatic-agent failover policy. Usage fetching and run mutation live
 * with the harness so this stays fixture-testable. */

const AGENTS = ["devin", "codex", "cursor"];

function claudeWindow(usage) {
  const claude = ((usage && usage.providers) || []).find((p) => p.id === "claude");
  if (!claude || claude.status !== "ok") return null;
  return (claude.windows || [])
    .filter((w) => ["session", "weekly"].includes(w.id))
    .filter((w) => Number.isFinite(Number(w.usedPct)))
    .sort((a, b) => Number(b.usedPct) - Number(a.usedPct))[0] || null;
}

function available(usage, id, installed) {
  if (installed && !installed.includes(id)) return false;
  const p = ((usage && usage.providers) || []).find((x) => x.id === id);
  if (!p || p.status !== "ok") return false;
  return !(p.windows || []).some((w) => Number(w.usedPct) >= 100);
}

function decide({ usage, harness = {}, currentAgent = "claude", orchestrator = false, installed = null } = {}) {
  if (!harness.failover || currentAgent !== "claude") return null;
  const window = claudeWindow(usage);
  if (!window) return null;
  const threshold = orchestrator ? 100 : Number(harness.failoverThreshold) || 95;
  if (Number(window.usedPct) < threshold) return null;
  const order = Array.isArray(harness.failoverOrder) ? harness.failoverOrder : AGENTS;
  const agent = order.find((id) => AGENTS.includes(id) && available(usage, id, installed));
  return agent ? { agent, threshold, usedPct: Number(window.usedPct), window: window.short || window.label || window.id } : null;
}

module.exports = { AGENTS, decide };
