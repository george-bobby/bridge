const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const os = require("os");
const path = require("path");

test("dotenv edits values in place and keeps comments and unknown keys", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "bridge-env-"));
  const file = path.join(dir, ".env");
  fs.writeFileSync(file, "# mine\nGITHUB_LOGIN=old   # who opens PRs\nCUSTOM_THING=1\n");
  process.env.BRIDGE_ENV_FILE = file;
  delete require.cache[require.resolve("../server/env")];
  delete require.cache[require.resolve("../server/dotenv")];
  const dotenv = require("../server/dotenv");
  dotenv.save({ GITHUB_LOGIN: "new", PRODUCT_NAME: "Acme Store" });
  const text = fs.readFileSync(file, "utf8");
  assert.match(text, /^# mine$/m);
  assert.match(text, /^GITHUB_LOGIN=new   # who opens PRs$/m);
  assert.match(text, /^CUSTOM_THING=1$/m);
  assert.match(text, /^PRODUCT_NAME="Acme Store"$/m);
  const { entries } = dotenv.describe();
  assert.ok(entries.some((e) => e.key === "CUSTOM_THING" && e.section === "Other"));
  assert.throws(() => dotenv.save({ X: "a\nb" }), /one line/);
  fs.rmSync(dir, { recursive: true, force: true });
});
