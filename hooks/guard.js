#!/usr/bin/env node
/**
 * PreToolUse guard for every session the harness launches (workers, the
 * pipeline, the orchestrator, and the terminal hand-off).
 *
 * It is loaded per session with `claude --settings <json>` rather than written
 * into ~/.claude/settings.json, so it never touches user-level config and never
 * affects a Claude session the harness didn't start.
 *
 * Three verdicts, chosen by server/policy.js:
 *
 *   deny   the command can never be right here: a kill by pattern, an env
 *          dump, a process listing that prints argv, reading a .env file.
 *          The reason goes back to the model so it can do the safe version.
 *   ask    allowed only with the user's OK on this exact call: destructive git
 *          and every outward write (Slack posts, Linear edits, PR merges, ...).
 *          Under the dashboard's `--permission-prompt-tool stdio` this becomes
 *          an Allow/Deny card showing the exact payload, even in full-access
 *          mode; in a terminal it is the normal permission prompt.
 *   (none) everything else falls through to the session's own permission mode.
 *
 * Under "Bypass permissions" the only prompts left are these `ask`s: Claude
 * Code honours a hook's `ask` in every mode, which is what keeps the hard
 * gates hard. So an `ask` must mean a real outward write or destructive git,
 * never a parser guess (test/policy.test.js holds the false positives seen).
 *
 * Fails open on a malformed hook payload (prints nothing, exits 0): a guard
 * that crashes on input it didn't expect would block every tool call in
 * every session. Its own tests live in test/policy.test.js.
 */

const { execFileSync } = require("child_process");
const os = require("os");
const path = require("path");

const policy = require("../server/policy");

const run = (cmd, args, cwd) => {
  try {
    return execFileSync(cmd, args, { cwd, encoding: "utf8", timeout: 3000, stdio: ["ignore", "pipe", "ignore"] }).trim();
  } catch {
    return "";
  }
};

/**
 * Whether a local port is served by a process running in the session's own
 * checkout (a scratch Bridge or dev server it started), so writes to it are
 * the session testing its own work, not an outward write. The checkout is the
 * git top level of the session's folder; a home folder or / never counts.
 */
function ownServer(cwd) {
  let root;
  return (port) => {
    if (!/^\d+$/.test(port) || !cwd) return false;
    if (root === undefined) root = run("git", ["rev-parse", "--show-toplevel"], cwd) || path.resolve(cwd);
    if (!root || root === "/" || root === os.homedir()) return false;
    const pids = run("lsof", ["-nP", `-iTCP:${port}`, "-sTCP:LISTEN", "-t"]).split("\n").filter((p) => /^\d+$/.test(p));
    if (!pids.length) return false;
    const dirs = run("lsof", ["-a", "-d", "cwd", "-p", pids.join(","), "-Fn"])
      .split("\n")
      .filter((l) => l[0] === "n")
      .map((l) => l.slice(1));
    return dirs.length > 0 && dirs.every((d) => d === root || d.startsWith(root + "/"));
  };
}

/** The branch a `git push --force-with-lease` with no refspec would update. */
const branchAt = (dir, cwd) => run("git", [...(dir ? ["-C", dir] : []), "rev-parse", "--abbrev-ref", "HEAD"], cwd);

let raw = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (c) => (raw += c));
process.stdin.on("end", () => {
  let input;
  try {
    input = JSON.parse(raw || "{}") || {};
  } catch {
    process.exit(0);
  }
  const verdict = policy.check(input.tool_name, input.tool_input || {}, {
    policy: policy.loadPolicy(),
    ownServer: ownServer(input.cwd),
    branchAt: (dir) => branchAt(dir, input.cwd),
  });
  if (!verdict) process.exit(0);
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: verdict.decision,
        permissionDecisionReason: verdict.reason,
      },
    })
  );
  process.exit(0);
});
