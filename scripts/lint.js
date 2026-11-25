#!/usr/bin/env node
/**
 * `npm run lint`: the checks that need nothing installed. Every server-side
 * script must parse, every committed JSON file must parse, and nothing may
 * require a package outside Node's standard library (the server has zero
 * dependencies, and stays that way).
 */

const fs = require("fs");
const path = require("path");
const { isBuiltin } = require("module");
const { spawnSync } = require("child_process");

const ROOT = path.join(__dirname, "..");
const DIRS = ["lib", "harness", "scripts", "test", "templates"];
const FILES = ["index.js", "bin/sb"];

function walk(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
    const p = path.join(dir, e.name);
    return e.isDirectory() ? walk(p) : [p];
  });
}

const all = [...FILES.map((f) => path.join(ROOT, f)), ...DIRS.flatMap((d) => walk(path.join(ROOT, d)))];
const scripts = all.filter((f) => f.endsWith(".js") || FILES.includes(path.relative(ROOT, f)));
const json = [...all, ...walk(path.join(ROOT, "docs")), path.join(ROOT, "data/config.example.json")].filter((f) => f.endsWith(".json"));
const errors = [];

for (const file of scripts) {
  const rel = path.relative(ROOT, file);
  const check = spawnSync(process.execPath, ["--check", file], { encoding: "utf8" });
  if (check.status !== 0) errors.push(check.stderr.trim());
  const src = fs.readFileSync(file, "utf8");
  for (const [, name] of src.matchAll(/\brequire\(\s*["']([^"']+)["']\s*\)/g)) {
    if (name.startsWith(".") || name.startsWith("/")) continue;
    if (!isBuiltin(name)) errors.push(`${rel}: requires "${name}", which is not part of Node's standard library`);
  }
}

for (const file of json) {
  try {
    JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (e) {
    errors.push(`${path.relative(ROOT, file)}: ${e.message}`);
  }
}

if (errors.length) {
  console.error(errors.join("\n"));
  process.exit(1);
}
console.log(`lint: ${scripts.length} scripts and ${json.length} JSON files ok`);
