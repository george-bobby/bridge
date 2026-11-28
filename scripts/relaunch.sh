#!/usr/bin/env bash
#
# Bring this Bridge up to the latest main and reopen it: fast-forward the
# checkout, rebuild the app only when its sources changed, restart the
# server only when what it serves changed, swap the app into ~/Applications
# and open it.
#
#   ./scripts/relaunch.sh           the whole run, in the foreground
#   ./scripts/relaunch.sh plan      print the same decisions as JSON; nothing moves
#   ./scripts/relaunch.sh --detach  the run in the background on its own
#                                   process group, so it survives the server
#                                   restart it performs; logs/relaunch.log
#
# Env: BRIDGE_ROOT (the checkout to work on; default this repo — point it at
# the main checkout to run a worktree's copy of this script against it),
# BRIDGE_PORT (the server to check and restart; default .env's, then 4319),
# LAUNCHD_LABEL (the dashboard job's name; default .env's, then local.bridge),
# BRIDGE_APP_DST (where the app installs; default ~/Applications/Bridge.app),
# BRIDGE_APP_PID (a running Bridge.app to wait out before `open`; the app
# passes its own pid and exits when it reads "step reopen"),
# BRIDGE_RELAUNCH_HEAD / BRIDGE_RELAUNCH_RESTART (the head and restart the
# user confirmed from `plan`; the run stops before touching anything if a
# fresh plan disagrees).
#
# "step <name>" lines mark the phases for the app's progress label.

set -uo pipefail
# A reader that goes away mid-run (the app quitting on "step reopen") must not
# take the script down with a SIGPIPE.
trap '' PIPE

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${BRIDGE_ROOT:-$(cd "$HERE/.." && pwd)}"
LOG="$ROOT/logs/relaunch.log"
APP_DST="${BRIDGE_APP_DST:-$HOME/Applications/Bridge.app}"

say() { echo "$*"; }
die() { say "error: $*" >&2; exit 1; }
step() { say "step $1"; }

# The run detached: a new process group (setsid, via node's detached spawn)
# keeps it alive when the server — possibly its own parent — goes down.
if [[ "${1:-}" == "--detach" ]]; then
  mkdir -p "$ROOT/logs"
  node -e '
    const { spawn } = require("child_process"), fs = require("fs");
    const out = fs.openSync(process.argv[1], "a");
    spawn("/bin/bash", [process.argv[2]], { detached: true, stdio: ["ignore", out, out], env: process.env }).unref();
  ' "$LOG" "$0" || die "couldn't detach the relaunch"
  echo "relaunching in the background; follow $LOG"
  exit 0
fi

command -v node >/dev/null || die "node is not on PATH"

# One key out of .env, parsed the way the server does (never echoed).
envval() {
  node -e 'const fs=require("fs");const m=fs.readFileSync(process.argv[1],"utf8").match(new RegExp("^\\s*(?:export\\s+)?"+process.argv[2]+"\\s*=\\s*[\"\x27]?([^\"\x27#\\s]*)","m"));process.stdout.write(m?m[1]:"")' "$ROOT/.env" "$1" 2>/dev/null
}

PORT="${BRIDGE_PORT:-$(envval BRIDGE_PORT)}"
PORT="${PORT:-4319}"
DASH_LABEL="${LAUNCHD_LABEL:-$(envval LAUNCHD_LABEL)}"
DASH_LABEL="${DASH_LABEL:-local.bridge}.dashboard"

gitrepo() { command git -C "$ROOT" "$@"; }
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP_DST/Contents/Info.plist" 2>/dev/null; }

# The trees build.sh's output depends on: change one and the stamp changes.
head_stamp() { gitrepo rev-parse "$1:app" "$1:scripts" "$1:package.json" 2>/dev/null | paste -sd- -; }

served_head() {
  curl -sf --max-time 2 "http://127.0.0.1:$PORT/api/state" 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(String(JSON.parse(s).meta.head||""))}catch{}})'
}

