These hold in every repo. A repo's own CLAUDE.md or AGENTS.md wins where it is stricter.

### Git
1. Work in a git worktree off a fresh `origin/main`, never in the main checkout, unless {{USER}} says to use the current one. Bridge sessions already start in one; anywhere else create it at `<repo>-worktrees/<branch>`, one level deep (strip a `user/` prefix from the folder name).
2. With a Linear ticket, the branch is Linear's suggested branch name; without one, a short kebab-case name.
3. Rebase onto the latest `origin/main` before every push. A rebased branch goes up with `--force-with-lease`, on your own branch only, never main; where force-pushes need approval, ask for it.
4. Move uncommitted work between checkouts with `git stash`, never a diff file.
5. Keep the diff to the task: stage by explicit path (never `git add -A`), run formatters on an explicit file list, no drive-by fixes. Failures that already exist on main go in the PR's caveats, not the diff.

### Verifying
6. Verify on the real running app (localhost or the PR preview), used the way a person would. A stubbed harness is a fallback, not the result. First prove which worktree and database serve the port.
7. A check that passes by finding nothing (no error, a grep count of 0, a poll that ends quietly) proves nothing until you have seen it fail. Otherwise say the green is unproven.
8. A claim about a set (every caller, emitter, flag or code path) comes from grepping the source, not from memory. When a finding has one occurrence, look for its siblings.
9. Before fixing, count what the fix touches (rows, consumers) and whether each benefits or is harmed. A review finding's diagnosis and its suggested remedy are separate claims: check both.
10. Report only the checks you actually ran, and say plainly what went unverified.

### Pull requests
11. After every push, re-check CI on the new head before calling a PR ready, and read every red check.
12. Any code change re-syncs the PR description (and the ticket's, if it describes the change) in place.
13. Opening a PR, writing its description and replying to review threads need no approval. Linear issues, Linear comments and Slack messages are drafts for {{USER}} until they say post.

### Writing
14. Anything that goes out under {{USER}}'s name is short and plain: a lead-in line, then a numbered list of complete sentences. No em-dashes (use colons or commas), no filler.
15. Before creating a Linear issue, confirm; fold requests from the same chat into the existing issue; keep titles plain and under ten words; attach every source.

### Working style
16. Use at most one background subagent unless {{USER}} asks for more, and give each its own scratch folder.
17. Outputs that must outlive the session go in a git-ignored folder in the repo, not a scratch folder a restart wipes.
