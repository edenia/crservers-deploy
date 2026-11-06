#!/usr/bin/env bash
# Runs a large deploy end to end against a local FTPS server: the workflow's steps exactly as written
# (extracted with yq) and the real FTP-Deploy-Action at the commit the workflow pins.
# Proves that a change too big for one run stops cleanly, resumes without re-sending, and ends with
# the same server contents and state as an ordinary deploy.
# shellcheck disable=SC2016,SC2034 # checks are single-quoted on purpose: check() evals them later
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
WF="$repo/.github/workflows/deploy.yml"
PAGES=${PAGES:-2500}
PORT=${PORT:-2121}
tmp=$(mktemp -d)
log="$tmp/ftp.log"
srv="$tmp/server"
STATE=.htcrservers-deploy-state.json
server_pid=""
cleanup() { [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null; chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT
fails=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# --- tools ------------------------------------------------------------------------------------
python3 -m venv "$tmp/venv"
"$tmp/venv/bin/pip" install --quiet --disable-pip-version-check 'pyftpdlib==2.0.1' 'pyopenssl==25.1.0'
sha=$(yq -r '.jobs.deploy.steps[] | select(.name == "Deploy via FTP") | .uses' "$WF" | sed 's/.*@//')
curl -fsSL -o "$tmp/action.js" "https://raw.githubusercontent.com/SamKirkland/FTP-Deploy-Action/$sha/dist/index.js"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=127.0.0.1 -keyout "$tmp/cert.pem" -out "$tmp/cert.pem.crt" 2>/dev/null
cat "$tmp/cert.pem.crt" >> "$tmp/cert.pem"

mkdir -p "$srv/site/uploads"
echo "written by the app on the server" > "$srv/site/uploads/keep.jpg"
touch "$log"
"$tmp/venv/bin/python" "$repo/test/ftps-server.py" "$srv" "$PORT" "$tmp/cert.pem" "$log" > "$tmp/server.out" 2>&1 &
server_pid=$!
for _ in $(seq 1 50); do (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && break; sleep 0.1; done

# --- the workflow's steps ---------------------------------------------------------------------
cd "$tmp"
step() { yq -r ".jobs.deploy.steps[] | select(.name == \"$1\") | .run" "$WF" > "$tmp/$2"; test -s "$tmp/$2"; }
step "Upload large change in batches" batches.py
step "Measure the upload" measure.sh
step "Job summary" summary.sh
export FTP_HOST="127.0.0.1:$PORT" FTP_USER=deploy FTP_PASSWORD='pa"ss\word' FTP_PROTOCOL=ftps FTP_SECURITY=loose
export FTP_TIMEOUT_MS=60000 LOCAL_DIR=./out/ STATE_NAME="$STATE" FTP_REMOTE_PATH_NORMALIZED=site/ RUNNER_TEMP="$tmp"
export CRS_FILES_PER_SECOND=2 CRS_BYTES_PER_SECOND=5242880 CRS_BATCH_ABOVE_SECONDS=600
export GITHUB_STEP_SUMMARY="$tmp/summary.md" GITHUB_OUTPUT="$tmp/output"
EXCLUDE=$'**/.git*\n**/.git*/**\n**/node_modules/**\nprivate/**\n**/.env\n**/.env.*\nuploads/**'

action() { # action <dry-run true|false>
  env INPUT_SERVER=127.0.0.1 INPUT_PORT="$PORT" INPUT_USERNAME=deploy INPUT_PASSWORD="$FTP_PASSWORD" INPUT_PROTOCOL=ftps INPUT_SECURITY=loose \
    INPUT_EXCLUDE="$EXCLUDE" INPUT_TIMEOUT=60000 'INPUT_LOCAL-DIR=./out/' 'INPUT_SERVER-DIR=site/' "INPUT_STATE-NAME=$STATE" \
    'INPUT_LOG-LEVEL=minimal' "INPUT_DRY-RUN=$1" node "$tmp/action.js"
}
batches() { # batches <seconds since the job started> <limit minutes> [dry run] [clean deploy]
  CRS_JOB_STARTED=$(( $(date +%s) - $1 )) DEPLOY_TIMEOUT=$2 DRY_RUN=${3:-false} CLEAN_DEPLOY=${4:-false} python3 "$tmp/batches.py"
}
stored() { grep "^STOR site/" "$log" | grep -c -v "$STATE" || true; }
mark() { cp "$log" "$tmp/log.before"; : > "$log"; }

# --- first deploy, by the action alone --------------------------------------------------------
mkdir -p out/private out/uploads out/gone "out/with space"
for i in $(seq 1 "$PAGES"); do
  mkdir -p "out/p/$i"; echo "page $i v1" > "out/p/$i/index.html"
done
echo "secret" > out/private/secret.json
echo "SECRET=1" > out/.env
echo "must not replace the server's copy" > out/uploads/local.jpg
echo "old" > out/gone/stale.html
echo "deny from all" > out/.htaccess
echo "weird v1" > "out/with space/café [1] {x}.html"
action false > "$tmp/first.out" 2>&1 || { sed 's/^/    /' "$tmp/first.out" | tail -20; bad "first deploy"; exit 1; }
total_files=$(( PAGES + 3 ))
check "first deploy uploaded $total_files files" '[ "$(stored)" -eq "$total_files" ]'

# --- a change to every page, too large for one run --------------------------------------------
for i in $(seq 1 "$PAGES"); do echo "page $i v2" > "out/p/$i/index.html"; done
rm -rf out/gone
echo "weird v2" > "out/with space/café [1] {x}.html"
mkdir -p out/brand/new/deep; echo "new" > out/brand/new/deep/page.html
changed=$(( PAGES + 2 ))

bash "$tmp/measure.sh" > /dev/null
check "a large site is measured as large" 'grep -q "^large=true" "$GITHUB_OUTPUT"'

mark
action true > "$tmp/plan.out" 2>&1
check "the listing step uploads nothing" '[ "$(stored)" -eq 0 ]'
check "the listing step leaves the action's file list" '[ -s "out/$STATE" ]'

# The limit is 20 minutes and 10 are reserved, so 3 seconds remain: one or two batches.
rc=0; batches $(( 600 - 3 )) 20 > "$tmp/run1.out" 2>&1 || rc=$?
first=$(stored)
check "run 1 fails instead of being cut off" '[ "$rc" -eq 1 ]'
check "run 1 warned up front that it can't fit" 'grep -q "::warning::$changed changed files need about" "$tmp/run1.out"'
check "run 1 says the upload did not finish" 'grep -q "### Upload did not finish" "$GITHUB_STEP_SUMMARY" && grep -q "Re-run the failed job" "$GITHUB_STEP_SUMMARY"'
check "run 1 sent part of the change ($first of $changed)" '[ "$first" -gt 0 ] && [ "$first" -lt "$changed" ]'
check "run 1 removed its file list from the upload folder" '[ ! -e "out/$STATE" ]'
check "run 1 deleted nothing" '[ -f "$srv/site/gone/stale.html" ]'
check "progress is on the server under the real name" 'python3 -c "
import json,sys
d={i[\"name\"]:i for i in json.load(open(sys.argv[1]))[\"data\"]}
assert d[\"gone/stale.html\"]
print(\"state entries:\",len(d))" "$srv/site/$STATE" > /dev/null && [ ! -e "$srv/site/$STATE.tmp" ]'
updated=$(python3 - "$srv/site/$STATE" out <<'PY'
import hashlib, json, sys
n = 0
for i in json.load(open(sys.argv[1]))["data"]:
    if i["type"] == "file" and i["name"].startswith("p/"):
        local = hashlib.sha256(open(sys.argv[2] + "/" + i["name"], "rb").read()).hexdigest()
        n += local == i["hash"]
print(n)
PY
)
check "the saved state records only what was sent ($updated)" '[ "$updated" -gt 0 ] && [ "$updated" -le "$first" ]'

# --- the re-run continues ---------------------------------------------------------------------
: > "$GITHUB_STEP_SUMMARY"
action true > "$tmp/plan2.out" 2>&1
batches 0 90 > "$tmp/run2.out" 2>&1
second=$(stored)
check "the re-run sent only the rest ($first + $(( second - first )) = $changed)" '[ "$second" -eq "$changed" ]'
check "no page was sent twice" '[ "$(grep "^STOR site/p/" "$log" | sort | uniq -d | wc -l | tr -d " ")" -eq 0 ]'
check "the re-run does not warn when the change fits" '! grep -q "::warning::" "$tmp/run2.out"'
check "the batches kept every page" 'grep -q "page 7 v2" "$srv/site/p/7/index.html"'
check "the batches handled spaces, brackets and accents" 'grep -q "weird v2" "$srv/site/with space/café [1] {x}.html"'
check "the batches created new nested folders" '[ -f "$srv/site/brand/new/deep/page.html" ]'

# --- the action finishes the job --------------------------------------------------------------
mark
action false > "$tmp/final.out" 2>&1
check "the final pass re-sends no site file" '[ "$(grep "^STOR site/" "$log" | grep -vc "$STATE")" -eq 0 ]'
check "the final pass deletes what left the site" '[ ! -e "$srv/site/gone/stale.html" ]'
check "private/ and .env were never uploaded" '[ ! -e "$srv/site/private" ] && [ ! -e "$srv/site/.env" ]'
check "protected paths were left alone" '[ -f "$srv/site/uploads/keep.jpg" ] && [ ! -e "$srv/site/uploads/local.jpg" ]'
if diff -r -x "$STATE" -x private -x .env -x uploads out "$srv/site" > "$tmp/diff.out"; then ok "server matches the build"; else bad "server differs from the build"; sed 's/^/    /' "$tmp/diff.out" | head; fi
rm -f "out/$STATE"
mark
action false > "$tmp/again.out" 2>&1
check "the next deploy finds nothing to do" '[ "$(grep "^STOR site/" "$log" | grep -vc "$STATE")" -eq 0 ] && [ "$(grep -c "^DELE" "$log")" -eq 0 ]'
rm -f "out/$STATE"

# --- dry run ----------------------------------------------------------------------------------
for i in $(seq 1 "$PAGES"); do echo "page $i v3" > "out/p/$i/index.html"; done
mark; : > "$GITHUB_STEP_SUMMARY"
action true > /dev/null 2>&1
batches 0 20 true > "$tmp/dry.out" 2>&1
check "a dry run uploads nothing" '[ "$(stored)" -eq 0 ]'
check "a dry run warns that the change can't fit" 'grep -q "::warning::$PAGES changed files need about" "$tmp/dry.out"'
check "a dry run reports the plan" 'grep -q "### Dry run: $PAGES of " "$GITHUB_STEP_SUMMARY"'

# --- clean deploy can't be split: warn, send nothing ------------------------------------------
: > "$GITHUB_STEP_SUMMARY"
action true > /dev/null 2>&1
batches 0 20 false true > "$tmp/clean.out" 2>&1
check "clean_deploy is left to the action" '[ "$(stored)" -eq 0 ]'
check "clean_deploy warns that it can't resume" 'grep -q "::warning::clean_deploy needs to upload" "$tmp/clean.out"'

# --- a file the server refuses stops the run, keeps progress ----------------------------------
action true > /dev/null 2>&1
rm -f "$srv/site/p/1/index.html"
chmod a-w "$srv/site/p/1"
rc=0; CRS_BATCH_ABOVE_SECONDS=0 batches 0 90 > "$tmp/refused.out" 2>&1 || rc=$?
chmod u+w "$srv/site/p/1"
check "a refused file fails the run with a clear message" '[ "$rc" -eq 1 ] && grep -q "::error::The upload did not finish: p/1/index.html failed 3 times" "$tmp/refused.out"'
check "the other files in the batches still arrive" '[ "$(grep -rl "v3" "$srv/site/p" | wc -l | tr -d " ")" -gt 0 ]'
refused_hash=$(python3 -c 'import json,sys; print({i["name"]: i for i in json.load(open(sys.argv[1]))["data"]}["p/1/index.html"]["hash"])' "$srv/site/$STATE")
check "the state does not claim the refused file arrived" '[ "$refused_hash" != "$(python3 -c "import hashlib; print(hashlib.sha256(open(\"out/p/1/index.html\", \"rb\").read()).hexdigest())")" ]'

# --- small site: the new steps stay out of the way -------------------------------------------
mkdir -p small/a; echo hi > small/a/index.html
: > "$GITHUB_OUTPUT"
LOCAL_DIR=./small/ bash "$tmp/measure.sh" > /dev/null
check "a small site skips the batch path" 'grep -q "^large=false" "$GITHUB_OUTPUT"'

# --- job summary after the job limit ----------------------------------------------------------
summary() { : > "$GITHUB_STEP_SUMMARY"; EVENT_NAME=push REF=refs/heads/main SHA=abc DRY_RUN=false CLEAN_DEPLOY=false SITE_URL="" BACKEND=false ENVIRONMENT="" PROTECTED_PATHS="" DEPLOY_TIMEOUT=90 "$@" bash "$tmp/summary.sh" > "$tmp/sum.out"; }
summary env FTP_OUTCOME=cancelled FTP_RETRY_OUTCOME=skipped BATCHES_OUTCOME=skipped
check "a limit during the action says a re-run starts over" 'grep -q "## Upload did not finish" "$GITHUB_STEP_SUMMARY" && grep -q "a re-run starts over" "$GITHUB_STEP_SUMMARY" && grep -q "deploy_timeout_minutes" "$GITHUB_STEP_SUMMARY" && grep -q "::error::The upload did not finish" "$tmp/sum.out"'
summary env FTP_OUTCOME="" FTP_RETRY_OUTCOME="" BATCHES_OUTCOME=cancelled
check "a limit during the batches says a re-run continues" 'grep -q "a re-run continues" "$GITHUB_STEP_SUMMARY" && ! grep -q "starts over" "$GITHUB_STEP_SUMMARY"'
summary env FTP_OUTCOME=success FTP_RETRY_OUTCOME="" BATCHES_OUTCOME=""
check "a finished deploy has no such message" '! grep -q "did not finish" "$GITHUB_STEP_SUMMARY" && grep -q "Job time limit:\*\* 90" "$GITHUB_STEP_SUMMARY"'

echo
if [ "$fails" -gt 0 ]; then echo "$fails large-deploy check(s) failed."; exit 1; fi
echo "All large-deploy checks passed."