# Paths that change what the server runs. app/, docs/, tests and the rest
# are no reason to kill live sessions.
server_files() { grep -Eq '^(server|prompts|hooks|skills|bin|scripts)/|^package\.json$'; }

GIT_OK=0
gitrepo rev-parse --git-dir >/dev/null 2>&1 && GIT_OK=1

BRANCH=""; BEHIND=0; AHEAD=0; MERGE=0; REASON=""
OLD_HEAD=""; NEW_HEAD=""; SERVER_UP=0; SERVER_HEAD=""

# Decide git and the server state. Fetch failures land in REASON, not a crash:
# a relaunch without a pull is still worth doing.
collect() {
  if (( GIT_OK )); then
    OLD_HEAD="$(gitrepo rev-parse HEAD 2>/dev/null)"
    if ! gitrepo fetch origin --quiet; then
      REASON="couldn't reach origin"
    else
      BRANCH="$(gitrepo symbolic-ref --short -q HEAD)"
      BEHIND="$(gitrepo rev-list --count HEAD..origin/main 2>/dev/null || echo 0)"
      AHEAD="$(gitrepo rev-list --count origin/main..HEAD 2>/dev/null || echo 0)"
      if [[ "$BRANCH" != main ]]; then REASON="on branch ${BRANCH:-detached HEAD}, not main"
      elif [[ -n "$(gitrepo status --porcelain --untracked-files=no)" ]]; then REASON="uncommitted changes in the checkout"
      elif (( AHEAD > 0 )); then REASON="$AHEAD unpushed commit(s) on main"
      elif (( BEHIND == 0 )); then REASON="already on the latest main"
      else MERGE=1; fi
    fi
  else
    REASON="not a git checkout"
  fi
  NEW_HEAD="$OLD_HEAD"
  (( MERGE )) && NEW_HEAD="$(gitrepo rev-parse origin/main 2>/dev/null)"
  if curl -sf --max-time 2 -o /dev/null "http://127.0.0.1:$PORT/api/state"; then
    SERVER_UP=1
    SERVER_HEAD="$(served_head)"
  fi
}

# Rebuild when the installed app is missing, was built from another checkout,
# or its stamped sources differ from the head we'll be on.
want_build() {
  (( GIT_OK )) || return 1
  [[ -d "$APP_DST" ]] || return 0
  [[ "$(plist BridgeRoot)" == "$ROOT" ]] || return 0
  local ours theirs
  ours="$(head_stamp "$NEW_HEAD")"
  theirs="$(plist BridgeSourceStamp)"
  [[ -n "$ours" && "$ours" != "$theirs" ]]
}

# Restart when the server is down, or what it serves differs from the head
# we'll be on in a file it runs. Commits that only touched the app don't earn
# a restart; a server whose commit is unknown always gets one.
want_restart() {
  (( SERVER_UP )) || return 0
  [[ -n "$SERVER_HEAD" && -n "$NEW_HEAD" ]] || return 0
  [[ "$SERVER_HEAD" == "$NEW_HEAD" ]] && return 1
  local files
  files="$(gitrepo diff --name-only "$SERVER_HEAD" "$NEW_HEAD" 2>/dev/null)" || return 0
  server_files <<<"$files"
}

decide() {
  BUILD=0; want_build && BUILD=1
  RESTART=0; want_restart && RESTART=1
}

if [[ "${1:-}" == "plan" ]]; then
  collect
  decide
  ROOT="$ROOT" PORT="$PORT" BEHIND="$BEHIND" AHEAD="$AHEAD" BRANCH="$BRANCH" MERGE="$MERGE" REASON="$REASON" \
    BUILD="$BUILD" RESTART="$RESTART" SERVER_UP="$SERVER_UP" NEW_HEAD="$NEW_HEAD" \
    node -e 'const e=process.env,b=(k)=>e[k]==="1";
      console.log(JSON.stringify({ok:true,root:e.ROOT,port:Number(e.PORT),behind:Number(e.BEHIND),ahead:Number(e.AHEAD),branch:e.BRANCH,merge:e.MERGE==="1",reason:e.REASON,build:b("BUILD"),restart:b("RESTART"),serverUp:b("SERVER_UP"),head:e.NEW_HEAD}))'
  exit 0
