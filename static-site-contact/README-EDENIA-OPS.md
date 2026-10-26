# Edenia / crservers — pre-copy `static-site-contact` onto InterWorx

This folder is the **canonical** mail-endpoint bundle for static sites on **crservers.com** (Apache + PHP-FPM + SMTP auth). Customer **Next.js** repos copy from here into `utils/contact-form/` when we change PHP behavior; **new hosting accounts** can receive this folder **as-is** so users only run one script and edit one config file.

## What to copy to a new account

From a clone of **edenia/crservers-deploy**, sync into the domain **document root** on the account. On InterWorx this is often **`~/example.com/html/`** (FTP-relative: `example.com/html/` — see root README [InterWorx paths](../README.md#interworx--crservers-ftp-paths)). Replace `DOMAIN` below.

```bash
# Example: from your workstation (replace HOST, USER, DOMAIN)
REMOTE_WEBROOT='USER@HOST:~/DOMAIN/html/'

rsync -avz --delete-excluded \
  --exclude '.git' \
  ./static-site-contact/ "$REMOTE_WEBROOT"
```

Prefer **`--delete-excluded`** only if you intend to mirror exactly; otherwise omit `--delete` to avoid removing unrelated site files. **Safer** pattern — copy only bundle files:

```bash
rsync -avz \
  ./static-site-contact/contact.php \
  ./static-site-contact/composer.json \
  ./static-site-contact/composer.lock \
  ./static-site-contact/install-on-server.sh \
  ./static-site-contact/smtp.config.example.php \
  ./static-site-contact/USERS-EASY-START.md \
  "$REMOTE_WEBROOT"
```

Then SSH:

```bash
ssh USER@HOST 'cd ~/DOMAIN/html && chmod +x install-on-server.sh && bash install-on-server.sh'
```

## After copy

- **`install-on-server.sh`** runs `composer install --no-dev` and creates **`~/private/smtp.config.php`** (from `DOMAIN/html`) or **`../private/smtp.config.php`** (from `public_html`).
- Tell the customer to **edit that config file** (mailbox password, `mail_to`, etc.) or set **env vars** if you inject secrets at the panel level.

## Gotchas

- **File ownership.** If you run the install or edit the config as `root` (for example over SSH from NodeWorx), PHP-FPM runs as the site user and can't read the files, so the form fails. Hand them back to the account's user:

  ```bash
  chown -R ACCOUNT:ACCOUNT ~ACCOUNT/private/smtp.config.php ~ACCOUNT/DOMAIN/html/vendor
  ```

- **Phone-only forms.** `require_reply_email` is `true` by default, so a submission without a valid `email` field (or the field named in `reply_to_field`) is rejected. For forms that only ask for a phone number, set `'require_reply_email' => false` in `smtp.config.php`.

## Smoke test

After install and config, post a test submission. Use the site's real field names. Any non-honeypot field gets emailed.

```bash
curl -sS -X POST 'https://DOMAIN/contact.php' \
  -H 'X-Requested-With: XMLHttpRequest' -H 'Accept: application/json' \
  -F 'name=Test' -F 'email=test@example.com' -F 'message=Smoke test'
# → {"ok":true,"error":""}
```

If Turnstile is configured (`turnstile_secret` or `TURNSTILE_SECRET`), this fails without a valid `cf-turnstile-response` token. Test through the browser form instead, or use Cloudflare's test keys on a staging site.

## Keeping in sync

When **`contact.php`** or Composer pins change:

1. Update **`static-site-contact/`** in this repo (PR + tag if needed).
2. Re-copy to accounts that need the fix **or** ship updates via customer site rebuilds that include `utils/contact-form/` from the same commit.

See **`CANONICAL-SOURCE.txt`** in the customer repo `utils/contact-form/` for the same pointer.
