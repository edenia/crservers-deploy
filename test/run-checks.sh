#!/usr/bin/env bash
# Runs the deploy workflow's safety-check steps against test/fixtures, exactly as written in the
# workflow (extracted with yq), and checks which fixtures pass and which are blocked.
set -euo pipefail
cd "$(dirname "$0")/.."
WF=.github/workflows/deploy-static-site.yml
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

if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; exit 1; fi
echo "All safety-check tests passed."
