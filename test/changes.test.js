/**
 * Source Control for an orchestrator's checkout: ahead/behind, the commit
 * graph, fetch, fast-forward-only pull and sync, against a scratch remote.
 */

const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");
const changes = require("../server/changes");

const tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "bridge-changes-")));
test.after(() => fs.rmSync(tmp, { recursive: true, force: true }));

const ID = ["-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"];
const git = (cwd, ...a) => execFileSync("git", [...ID, ...a], { cwd, stdio: ["ignore", "pipe", "ignore"] }).toString().trim();
const commit = (cwd, file, text, msg) => {
  fs.writeFileSync(path.join(cwd, file), text);
  git(cwd, "add", ".");
  git(cwd, "commit", "-qm", msg);
};
const configure = (dir) => {
  for (const [k, v] of [["user.email", "t@t"], ["user.name", "t"], ["commit.gpgsign", "false"]]) git(dir, "config", k, v);
};

test("graph, fetch, fast-forward pull, refusal on divergence, and sync", async () => {
  const origin = path.join(tmp, "origin.git");
  git(tmp, "init", "-q", "--bare", "-b", "main", origin);
  const a = path.join(tmp, "a");
  const b = path.join(tmp, "b");
  git(tmp, "clone", "-q", origin, a);
  configure(a);
  commit(a, "one.txt", "1\n", "first");
  git(a, "push", "-q", "-u", "origin", "main");
  git(tmp, "clone", "-q", origin, b);
  configure(b);
  commit(b, "two.txt", "2\n", "second from b");
  git(b, "push", "-q");

  // Fetch sees b's commit: one behind, and the graph shows it under origin/main.
  let st = await changes.fetchRemote(a);
  assert.strictEqual(st.behind, 1);
  assert.strictEqual(st.unpushed, 0);
  const g = await changes.graph(a);
  assert.strictEqual(g.commits[0].subject, "second from b");
  assert.deepStrictEqual(g.commits[0].refs, [{ name: "origin/main", kind: "remote", head: false }]);
  assert.strictEqual(g.commits[1].head, true);
  assert.deepStrictEqual(g.commits[1].refs, [{ name: "main", kind: "branch", head: true }]);
  assert.deepStrictEqual(g.commits[0].parents, [g.commits[1].sha]);

  st = await changes.pull(a);
  assert.strictEqual(st.behind, 0);
  assert.ok(fs.existsSync(path.join(a, "two.txt")), "fast-forwarded");

  // Diverged: pull refuses rather than merging or rebasing, and nothing moves.
  commit(b, "three.txt", "3\n", "third from b");
  git(b, "push", "-q");
  commit(a, "local.txt", "x\n", "local work");
  const before = git(a, "rev-parse", "HEAD");
  await assert.rejects(changes.pull(a), /can't fast-forward/);
  assert.strictEqual(git(a, "rev-parse", "HEAD"), before);
  await assert.rejects(changes.sync(a), /can't fast-forward/, "sync stops at the pull: it never force-pushes");

  // Ahead only: sync pushes.
  git(a, "reset", "-q", "--hard", "origin/main");
  commit(a, "four.txt", "4\n", "fourth from a");
  st = await changes.sync(a);
  assert.strictEqual(st.unpushed, 0);
  assert.strictEqual(git(b, "ls-remote", "origin", "main").split("\t")[0], git(a, "rev-parse", "HEAD"));

  assert.match(await changes.show(a, st.commits[0].sha), /fourth from a/);
  await assert.rejects(changes.show(a, "HEAD; rm -rf /"), /not a commit id/);
});

test("ref names: remote vs a local branch with a slash, tags, other local branches left off", () => {
  const c = changes.shapeCommit(
    ["f".repeat(40), "fffffff", "a b", "HEAD -> refs/heads/alex/web-1, refs/remotes/origin/main, refs/remotes/origin/HEAD, refs/heads/other, tag: refs/tags/v1", "Subject", "Alex", "1700000000"].join("\x1f"),
  );
  assert.deepStrictEqual(c.refs, [
    { name: "alex/web-1", kind: "branch", head: true },
    { name: "origin/main", kind: "remote", head: false },
    { name: "v1", kind: "tag", head: false },
  ]);
  assert.deepStrictEqual(c.parents, ["a", "b"]);
  assert.strictEqual(c.head, true);
});
