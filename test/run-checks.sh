#!/usr/bin/env bash
# Runs the deploy workflow's safety-check steps against test/fixtures, exactly as written in the
# workflow (extracted with yq), and checks which fixtures pass and which are blocked.
set -euo pipefail
cd "$(dirname "$0")/.."
WF=.github/workflows/deploy.yml
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export GITHUB_STEP_SUMMARY="$tmp/summary.md"

step() { yq -r ".jobs.build.steps[] | select(.name == \"$1\") | .run" "$WF" > "$tmp/step.sh"; test -s "$tmp/step.sh"; }
fails=0
expect() { # expect <pass|fail> <step name> <artifact dir> [grep pattern that output must contain]
  local want=$1 name=$2 art=$3 pattern=${4:-}
  step "$name"
  local rc=0
  ART="$art" ALLOW_FILES="${ALLOW_FILES:-}" BACKEND="${BACKEND:-false}" bash "$tmp/step.sh" > "$tmp/out" 2>&1 || rc=$?
  local got=pass; [ "$rc" -ne 0 ] && got=fail
  if [ "$got" != "$want" ] || { [ -n "$pattern" ] && ! grep -Eq -- "$pattern" "$tmp/out"; }; then
    echo "FAIL: $name on $art: expected $want${pattern:+ with /$pattern/}, got $got"; sed 's/^/    /' "$tmp/out"; fails=$((fails + 1))
  else
    echo "ok:   $name on $art -> $got"
  fi
}

G='Check: server-only files'
expect pass "$G" test/fixtures/good-site
expect fail "$G" test/fixtures/bad-site
for f in wp-config.php private/x.json .env dump.sql admin.php.bak-20261025; do
  expect fail "$G" test/fixtures/bad-site "file=$f::"
done
[ "$(grep -c '^::error' "$tmp/out")" -eq 5 ] || { echo "FAIL: expected exactly 5 blocked files in bad-site"; fails=$((fails + 1)); }
ALLOW_FILES=$'wp-config.php\nprivate/x.json\n.env\ndump.sql\nadmin.php.bak-20261025' expect pass "$G" test/fixtures/bad-site

P='Check: PHP'
expect pass "$P" test/fixtures/good-site
expect fail "$P" test/fixtures/bad-php 'file=broken.php::PHP syntax error'
expect fail "$P" test/fixtures/bad-php 'warning file=risky.php,line=2::'

# Lockfiles outside the upload are audited too (here: static-site-contact/composer.lock in this repo).
C='Check: Composer dependencies'
if command -v composer >/dev/null; then
  expect pass "$C" test/fixtures/good-site 'Auditing static-site-contact/composer.lock'
else
  echo "skip: $C (composer not installed here; CI runs it)"
fi

# The scanner can't be fetched (bogus version -> 404): static deploys warn and go on, backend deploys stop.
S='Check: secret scan (gitleaks)'
export GITLEAKS_VERSION=0.0.0-missing GITLEAKS_SHA256=0000 RUNNER_TEMP="$tmp"
expect pass "$S" test/fixtures/good-site 'warning::Secret scan skipped: could not download gitleaks'
BACKEND=true expect fail "$S" test/fixtures/good-site 'error::Secret scan unavailable'
unset GITLEAKS_VERSION GITLEAKS_SHA256

# Sync state before the upload, against a stub curl that keeps the "server" in a temp folder.
yq -r '.jobs.deploy.steps[] | select(.name == "Prepare sync state") | .run' "$WF" > "$tmp/state.sh"
srv="$tmp/srv"
new_state="$srv/site/.htcrservers-deploy-state.json"
old_state="$srv/site/.ftp-deploy-sync-state.json"
state() { # state <label> <setup function> <check function>
  rm -rf "$srv" "$srv.cfg"; mkdir -p "$srv/site"; : > "$tmp/ftp.log"
  "$2"
  local rc=0
  PATH="$PWD/test/stubs:$PATH" FAKE_FTP_ROOT="$srv" FAKE_FTP_LOG="$tmp/ftp.log" RUNNER_TEMP="$tmp/rt" \
    FTP_HOST=iwx41.example FTP_USER='deploy@example.com' FTP_PASSWORD='p"a\ss word' FTP_PROTOCOL=ftps FTP_SECURITY=strict \
    FTP_REMOTE_PATH_NORMALIZED=site/ STATE_NAME=.htcrservers-deploy-state.json OLD_STATE_NAME=.ftp-deploy-sync-state.json \
    bash "$tmp/state.sh" > "$tmp/out" 2>&1 || rc=$?
  unset FAKE_FTP_FAIL FAKE_FTP_NO_DELETE
  if [ "$rc" -eq 0 ] && "$3"; then echo "ok:   sync state: $1"; else
    echo "FAIL: sync state: $1 (exit $rc)"; sed 's/^/    /' "$tmp/out"; find "$srv" | sed 's/^/    /'; fails=$((fails + 1)); fi
}
none() { :; }
no_folder() { rm -rf "$srv/site"; }
old_only() { echo '{"version":"1.0.0","data":[{"name":"a.html"}]}' > "$old_state"; echo stray > "$srv/.ftp-deploy-sync-state.json"; }
both() { echo '{"data":[1]}' > "$new_state"; echo old > "$old_state"; }
offline() { export FAKE_FTP_FAIL=1; }
silent_delete() { old_only; export FAKE_FTP_NO_DELETE=silent; }
refused_delete() { old_only; export FAKE_FTP_NO_DELETE=fail; }
seeded() { [ "$(jq -r '.version, (.data|length)' "$new_state" | tr '\n' ' ')" = "1.0.0 0 " ] && [ ! -e "$old_state" ]; }
# The copy in the login folder must survive: only the site folder's file is deleted.
migrated() { [ "$(jq -r '.data[0].name' "$new_state")" = a.html ] && [ ! -e "$old_state" ] && [ -e "$srv/.ftp-deploy-sync-state.json" ] && grep -q "Removed the public" "$tmp/out"; }
kept() { [ "$(jq -c .data "$new_state")" = "[1]" ] && [ ! -e "$old_state" ] && ! grep -q -- "-T" "$tmp/ftp.log"; }
warned() { grep -q "::warning::Could not check" "$tmp/out" && [ ! -e "$new_state" ]; }
# Only claim the old file is gone when a fresh download says so.
not_removed() { [ -e "$old_state" ] && grep -q "::warning::Could not delete" "$tmp/out" && ! grep -q "Removed the public" "$tmp/out"; }
# The warning carries the DELE error, not the follow-up download's.
refused() { not_removed && grep -q "curl exit 21: curl: (21) QUOT command failed" "$tmp/out"; }
private() { ! grep -qF 'a\ss' "$tmp/ftp.log" && grep -qF 'user = "deploy@example.com:p\"a\\ss word"' "$srv.cfg"; }
state "first deploy seeds an empty state" none seeded
state "new folder (CWD refused): seeds an empty state and creates the folder" no_folder seeded
state "old public state moves to the private name (site folder only)" old_only migrated
state "already migrated: nothing uploaded, stray old copy removed" both kept
state "server unreachable: warns, upload goes ahead" offline warned
state "delete that does nothing: warns, never claims removal" silent_delete not_removed
state "delete refused: warning shows the DELE error" refused_delete refused
state "password stays out of the command line, escaped in the config" none private

if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; exit 1; fi
echo "All safety-check tests passed."
