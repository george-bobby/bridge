// What Bridge works out instead of asking (server/identity.js): an explicit
// .env value always wins; otherwise the facts fill in, and the Linear team
// picked in Settings sets the issue prefix.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "bridge-identity-"));
process.env.BRIDGE_DATA_DIR = tmp;
process.env.BRIDGE_ENV_FILE = path.join(tmp, "none.env");
const id = require("../server/identity");

test("owner/name from any GitHub remote", () => {
  assert.equal(id.slugOf("git@github.com:Mercor-io/studio.git"), "Mercor-io/studio");
  assert.equal(id.slugOf("https://github.com/george-bobby/bridge"), "george-bobby/bridge");
  assert.equal(id.slugOf("https://gitlab.com/a/b.git"), "");
});

const facts = {
  github: { login: "octo" },
  slack: { userId: "U1", name: "Octo Cat" },
  linear: { workspace: "acme", teams: [{ key: "WEB", name: "Web" }, { key: "MOB", name: "Mobile" }] },
  path: "/Users/x/.nvm/bin:/usr/bin",
};
const fresh = (raw = {}) => ({ raw: { githubLogin: "", githubRepo: "", branchPrefix: "", slackUserId: "", slackUserName: "", linearWorkspace: "", linearTeam: "", linearIssuePrefix: "", targetRepo: "", productName: "", pipelineModel: "", extraPath: "", ...raw } });

test("facts fill what .env left empty", () => {
  const e = id.apply(fresh(), facts, { harness: { linearTeam: "MOB", pipelineModel: "sonnet" } });
  assert.deepEqual([e.githubLogin, e.branchPrefix, e.slackUserName, e.linearWorkspace, e.linearTeam, e.linearIssuePrefix, e.pipelineModel], ["octo", "octo", "Octo Cat", "acme", "Mobile", "MOB", "sonnet"]);
  assert.ok(e.extraPath.split(":").includes("/Users/x/.nvm/bin"), "the login shell's PATH is added");
});

test("an explicit .env value is an override and always wins", () => {
  // env.js has already set extraPath from EXTRA_PATH; apply leaves it alone.
  const e = id.apply({ ...fresh({ githubLogin: "me", branchPrefix: "gb", linearTeam: "Studio", linearIssuePrefix: "RLS", extraPath: "/only" }), extraPath: "/only" }, facts, { harness: { linearTeam: "MOB" } });
  assert.deepEqual([e.githubLogin, e.branchPrefix, e.linearTeam, e.linearIssuePrefix, e.extraPath], ["me", "gb", "Studio", "RLS", "/only"]);
});

test("nothing known: the old defaults", () => {
  const e = id.apply(fresh(), {}, {});
  assert.deepEqual([e.branchPrefix, e.slackUserName, e.linearIssuePrefix, e.pipelineModel], ["task", "the user", "ISSUE", "opus"]);
});

test.after(() => fs.rmSync(tmp, { recursive: true, force: true }));
