# Easiest path — contact forms on crservers (InterWorx)

Pick **one** path depending on how your site was built.

---

## Path A — Edenia / crservers already copied files to your hosting (pre-provisioned)

You should have **`contact.php`**, **`composer.json`**, **`composer.lock`**, **`install-on-server.sh`**, and **`smtp.config.example.php`** in your **`public_html`** (or the folder where your `index.html` lives).

1. **SSH** (or SiteWorx terminal) into the account.
2. Run:
   ```bash
   cd ~/public_html
   bash install-on-server.sh
   ```
3. **Edit one file** with your text editor — the script prints the path (usually **`~/private/smtp.config.php`** from `~/DOMAIN/html`, or **`../private/smtp.config.php`** from `~/public_html`) — and set at least:
   - `smtp_pass` → mailbox password  
   - `mail_to` → where you want form mail to arrive  
   - `smtp_host` / `smtp_user` / `mail_from_email` if they are not already correct for your domain.

That’s it. Open your website form and send a test.

**Optional:** If Edenia set **environment variables** for SMTP instead, you may only need step 2 (Composer still required for `vendor/`).

---

## Path B — Your site comes from GitHub (Next.js static export)

Each production deploy (FTP) should already place **`contact.php`**, **`composer.json`**, **`composer.lock`**, **`smtp.config.example.php`**, **`install-on-server.sh`**, and **`USERS-EASY-START.md`** in **`public_html`** (they are copied from `utils/contact-form/` into `public/` at build time, then exported to `out/`).

1. **SSH** into the account → `cd ~/public_html`
2. Run: `bash install-on-server.sh`
3. Edit the **`smtp.config.php`** path printed by the script (same as path A).

If an older deploy is missing those files, copy them from your repo’s **`utils/contact-form/`** (or from the [canonical bundle](https://github.com/edenia/crservers-deploy/tree/main/static-site-contact)) into `public_html`, then run step 2.

---

## Need more detail?

- Full checklist: **`SETUP.md`**
- Spam / Turnstile / v0 prompts: **`OPERATOR.txt`**, **`V0-FORM-PROMPT.md`**

**Canonical pre-copy bundle (for hosts):**  
[edenia/crservers-deploy — `static-site-contact/`](https://github.com/edenia/crservers-deploy/tree/main/static-site-contact)