fi

mkdir -p "$ROOT/logs"
exec > >(tee -a "$LOG") 2>&1
say "--- relaunch $(date '+%Y-%m-%d %H:%M:%S') on $ROOT"

collect
decide

if [[ -n "${BRIDGE_RELAUNCH_HEAD+x}" ]] && [[ "$NEW_HEAD" != "$BRIDGE_RELAUNCH_HEAD" || "$RESTART" != "${BRIDGE_RELAUNCH_RESTART:-$RESTART}" ]]; then
  die "main moved since you confirmed; nothing was changed, press Relaunch again"
fi

if (( MERGE )); then
  step updating
  say "pulling $BEHIND commit(s) into $ROOT"
  gitrepo merge --ff-only origin/main || die "the pull failed; the checkout is untouched"
  NEW_HEAD="$(gitrepo rev-parse HEAD 2>/dev/null)"
else
  say "leaving git alone: ${REASON:-nothing to pull}"
fi

if (( BUILD )); then
  step building
  (cd "$ROOT" && ./scripts/build.sh) || die "the app build failed"
else
  say "the app is already built from this code"
fi

if (( RESTART )); then
  step restarting
  if [[ -f "$ROOT/.env" ]]; then
    "$ROOT/scripts/install.sh" start || die "the server didn't restart (install.sh failed)"
  elif launchctl print "gui/$UID/$DASH_LABEL" >/dev/null 2>&1; then
    node "$ROOT/server/render.js" || true
    launchctl kickstart -k "gui/$UID/$DASH_LABEL" || die "couldn't restart the server"
  else
    die "nothing restarts the server: no .env for npm start, no launchd job"
  fi
  for _ in $(seq 1 60); do
    curl -sf --max-time 1 -o /dev/null "http://127.0.0.1:$PORT/api/state" && break
    sleep 0.5
  done
  curl -sf --max-time 2 -o /dev/null "http://127.0.0.1:$PORT/api/state" || die "the server isn't answering on :$PORT"
  say "the server is back on :$PORT"
else
  say "the server keeps running"
fi

# Copy beside the installed app first and swap only once the copy is whole,
# so a failed install leaves the running app and its bundle as they were.
if (( BUILD )); then
  APPS="$(dirname "$APP_DST")"
  NEXT="$APPS/.$(basename "$APP_DST").next"
  PREV="$APPS/.$(basename "$APP_DST").prev"
  mkdir -p "$APPS"
  rm -rf "$NEXT" "$PREV"
  cp -R "$ROOT/dist/Bridge.app" "$NEXT" || { rm -rf "$NEXT"; die "couldn't copy the app into $APPS; the installed one is untouched"; }
  if [[ -d "$APP_DST" ]]; then mv "$APP_DST" "$PREV" || { rm -rf "$NEXT"; die "couldn't move the installed app aside"; }; fi
  if ! mv "$NEXT" "$APP_DST"; then
    [[ -d "$PREV" ]] && mv "$PREV" "$APP_DST"
    die "couldn't swap in the new build; the previous one is back"
  fi
  rm -rf "$PREV"
  say "swapped in the new build"
fi
step reopen
# `open` only focuses a running instance, so the old app has to be gone first:
# the app exits on "step reopen"; a stray pid gets a moment, then a push.
if [[ -n "${BRIDGE_APP_PID:-}" ]]; then
  for _ in $(seq 1 40); do
    kill -0 "$BRIDGE_APP_PID" 2>/dev/null || break
    sleep 0.25
  done
  kill -9 "$BRIDGE_APP_PID" 2>/dev/null || true
fi
open "$APP_DST" || die "couldn't open $APP_DST"
say "done: on $(gitrepo rev-parse --short HEAD 2>/dev/null || echo '?'), server on :$PORT"
