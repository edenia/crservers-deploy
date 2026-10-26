# First-time setup (InterWorx / crservers static site)

Do this **once per SiteWorx account** (or whenever SMTP credentials change).  
Applies to any static or Next.js site on crservers that uses the `utils/contact-form/` bundle (copied from this repo).

## Fast path (most customers)

Read **`USERS-EASY-START.md`** — two short paths: **pre-provisioned files** on the account (run `install-on-server.sh` + edit one config file) **or** static export from GitHub then the same server steps.

**Canonical bundle to copy onto new accounts (Edenia ops):**  
[edenia/crservers-deploy — `static-site-contact/`](https://github.com/edenia/crservers-deploy/tree/main/static-site-contact)

---

## 1. SiteWorx: mailbox for sending

1. Log in to **SiteWorx** for the domain.
2. **Email → Add mailbox** (e.g. `forms@yourdomain.com`).
3. Note the password you set — this is the **SMTP password** (keep it secret).

Use your host’s SMTP hostname (often **`mail.yourdomain.com`** or the hostname InterWorx lists).  
Typical ports: **587** + **TLS (STARTTLS)**, or **465** + **SSL**.

---

## 2. Deploy the static site

Merge the GitHub PR and let Actions **FTP** the `out/` folder so the web root contains:

- `index.html`, assets, `.htaccess`, and **`contact.php`** (exported from `public/`).

---

## 3. SSH into the account (or terminal in the panel)

Replace `ACCOUNT` and paths with yours (`public_html` may differ).

```bash
cd ~/public_html
# Or: cd /home/ACCOUNT/public_html
```

Confirm **`contact.php`** is here (same directory as `index.html`).

---

## 4. Install PHPMailer (Composer)

Upload **`composer.json`** and **`composer.lock`** from the repo’s `utils/contact-form/` into this directory (if they are not already there from the deploy), then:

```bash
composer install --no-dev
```

You should see **`vendor/`** next to `contact.php`.  
If `composer` is not in PATH, use the full path your host documents (e.g. `/opt/cpanel/composer/bin/composer` — check InterWorx docs).

**Troubleshooting:** If Composer complains about PHP version, switch the domain to PHP 8.1+ in SiteWorx and retry.

---

## 5. Configure secrets (pick one pattern)

### Option A — Private PHP file (simple on shared hosting)

```bash
mkdir -p ~/private
cp /path/to/smtp.config.example.php ~/private/smtp.config.php
chmod 600 ~/private/smtp.config.php
nano ~/private/smtp.config.php   # set smtp_*, mail_from_*, mail_to, etc.
```

`contact.php` loads **`/home/ACCOUNT/private/smtp.config.php`** when the site lives under **`~/DOMAIN/html/`** (also checks **`~/DOMAIN/private/`** as a fallback).

### Option B — Environment variables (good if your host injects env into PHP)

Set in the panel or FPM pool, for example:

| Variable | Example |
|----------|---------|
| `SMTP_HOST` | `mail.yourdomain.com` |
| `SMTP_PORT` | `587` |
| `SMTP_SECURE` | `tls` |
| `SMTP_USER` | `forms@yourdomain.com` |
| `SMTP_PASSWORD` | *(mailbox password)* |
| `MAIL_FROM_EMAIL` | `forms@yourdomain.com` |
| `MAIL_FROM_NAME` | `Website form` |
| `MAIL_TO` | `you@yourdomain.com` |

Non-empty **env vars override** values from `smtp.config.php` when both exist.

### Option C — Hybrid

Put non-secrets in `smtp.config.php` and set **`SMTP_PASSWORD`** (and optionally `SMTP_USER`, `MAIL_TO`) only via env.

---

## 6. DNS / deliverability (same domain as From)

In **NodeWorx / DNS** for the domain:

- **SPF** should authorize the host that sends mail (your InterWorx server / PMG path — match what you already use for normal mail).
- Enable **DKIM** for the domain if the panel offers it.

This reduces spam-folder placement for form mail.

### Hybrid mail domains (mailbox on crservers, real mail hosted elsewhere)

Some domains have their **real** mailboxes on an external provider (Microsoft 365, Google Workspace, etc. — check the domain's `MX` record) while the `forms@` sending mailbox lives on the InterWorx account purely to send form mail via SMTP. In that case the domain's existing SPF record typically authorizes **only** the external provider, and iwx-originated mail will fail SPF until you add the InterWorx node's own SPF mechanism alongside it:

```text
# Before (example: mail hosted on Microsoft 365 only)
v=spf1 include:spf.protection.outlook.com -all

# After (preserves the existing provider, adds the sending node)
v=spf1 include:spf.protection.outlook.com include:_spf.crservers.com -all
```

`_spf.crservers.com` authorizes crservers' shared sending IPs; swap in the equivalent record if the form is hosted on a different provider's node. Always **send the exact before/after diff to the client for approval before applying** — this is a DNS change on a domain you don't own the mailflow for. Keep the existing `-all` (hard fail) and don't drop the client's current include.

Check DMARC alignment too (`_dmarc.DOMAIN` TXT record): if `adkim=s`/`aspf=s` (strict alignment) and DKIM is already correctly signing with `d=DOMAIN` from the InterWorx side, mail can pass DMARC via DKIM alignment alone even before the SPF record is updated — the SPF addition is still worth doing since some spam filters penalize a hard SPF fail independently of DMARC.

### Confirm mail actually reaches the destination (not just "accepted")

If the domain is a hybrid setup like above, a `250` response from your own SMTP submission only means the **local** mail server accepted the message for delivery — it does **not** prove the message reached the external mailbox. Before declaring the integration done, check the sending server's mail log for the actual remote-delivery outcome, e.g. on InterWorx/qmail:

```bash
grep -i 'to remote info@DOMAIN' /var/log/send/current | tail -5
# Look for a subsequent "delivery N: success: ..." line naming the destination's
# mail server (e.g. an outlook.com / google.com hostname), not just the initial
# "starting delivery" line.
```

If the domain instead has **no** external MX (mail fully hosted on the same InterWorx account) and the destination mailbox doesn't exist there, mail can bounce locally without ever leaving the server — confirm the destination mailbox exists, or that the domain is correctly configured for local delivery, before relying on `mail_to`.

---

## 7. Smoke test

From your laptop (replace URL and use a real test body):

```bash
curl -sS -X POST 'https://yourdomain.com/contact.php' \
  -H 'X-Requested-With: XMLHttpRequest' \
  -H 'Accept: application/json' \
  -F 'email=test@example.com' \
  -F 'message=SMTP test from curl' \
  -F 'name=CLI'
```

Expect JSON: `{"ok":true,"error":""}`.  
Check the **`MAIL_TO`** inbox (and spam).

If **`require_reply_email`** is true (default), a valid **`email`** field (or `reply_to_field` in config) is required.

---

## 8. Front-end

The site form must **POST** to **`/contact.php`** with a real **`email`** (and honeypots left empty).  
See **`OPERATOR.txt`** for JSON vs form, honeypots, and optional Turnstile.

**Generating forms in v0:** paste the prompt from **`V0-FORM-PROMPT.md`** (or the copy in the customer repo’s `utils/contact-form/`) so the model matches headers, honeypot, and optional Turnstile.

Copy **`contact.php`** (and Composer files) into the app’s **`public/`** before build so the static export and FTP deploy include them in **`out/`**.

---

## 9. Spam hardening (recommended)

Do **not** ship a public form with only a honeypot — bots will find it.

| Layer | What to do |
|-------|------------|
| **Turnstile** | Create a widget in Cloudflare Dashboard → Turnstile. Put **`site key`** in the front-end (e.g. `NEXT_PUBLIC_TURNSTILE_SITE_KEY`). Set **`TURNSTILE_SECRET`** (env) or **`turnstile_secret`** in `~/private/smtp.config.php`. Every successful POST must include field **`cf-turnstile-response`**. |
| **Honeypot** | Keep hidden trap fields (e.g. `company`) **empty** in real submissions. |
| **CDN / WAF** | If using Cloudflare, add managed / rate rules for **`POST /contact.php`** when possible. |
| **Watch mail** | If spam increases, enable Turnstile first, then tune hosting rules. |

**v0:** use the copy-paste prompt **`utils/contact-form/V0-FORM-PROMPT.md`** so generated React forms POST correctly to `/contact.php`.

### Client has no Cloudflare account yet

**Preferred: have the client create their own free Cloudflare account**, then invite the agency operator as a member (Account → Members → Invite) to create/configure the Turnstile widget on their behalf. This is no slower than creating a widget directly, keeps the widget under the client's own account from day one, and avoids any key rotation later. Turnstile doesn't require the protected domain's DNS/nameservers to be on Cloudflare at all — it's a standalone client-side widget plus a server-side API call, so this has no impact on the domain's existing DNS/hosting.

**Only as a time-boxed stopgap** if the client genuinely cannot create an account yet: Cloudflare's Self-Serve Subscription Agreement (§2.2.1(a)) prohibits signing up for its services "on behalf of a third party" without Cloudflare's express written permission — that's what the formal Agency/Partner Program exists for. Hosting a client's widget under the agency's own regular account is therefore **not a ToS-clean standing pattern**; only do it short-term, with the client's awareness, and migrate off it promptly:

- Confirm with the client that this is temporary before doing it.
- Note in your handoff that the widget is agency-owned so it's easy to find and retire later.
- Migrate to the client's own account **as soon as they have one**: recreate the widget there and swap **both** keys (site key in the front-end, secret in `smtp.config.php`/env) — no code changes needed, just key rotation.
- If this keeps recurring across clients, that's a signal to push for client-owned accounts up front, or to formally enroll in Cloudflare's Agency Partner Program rather than relying on ad hoc agency accounts.

### Verifying reject-on-missing/invalid-token without a live widget

Cloudflare publishes fixed [testing sitekey/secret pairs](https://developers.cloudflare.com/turnstile/troubleshooting/testing/) that work without any account or real widget, useful for confirming the endpoint's captcha behavior before the real widget is wired up front-end:

| Purpose | Secret key |
|---------|------------|
| Always fails verification | `2x0000000000000000000000000000AA` |
| Always passes verification | `1x0000000000000000000000000000AA` (only works with a token actually generated by the matching test sitekey in a real browser — an arbitrary string won't pass) |

With a non-empty `turnstile_secret` configured (even a test one), confirm both rejection paths, then **revert to `''` until the real widget is live** so real visitors without a token aren't blocked:

```bash
# Missing token -> expect 400 "Captcha verification missing."
curl -sS -X POST 'https://yourdomain.com/contact.php' \
  -H 'X-Requested-With: XMLHttpRequest' -H 'Accept: application/json' \
  -F 'email=test@example.com' -F 'message=no token' -F 'name=Test'

# Invalid token against the always-fail secret -> expect 400 "Captcha verification failed."
curl -sS -X POST 'https://yourdomain.com/contact.php' \
  -H 'X-Requested-With: XMLHttpRequest' -H 'Accept: application/json' \
  -F 'email=test@example.com' -F 'message=invalid token' -F 'name=Test' \
  -F 'cf-turnstile-response=garbage-token'
```

---

## Checklist

- [ ] Mailbox created; SMTP host/port/TLS known  
- [ ] `contact.php` + `composer.json` + `composer.lock` in web root  
- [ ] `composer install --no-dev` → `vendor/` exists  
- [ ] `~/private/smtp.config.php` **or** env vars with SMTP + MAIL_TO  
- [ ] `chmod 600` on private config  
- [ ] curl test returns `ok: true`  
- [ ] Test message received  
- [ ] (Recommended) Turnstile site key + server secret if the form is public  
