# Pipeline

Turn the task above (a Linear issue, a Slack thread, or a plain brief) into
shipped work: pull just enough context, then either plan a large change with
{{USER}} or implement a small one and open a PR, followed by the post-PR steps.

## Scope

Detect the app first, from the ticket's team, the thread's channel and the
code it names (the table in `~/.claude/skills/capture/SKILL.md` §0a has each
app's repo, start alias, Linear team, PR title and `gh` account):
- **Expert Studio** (gym repo, `expert_studio/`): Linear team Deeptune, its
  prod DB / Modal apps / PostHog "Studio" project. Never touch files outside
  `expert_studio/`.
- **Mercor Studio** (`~/Development/studio`, `rl-studio/` + archipelago):
  Linear team Studio (`RLS`). Follow that repo's `CLAUDE.md` and
  `.agents/rules/` (they win over this file where they differ), plus the
  Studio memories (`feedback-pr-conventions`, `feedback-git-workflow-worktree-branch`).
- **Any other repo** (Bridge itself, a side project): follow its own
  `CLAUDE.md`/`AGENTS.md`; the Expert Studio and Mercor Studio steps below
  don't apply.

## 1. Gather context (stop as soon as the task is clear)

Collect only what's needed; never repeat a fact you already have. The source
is {{URL}}; the full brief is at `{{BRIEF}}`.

**Linear issue:**
1. **Linear (always):** `get_issue` + `list_comments`. Note title, description,
   repro steps, labels, attachments.
2. **Slack (usually):** most issues start there. Follow a Slack link in the
   issue, else `slack_search_public_and_private` by title/key terms and read
   the originating thread.

**Slack thread:**
1. **Slack (always):** `slack_read_thread` on the URL: the whole thread
   including replies, links and screenshots. It returns text only, so find the
   images with `slack_search_public_and_private` (`content_types="files"`,
   query `in:#<channel> type:images after:<day before>`), match them to the
   thread by author and time, and open each with `slack_download_file`. Look
   at every screenshot before searching the code or asking which screen.
2. **Linear (always ends with a ticket):** follow a Linear link in the thread,
   else one quick `list_issues` search by the thread's key terms. Found: pull
   it as above. Not found: **create the ticket now, before §2** (a Slack
   thread handed over is the go-ahead): team by app (Deeptune for Expert
   Studio, Studio `RLS` for Mercor Studio), plain title under 10 words, a
   priority judged from the thread, the thread summarized in the description,
   and the **Slack thread URL attached as a link** (`save_issue` `links`) plus
   every other source it cites. Say the key. From here on the ticket is the
   spec.

**Either way:**
- **Logs (only for unclear bugs):** **Modal** (`mcp-modal`) for stack traces;
  Expert Studio: **PostHog** ("Studio") for error tracking and event
  frequency. Mercor Studio: **Datadog** (`service:rl-studio env:prod`,
  `service:modal.function-logs` for Modal containers; see
  `docs/guides/trajectory-and-modal-debugging-runbook.md`).

## 2. Check it's not already built (report before proceeding)

Before planning or writing code, search the codebase and say:
1. **Does it already exist?** Routes, components, models, services: full,
   partial, or flag-gated. Cite `path:line`.
2. **Is it worth building?** Genuinely useful, or redundant / already covered
   / low-value given what's there.

Give a short verdict (*exists / partial / doesn't exist* and whether you'd
build it). **Wait for {{USER}} only when the verdict changes the ask** (it
already exists, or doesn't look worth building). Otherwise state the verdict
and go straight on. For a clear bug fix, just confirm the broken feature exists.

## 2.5 Root-cause it first (bugs only)

**Don't write a fix until you can name the cause.** Before §4, state:
1. **Where:** the `path:line` the wrong behavior originates from (the code
   whose logic is wrong, not where the symptom shows).
2. **Why:** one line connecting that code to the reported symptom.
3. **Scope:** how many other call sites / rows / users hit the same cause.

Escalate only when the cheap read fails, stopping the moment the chain closes:
1. **Read the code** (default).
2. **Cheap targeted evidence:** one Modal trace or PostHog error for the exact
   failure, or reproduce locally.
3. **`/root` on the originating Slack thread:** only if the cause is still
   unnamed after 1 and 2. Ask {{USER}} first, saying why.

If the behavior is correct (a false positive) or already fixed on `main`,
stop and say so instead of opening a PR.

## 3. Decide the path

Classify the work and act; never end the turn asking whether to plan or build.
- **Big → plan.** Spans several areas or services, schema or DB migration,
  auth/permission changes, real architectural choices, ambiguous scope:
  ask the open questions, then produce a full plan for approval before coding.
- **Simple → build now.** A clear bug fix or a well-scoped feature (UI/copy,
  one component/route/endpoint, contained backend logic, no schema change).
- **Borderline:** if a wrong first attempt is cheap to redo, build; if it
  would bake in a design {{USER}} might reject, plan.

## 4. Implement

- **Two or more issues at once:** one worktree and one subagent each.
- **Mercor Studio setup:** a new worktree has no `node_modules` or `.env`. If
  `pnpm install` 403s (npm firewall), copy (don't symlink) the main
  checkout's `rl-studio/frontend/node_modules` and `.env`; never commit them.
- **Code comments:** 2-3 lines at most; no ticket keys in code or docstrings.
- **No drive-by fixes:** leave unrelated pre-existing errors alone;
  `--no-verify` past hook failures already on `main`, and note them.
- **Lint/format before commit:** Expert Studio: Ruff (Python); ESLint +
  Prettier (frontend). Mercor Studio: `mise run check:branch` in
  `rl-studio/server` and `pnpm check:fast` in `rl-studio/frontend` (out of
  memory: `NODE_OPTIONS=--max-old-space-size=8192`); backend API changes also
  need `mise openapi`. Never `mise check` or `pnpm type-check` locally.

## 5. Verify, then open the PR

**Confirm it works first:** run the app or tests and watch the fix behave;
never open a PR you haven't seen work. Then commit and open the PR without
asking (creating a *Linear issue* still needs {{USER}}'s go-ahead, except the
one §1 creates for a Slack thread).
- **Mercor Studio:**
  - **Title** `type(scope): <Linear title, lightly adapted> (RLS-NNNNN)`, e.g.
    `fix(modules): hide the pass rate target card in Deeptune review (RLS-12986)`.
    A Studio PR needs a ticket: with none, draft one and get the go-ahead.
  - **Commit:** one squashed, signed commit with the PR title as its message,
    rebased on the latest `origin/main`.
  - **Open** with `GH_TOKEN=$(gh auth token --user george-mercor) gh pr create
    --repo Mercor-io/studio --base main --label preview-url --body-file <file>`,
    ready (not draft), assigned to george-mercor.
  - **Body:** the repo template and `.agents/rules/pr-descriptions.md`: under
    200 words of prose (`python3 .github/scripts/check_pr_body_length.py`), a
    2-3 sentence summary first, UI click-through steps, only checks actually
    run, caveats that affect merging.
  - Move the ticket to **In Review** once the PR is open.
- **Expert Studio title** `[PRIORITY] <title>`: `[URGENT]` (1), `[HIGH]` (2),
  `[MED]` (3, never `[MEDIUM]`), `[LOW]` (4), read off the ticket (a ticket
  with No priority gets one set in Linear first). With a ticket, the title is
  the Linear title character for character (rename the ticket first if it's
  wrong); without one, 10 words or fewer. No ticket key, no colon, no emoji.
  The title is frozen once the PR is open, except to restore that shape.
- **Other repos:** the repo's own conventions; a plain title.
- **Description:** real "How to test from the UI" steps, a direct link to the
  exact page, and every check you ran marked ✅ passed. No em-dashes in the PR
  or any other outgoing text: use colons, commas, or separate sentences.

## 6. After the PR

`gh` and pushes run as **george-mercor** on the Studio repos (`gh auth switch
--user george-mercor` if a push or edit 404s).
1. **Assign** {{USER}}: `gh pr edit <n> --add-assignee <that account>`.
2. **`/review <pr> low`** (Expert Studio and Mercor Studio): it owns the review
   cycle. Expert Studio requests Codex, runs `/rules` and `/code-review`,
   waits for Codex, then `/resolve`. Mercor Studio has no Codex: Devin Review
   and Cursor Bugbot run on their own; `/review` runs `/rules` and
   `/code-review`, waits for both bots on the head commit, then `/resolve`.
   Say the PR URL and don't end the turn while it waits.
3. **`/capture`** when the change shows in the UI (screenshots only), after
   `/review`'s push.
4. **CI on the latest push (always, last):** watch every check on the final
   head until none is pending (`gh pr checks <n> --json name,bucket`), report
   pass/fail per check, read any red log (`gh run view <id> --log-failed`) and
   fix it if it's yours; if it's flaky or already red on `main`, say so with
   the evidence. The PR isn't ready until this is green.

Don't post to Linear unless {{USER}} has said to.

## Done when

- §2 verdict reported (paused only if it already existed or wasn't worth it).
- Bugs: root cause named (`path:line`, why, scope) before any fix.
- Classified as plan or build, with no stalling in between.
- The change seen working, not just written.
- PR opened per the app's conventions, with UI test steps.
- Review threads resolved and every CI check green on the latest head.
- No unrelated changes in the diff.
