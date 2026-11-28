#!/usr/bin/env node
/**
 * A fake `modal` CLI for the Modal feed tests (BRIDGE_MODAL): one workspace,
 * two environments, answering only to the token pair the feed passes in env.
 * FAKE_MODAL_BILLING=deny makes billing fail the way a non-manager's does.
 */
const a = process.argv.slice(2);
const has = (...w) => w.every((x, i) => a[i] === x);
const envName = a.includes("-e") ? a[a.indexOf("-e") + 1] : "main";
const out = (o) => process.stdout.write(JSON.stringify(o));
const fail = (msg) => {
  process.stderr.write(`╭─ Error ─────────╮\n│ ${msg} │\n╰─────────────────╯\n`);
  process.exit(1);
};

if (process.env.MODAL_TOKEN_ID !== "ak-test" || process.env.MODAL_TOKEN_SECRET !== "as-test") fail("Token missing");
if (!a.includes("--json") && !has("token", "info")) fail("expected --json");

if (has("token", "info")) {
  process.stdout.write("Token: ak-test\nWorkspace: acme (ac-1)\nUser: alex (us-1)\n");
} else if (has("environment", "list")) {
  out([{ name: "main", active: "True" }, { name: "dev", active: "False" }]);
} else if (has("app", "list")) {
  out(
    envName === "main"
      ? [
          { app_id: "ap-idle", description: "nightly", state: "deployed", tasks: "0", created_at: "2026-11-01 10:00:00+00:00", stopped_at: null },
          { app_id: "ap-llm", description: "llm-serve", state: "deployed", tasks: "3", created_at: "2026-11-20 10:00:00+05:30", stopped_at: null },
        ]
      : [{ app_id: "ap-dev", description: "scratch", state: "stopped", tasks: "0", created_at: "2026-11-27 10:00:00+00:00", stopped_at: "2026-11-27 11:00:00+00:00" }],
  );
} else if (has("container", "list")) {
  out(envName === "main" ? [1, 2, 3].map((i) => ({ container_id: `ta-${i}`, app_id: "ap-llm", app_name: "llm-serve", start_time: `2026-11-28 10:0${i}:00+00:00` })) : []);
} else if (has("billing", "summary")) {
  if (process.env.FAKE_MODAL_BILLING === "deny") fail("Workspace manager permissions required");
  out({ metered_cost: "120.50000000", billed_cost: "90.50000000", adjustments: { plan_cost: "0E-8", credits: "-30.00000000" }, metered_cost_breakdown: { deployed_apps: "100.25", network_egress: "20.25" } });
} else if (has("billing", "report")) {
  if (process.env.FAKE_MODAL_BILLING === "deny") fail("Workspace manager permissions required");
  out([
    { object_id: "ap-llm", description: "llm-serve", environment: "main", resource: "CPU", cost: "1.004" },
    { object_id: "ap-llm", description: "llm-serve", environment: "main", resource: "GPU H100", cost: "10.00" },
    { object_id: "ap-idle", description: "nightly", environment: "main", resource: "Memory", cost: "0.5" },
  ]);
} else if (has("app", "info")) {
  if (a[2] !== "ap-llm") fail(`No App with name '${a[2]}' found`);
  out({
    description: "llm-serve",
    app_id: "ap-llm",
    lifecycle: { state: "deployed", created_by: "alex", deployed_at: "2026-11-28 09:00:00+00:00", deployed_by: "github-actions", version: 7, stopped_at: null, stopped_by: null },
    functions: {
      generate: { id: "fu-gen", summary: {} },
      web: { id: "fu-web", summary: { web_function: true } },
      warm: { id: "fu-warm", summary: { schedule: { cron: { cron_string: "*/10 * * * *" } } } },
    },
    servers: {},
  });
} else if (has("app", "history")) {
  out([{ version: "v7", time_deployed: "2026-11-28 09:00:00+00:00", deployed_by: "github-actions", commit: "abc1234" }]);
} else if (has("function", "info")) {
  out({ "fu-gen": { gpus: ["H100"] }, "fu-web": { gpus: [], web_info: { web_url: "https://acme--llm-serve-web.modal.run" } }, "fu-warm": { gpus: [] } }[a[2]]);
} else if (has("function", "stats")) {
  out({ input_success_count: a[2] === "fu-gen" ? 40 : 0, input_failure_count: a[2] === "fu-gen" ? 2 : 0, input_timeout_count: 0, input_running_at_end_count: 1, container_error_count: 0 });
} else {
  fail(`unknown command ${a.join(" ")}`);
}
