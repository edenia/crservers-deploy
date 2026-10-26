#!/usr/bin/env bash
# crservers.com — one-time setup for contact.php (run from the site html root, next to contact.php)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

if [[ ! -f contact.php ]] || [[ ! -f composer.json ]]; then
  echo "Run this from the folder that contains contact.php and composer.json (e.g. ~/public_html or ~/DOMAIN/html)." >&2
  exit 1
fi

if command -v composer >/dev/null 2>&1; then
  echo "Installing PHPMailer into vendor/ …"
  composer install --no-dev --no-interaction
elif [[ -f composer.phar ]]; then
  echo "Installing PHPMailer via composer.phar …"
  php composer.phar install --no-dev --no-interaction
else
  echo "Composer not found on this account." >&2
  echo "Option A — on your Mac/Linux, from this same folder run:" >&2
  echo "  curl -sS https://getcomposer.org/installer | php" >&2
  echo "  php composer.phar install --no-dev --no-interaction" >&2
  echo "  rm -f vendor/phpmailer/phpmailer/get_oauth_token.php" >&2
  echo "  Then upload the new vendor/ directory next to contact.php." >&2
  echo "Option B — ask your host to enable the Composer CLI for your SSH user." >&2
  exit 1
fi

# PHPMailer's OAuth helper is a script meant to be run once by hand. vendor/ sits in the web root, so it
# would be reachable on the web (found live on several sites, 2026-10-26); the form doesn't use OAuth.
rm -f vendor/phpmailer/phpmailer/get_oauth_token.php

PARENT="$(cd "$DIR/.." && pwd)"
GRANDPARENT="$(cd "$DIR/../.." && pwd)"

# DOMAIN/html → account ~/private is two levels up; public_html → one level up (../private)
if [[ "$(basename "$DIR")" == "html" ]]; then
  ACCOUNT_PRIVATE="$GRANDPARENT/private"
  DOMAIN_PRIVATE="$PARENT/private"
else
  ACCOUNT_PRIVATE="$PARENT/private"
  DOMAIN_PRIVATE="$PARENT/private"
fi

mkdir -p "$ACCOUNT_PRIVATE"
if [[ "$DOMAIN_PRIVATE" != "$ACCOUNT_PRIVATE" ]]; then
  mkdir -p "$DOMAIN_PRIVATE"
fi

CFG="$ACCOUNT_PRIVATE/smtp.config.php"
if [[ ! -f "$CFG" ]]; then
  cp smtp.config.example.php "$CFG"
  chmod 600 "$CFG" || true
  echo ""
  echo "Created $CFG — edit it with your mailbox password, mail_to, and SMTP host if needed."
else
  echo "Config already exists: $CFG (left unchanged)"
fi

echo ""
echo "Done. Test with your live contact form or curl (see SETUP.md §7)."
