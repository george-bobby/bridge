/**
 * The skill every new worker opens with (WORKER_SKILL, default `fetch`).
 *
 * Claude runs it as a slash command: `/fetch <linear or slack url | brief>`,
 * then Bridge's own rules (worktree, report.md, asks) after it, the same way a
 * slash command typed in the composer gets the mode's rule appended. Codex,
 * Cursor and Devin can't run Claude skills, so they get the skill's SKILL.md
 * inlined with `$ARGUMENTS` filled in. A skill that isn't installed returns
 * null, and the caller falls back to Bridge's built-in brief / pipeline.
 */

const fs = require("fs");
const os = require("os");
const path = require("path");

const NAME = /^[\w.-]+(?::[\w.-]+)?$/;
const OFF = /^(none|off|false|no|0)$/i;

/** Claude Code's user folder (skills, commands): $CLAUDE_CONFIG_DIR or ~/.claude. */
const claudeHome = () => process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), ".claude");

/** "fetch", "/fetch", "plugin:skill" → the bare name; "none"/"off"/"" → "". */
function normalise(raw) {
  const name = String(raw == null ? "" : raw).trim().replace(/^\//, "");
  if (!name || OFF.test(name) || !NAME.test(name)) return "";
  return name;
}

/**
 * Where a skill lives: `<dir>/.claude/skills/<name>/SKILL.md` (or a
 * `commands/<name>.md`) in each folder given, then the user's ~/.claude.
 * A `plugin:skill` name has no file we can find: Claude can still run it,
 * the other agents can't (no text to inline).
 */
function find(name, dirs = []) {
  const n = normalise(name);
  if (!n) return null;
  if (n.includes(":")) return { name: n, file: "", text: "" };
  const bases = [...new Set([...dirs.filter(Boolean).map((d) => path.join(d, ".claude")), claudeHome()])];
  for (const base of bases) {
    for (const file of [path.join(base, "skills", n, "SKILL.md"), path.join(base, "commands", `${n}.md`)]) {
      try {
        return { name: n, file, text: fs.readFileSync(file, "utf8") };
      } catch {}
    }
  }
  return null;
}

const LINEAR = /https:\/\/linear\.app\/[^\s)>\]"'`]+\/issue\/[^\s)>\]"'`]+/;
const SLACK = /https:\/\/[\w.-]*slack\.com\/archives\/[^\s)>\]"'`]+/;

/** The Linear issue or Slack thread a brief is about, Linear first. */
function sourceUrl(text) {
  const s = String(text || "");
  return (LINEAR.exec(s) || SLACK.exec(s) || [""])[0].replace(/[.,;:]+$/, "");
}

/** SKILL.md without its frontmatter. */
const body = (text) => String(text || "").replace(/^---\n[\s\S]*?\n---\n?/, "").trim();

/**
 * The opening prompt: the skill invocation, then Bridge's rules. Null when
 * this agent can't run the skill (a plugin skill outside Claude).
 */
function prompt({ skill, agent = "claude", arg, rules = "" }) {
  if (!skill) return null;
  const a = String(arg || "").trim();
  if ((agent || "claude") === "claude") return [`/${skill.name} ${a}`.trim(), rules].filter(Boolean).join("\n\n");
  if (!skill.text) return null;
  const content = body(skill.text).replace(/\$ARGUMENTS/g, a);
  return [
    `Run the \`${skill.name}\` skill below on: ${a}`,
    `Skills can't be invoked as slash commands here, so its SKILL.md is inlined: follow it exactly as if you had been started with \`/${skill.name} ${a.split("\n")[0]}\`. Where it names tools you don't have (the Skill tool, plan mode, AskUserQuestion, a Linear or Slack connector), use the closest equivalent you do have, and say in your report what you couldn't do.`,
    `<skill name="${skill.name}" path="${skill.file}">\n${content}\n</skill>`,
    rules,
  ]
    .filter(Boolean)
    .join("\n\n");
}

module.exports = { find, normalise, sourceUrl, prompt, body, claudeHome };
