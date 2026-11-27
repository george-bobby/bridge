// Preview links from what GitHub knows about a PR's head commit: deployments,
// commit statuses and the Vercel/Netlify bot comments.
const test = require("node:test");
const assert = require("node:assert/strict");
const { previews } = require("../server/previews");

test("deployments: the latest status per environment, inactive and URL-less ones skipped", () => {
  const out = previews({
    deployments: [
      { environment: "Preview – web", state: "INACTIVE", latestStatus: { state: "INACTIVE", environmentUrl: "https://web-old-acme.vercel.app" } },
      { environment: "Preview – web", state: "ACTIVE", latestStatus: { state: "SUCCESS", environmentUrl: "https://web-git-feat-acme.vercel.app" } },
      { environment: "Preview – docs", state: "IN_PROGRESS", latestStatus: { state: "IN_PROGRESS", environmentUrl: "" } },
      { environment: "deploy-preview", state: "ACTIVE", latestStatus: { state: "SUCCESS", environmentUrl: "https://deploy-preview-12--site.netlify.app" } },
    ],
  });
  assert.deepEqual(
    out.map((p) => [p.provider, p.url, p.state]),
    [
      ["netlify", "https://deploy-preview-12--site.netlify.app", "ready"],
      ["vercel", "https://web-git-feat-acme.vercel.app", "ready"],
    ],
  );
});

test("statuses: Netlify's deploy-preview target counts, Vercel's dashboard link doesn't", () => {
  const out = previews({
    statuses: [
      { context: "Vercel", state: "SUCCESS", targetUrl: "https://vercel.com/acme/web/AbC123" },
      { context: "netlify/site/deploy-preview", state: "PENDING", targetUrl: "https://deploy-preview-12--site.netlify.app" },
      { context: "ci/circleci", state: "SUCCESS", targetUrl: "https://circleci.com/gh/acme/web/1" },
    ],
  });
  assert.deepEqual(out, [{ provider: "netlify", url: "https://deploy-preview-12--site.netlify.app", state: "building", env: "netlify/site/deploy-preview" }]);
});

test("bot comments are the fallback: the latest Vercel comment's preview, not its dashboard or feedback links", () => {
  const body = (status, host) =>
    `[vc]: #abc\n**The latest updates on your projects**.\n\n| Name | Status | Preview | Updated |\n| :--- | :----- | :------ | :------ |\n| **web** | ${status} ([Inspect](https://vercel.com/acme/web/X1)) | [Visit Preview](https://${host}) | 💬 [**Add feedback**](https://vercel.live/open-feedback/${host}) | Nov 27, 2026 |`;
  const comments = [
    { author: { login: "vercel" }, body: body("🔄 Building", "web-old-acme.vercel.app") },
    { author: { login: "maya" }, body: "see https://not-a-bot.vercel.app" },
    { author: { login: "vercel" }, body: body("✅ Ready", "web-git-feat-acme.vercel.app") },
  ];
  assert.deepEqual(previews({ comments }), [{ provider: "vercel", url: "https://web-git-feat-acme.vercel.app", state: "ready", env: "web-git-feat-acme.vercel.app" }]);
  // Deployments win over comments.
  const deployments = [{ environment: "Preview", state: "ACTIVE", latestStatus: { state: "SUCCESS", environmentUrl: "https://from-deploy.vercel.app" } }];
  assert.deepEqual(previews({ comments, deployments }).map((p) => p.url), ["https://from-deploy.vercel.app"]);
});

test("Netlify's bot comment", () => {
  const body = "### <span aria-hidden=\"true\">✅</span> Deploy Preview for *site* ready!\n\n|  Name | Link |\n|:-:|------------------------|\n|<span aria-hidden=\"true\">🔨</span> Latest commit | abc |\n|<span aria-hidden=\"true\">😎</span> Deploy Preview | [https://deploy-preview-7--site.netlify.app](https://deploy-preview-7--site.netlify.app) |";
  assert.deepEqual(previews({ comments: [{ author: { login: "netlify" }, body }] }).map((p) => [p.provider, p.url, p.state]), [["netlify", "https://deploy-preview-7--site.netlify.app", "ready"]]);
});

test("Netlify: one comment per site; a cancelled rebuild keeps the last good link", () => {
  const ready = (site, n) => `### ✅ Deploy Preview for *${site}* ready!\n\n| 😎 Deploy Preview | [https://deploy-preview-${n}--${site}.netlify.app](https://deploy-preview-${n}--${site}.netlify.app) |`;
  const canceled = (site) => `### ✅ Deploy Preview for *${site}* canceled.\n\n| 🔍 Latest deploy log | https://app.netlify.com/projects/${site}/deploys/1 |`;
  const comments = [
    { author: { login: "netlify" }, body: ready("gym", 9) },
    { author: { login: "netlify" }, body: ready("studio", 9) },
    { author: { login: "netlify" }, body: canceled("gym") },
  ];
  assert.deepEqual(previews({ comments }).map((p) => p.url).sort(), ["https://deploy-preview-9--gym.netlify.app", "https://deploy-preview-9--studio.netlify.app"]);
  // A site that was never deployed has nothing to open.
  assert.deepEqual(previews({ comments: [{ author: { login: "netlify" }, body: canceled("docs") }] }), []);
});

test("nothing to show", () => {
  assert.deepEqual(previews({}), []);
  assert.deepEqual(previews({ deployments: [null], statuses: [{ context: "x", state: "SUCCESS", targetUrl: null }] }), []);
});
