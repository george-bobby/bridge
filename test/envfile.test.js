const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const os = require("os");
const path = require("path");

test("envfile edits values in place and keeps comments and unknown keys", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "sb-env-"));
  const file = path.join(dir, ".env");
  fs.writeFileSync(file, "# mine\nGITHUB_LOGIN=old   # who opens PRs\nCUSTOM_THING=1\n");
  process.env.BRIDGE_ENV_FILE = file;
  delete require.cache[require.resolve("../lib/env")];
  delete require.cache[require.resolve("../lib/envfile")];
  const envfile = require("../lib/envfile");
  envfile.save({ GITHUB_LOGIN: "new", PRODUCT_NAME: "Acme Store" });
  const text = fs.readFileSync(file, "utf8");
  assert.match(text, /^# mine$/m);
  assert.match(text, /^GITHUB_LOGIN=new   # who opens PRs$/m);
  assert.match(text, /^CUSTOM_THING=1$/m);
  assert.match(text, /^PRODUCT_NAME="Acme Store"$/m);
  const { entries } = envfile.describe();
  assert.ok(entries.some((e) => e.key === "CUSTOM_THING" && e.section === "Other"));
  assert.throws(() => envfile.save({ X: "a\nb" }), /one line/);
  fs.rmSync(dir, { recursive: true, force: true });
});
