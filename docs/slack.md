# Connecting Slack

Bridge reads Slack as **you**, with a user token. There is no bot: nothing to
invite, nothing to add to any channel. It can read what you can read, and it
posts only when you press Reply.

Slack only issues tokens to an app, so you create a small one once and install
it to yourself:

1. Open https://api.slack.com/apps and choose **Create New App → From a manifest**.
2. Pick your workspace and paste [`manifest.json`](manifest.json).
3. **Install to Workspace** and allow it. (Some workspaces require an admin to
   approve new apps first; it's then approved once, for you.)
4. Copy the **User OAuth Token** (`xoxp-…`) from **OAuth & Permissions**.
5. In Bridge: **Settings → Environment → SLACK_USER_TOKEN**, paste, **Save and restart**.

What the scopes are for:

| Scope | Used for |
| --- | --- |
| `search:read` | your mentions (the Slack page) |
| `channels:history`, `groups:history`, `im:history`, `mpim:history` | reading a thread |
| `channels:read`, `groups:read`, `im:read`, `mpim:read`, `users:read` | channel and people names |
| `chat:write` | replying in a thread, as you, when you press Reply |

The token stays in `.env` on your machine. The server reads it and strips it
from the environment that Claude sessions inherit; the app never sees it.

The Slack pipeline the workers run still reads threads through Claude Code's
own Slack connector; this token powers Bridge's own views.
