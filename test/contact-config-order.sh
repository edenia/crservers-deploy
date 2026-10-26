#!/usr/bin/env bash
# contact.php reads ~/DOMAIN/private/smtp.config.php before ~/private/smtp.config.php (the first found wins).
# Runs contact.php from the PHP CLI against a fake account: the account-level file is incomplete, the
# domain-level one complete, so "not configured" means the wrong file was read.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
home="$tmp/home/acct"
mkdir -p "$home/private" "$home/example.com/private" "$home/example.com/html/vendor"
cp static-site-contact/contact.php "$home/example.com/html/"
echo '<?php' > "$home/example.com/html/vendor/autoload.php"
echo '<?php return ["smtp_host" => ""];' > "$home/private/smtp.config.php"
cat > "$home/example.com/private/smtp.config.php" <<'PHP'
<?php return ['smtp_host' => 'mail.example.com', 'smtp_user' => 'f@example.com', 'smtp_pass' => 'x', 'mail_from_email' => 'f@example.com', 'mail_to' => 'o@example.com'];
PHP

run() { REQUEST_METHOD=POST HTTP_ACCEPT=application/json REMOTE_ADDR=192.0.2.1 php "$home/example.com/html/contact.php" 2>&1 || true; }

fails=0
out=$(run)
if grep -q 'not configured' <<<"$out"; then
  echo "FAIL: domain-level config should win over the account level: $out"; fails=$((fails + 1))
elif ! grep -q '"ok":false' <<<"$out"; then
  echo "FAIL: expected a JSON validation error after loading the domain config: $out"; fails=$((fails + 1))
else
  echo "ok:   domain-level config wins"
fi

rm "$home/example.com/private/smtp.config.php"
out=$(run)
if grep -q 'not configured' <<<"$out"; then
  echo "ok:   account-level config is the fallback"
else
  echo "FAIL: without a domain-level file the account-level file should be read: $out"; fails=$((fails + 1))
fi
exit "$fails"
