# CR Servers Deploy

> Formerly **CR Servers Static Deploy** in the repo `edenia/crservers-static-deploy` (renamed 2026-10-25: it now deploys PHP apps too). GitHub redirects the old repo name, and `v1` still points at v1.4.0 with the old workflow file `deploy-static-site.yml`, so existing `@v1` callers keep working. New setups use `edenia/crservers-deploy/.github/workflows/deploy.yml@v2`; see [Upgrading from v1](#upgrading-from-v1). The deploy marker keeps `tool: "crservers-static-deploy"` (AI Connect matches it).

**CR Servers Deploy** publishes a website kept in GitHub to CR Servers shared hosting. It is also **the preferred way to deploy server code (PHP apps)** to CR Servers: see [Backend code (PHP)](#backend-code-php). A reusable GitHub Actions workflow builds a static export (for example Next.js `output: "export"`) and uploads it over **FTPS** with [SamKirkland/FTP-Deploy-Action](https://github.com/SamKirkland/FTP-Deploy-Action). The repo also holds the **contact form bundle** (`static-site-contact/`) for static sites that need to send mail.

Maintained by **Edenia** for CR Servers hosting. Customer repos stay thin: they call this workflow and supply the FTP secrets.

**Which tool for which site:**

| | CR Servers Deploy | CR Servers AI Connect |
|---|---|---|
| For | Developers whose site lives in a GitHub repo | Clients who update their site by asking ChatGPT or Claude |
| How changes arrive | A push to the repo builds and uploads the site | The assistant drafts changes, shows a preview, publishes on confirmation |
| Undo | Revert the commit and deploy again | One sentence: undo any of the last 5 publishes |
| Server code (PHP, `.htaccess`) | Allowed (trusted repo maintainers); `backend: true` adds strict checks | Refused |
| Before upload | Blocks server-only files (config with passwords, `.env`, keys, dumps, backups), scans for secrets, checks PHP syntax and Composer advisories | Refuses server code; never shows files that may hold passwords |

Use **one of them per site** (see [CR Servers Deploy and AI Connect on the same site](#cr-servers-deploy-and-ai-connect-on-the-same-site)). Client docs: [crservers.com/support](https://crservers.com/support).

Customer repos should set **`packageManager`** in `package.json` (for example `"packageManager": "pnpm@9.15.9"`). `pnpm/action-setup` reads that field and no separate pnpm version is passed from the workflow (avoids mismatch with a pinned major in CI).

## Usage (customer repository)

Add a workflow that references this repo (pin a **tag** such as `@v2` in production instead of `@main`):

```yaml
name: Deploy static site

on:
  push:
    branches: [main]

permissions:
  contents: read
  actions: write

jobs:
  deploy-site:
    uses: edenia/crservers-deploy/.github/workflows/deploy.yml@v2
    secrets:
      FTP_HOST: ${{ secrets.FTP_HOST }}
      FTP_USER: ${{ secrets.FTP_USER }}
      FTP_PASSWORD: ${{ secrets.FTP_PASSWORD }}
      FTP_REMOTE_PATH: ${{ secrets.FTP_REMOTE_PATH }}
    with:
      site_url: ${{ vars.SITE_URL }}
```

Configure **Settings → Secrets and variables → Actions**:

- **Secrets** (required): `FTP_HOST`, `FTP_USER`, `FTP_PASSWORD`, `FTP_REMOTE_PATH`. Use a **separate FTP account just for deploys**, jailed to the site folder (SiteWorx → FTP Accounts → add, with that folder as its home), not the account's main FTP login. Then `FTP_REMOTE_PATH` is `/`, and a leaked GitHub secret can only touch that folder.
- **Variables** (optional): `SITE_URL` — public URL such as `https://dev.example.com/` (not sensitive; shown in the deploy job summary)

Because this reusable workflow lives in **another** repository, the caller **cannot** use `secrets: inherit`. Map each secret under `secrets:` as shown above (same names on both sides).

### Required repository secrets

| Secret | Description |
|--------|-------------|
| `FTP_HOST` | crservers FTP/FTPS hostname — see [FTPS hostname and certificate](#ftps-hostname-and-certificate) below before assuming this is `ftp.customerdomain.com` |
| `FTP_USER` | FTP username |
| `FTP_PASSWORD` | FTP password |
| `FTP_REMOTE_PATH` | Remote directory **relative to the FTP account's jail root** — **must end with `/`**, and must **not** start with `./` (see [InterWorx paths](#interworx--crservers-ftp-paths) below; e.g. `example.com/html/`, or `/` if the FTP account is already scoped directly to the deploy folder) |

### FTPS hostname and certificate

On shared InterWorx nodes, **ProFTPd serves a single TLS certificate for the whole node** (CN matching the node's own hostname, e.g. `nodeXX.crservers.com`), not a per-domain certificate. If `FTP_HOST` is set to the customer's domain (`ftp.customerdomain.com`) or a `mail.` subdomain, FTPS certificate verification can fail or the TLS handshake can behave unpredictably depending on SNI support, even though plain FTP or an FTPS client with relaxed verification would connect fine.

**Use the node's own hostname as `FTP_HOST`** (e.g. `iwx41.crservers.com`) unless you've confirmed the customer's domain is included as a SAN on that node's certificate. Confirm with:

```bash
echo | openssl s_client -connect NODE_HOSTNAME:21 -starttls ftp -servername NODE_HOSTNAME 2>/dev/null \
  | openssl x509 -noout -subject -ext subjectAltName
```

If the customer's FTP account is jailed correctly, this has no effect on where files land — `FTP_REMOTE_PATH` (relative to the jail root) still controls that independently of which hostname you connect to.

### Optional repository variable

| Variable | Description |
|----------|-------------|
| `SITE_URL` | Pass as `site_url` input (`vars.SITE_URL` in the caller). Used only for the workflow summary link text — **FTP deploy does not require it**. |

### Manual runs (dry run / clean deploy)

Add `workflow_dispatch` and forward booleans using string comparisons (`github.event.inputs` values are strings):

```yaml
on:
  workflow_dispatch:
    inputs:
      dry_run:
        type: boolean
        default: false
      clean_deploy:
        type: boolean
        default: false

jobs:
  deploy-site:
    uses: edenia/crservers-deploy/.github/workflows/deploy.yml@v2
    secrets:
      FTP_HOST: ${{ secrets.FTP_HOST }}
      FTP_USER: ${{ secrets.FTP_USER }}
      FTP_PASSWORD: ${{ secrets.FTP_PASSWORD }}
      FTP_REMOTE_PATH: ${{ secrets.FTP_REMOTE_PATH }}
    with:
      dry_run: ${{ github.event.inputs.dry_run == 'true' }}
      clean_deploy: ${{ github.event.inputs.clean_deploy == 'true' }}
      site_url: ${{ vars.SITE_URL }}
```

On `push`, those comparisons are false because the inputs are absent.

### Verbose logging for a real deploy

`dry_run: true` always logs verbosely, but that skips the actual upload. To get a full FTP command/response transcript on a **real** deploy (e.g. to correlate a failure against server-side FTP/TLS logs), set `ftp_log_level: verbose` and leave `dry_run` at its default (`false`):

```yaml
    with:
      ftp_log_level: verbose
      site_url: ${{ vars.SITE_URL }}
```

Available starting with the `ftp_log_level` input (not present in workflow revisions before it was added — pin a tag that includes it). Revert to the default (or omit the input) once you have the log you need, since verbose logging prints the full FTP transcript on every run.

### Callable workflow inputs (defaults)

| Input | Default | Notes |
|-------|---------|--------|
| `node_version` | `22` | Node used for `pnpm install` / `pnpm build` on the runner |
| `package_manager` | `pnpm` | `pnpm`, `yarn` or `npm`: dependency cache, and pnpm setup for `pnpm`. Set the commands to match, e.g. `yarn install --immutable` / `yarn build` (v1.6.0+) |
| `install_command` | `pnpm install --frozen-lockfile` | Trusted maintainer input |
| `build_command` | `pnpm build` | Trusted maintainer input |
| `verify_command` | `pnpm run verify:static-out` | Skipped if `skip_verify: true` |
| `skip_verify` | `false` | |
| `artifact_name` | `static-out` | |
| `artifact_path` | `out/` | |
| `artifact_retention_days` | `7` | |
| `ftp_protocol` | `ftps` | |
| `ftp_local_dir` | `./out/` | Must end with `/` |
| `ftp_timeout_ms` | `1200000` | |
| `ftp_log_level` | `standard` | FTP-Deploy-Action log verbosity for real deploys - `minimal`\|`standard`\|`verbose`. Set to `verbose` to get the full FTP command/response transcript for a real (non-dry-run) deploy, e.g. to correlate against server-side FTP logs. `dry_run: true` always forces `verbose` regardless of this input. |
| `dry_run` | `false` | FTP no-op |
| `clean_deploy` | `false` | Wipes remote `FTP_REMOTE_PATH` |
| `site_url` | *(empty)* | Pass `vars.SITE_URL` from caller for summary |
| `backend` | `false` | Strict mode for server code: secret-scan findings and Composer advisories fail the deploy; `clean_deploy` is refused. See [Backend code (PHP)](#backend-code-php) |
| `environment` | *(empty)* | GitHub environment for the deploy job (`production`, `staging`): required reviewers, branch rules, environment secrets |
| `protected_paths` | *(empty)* | One glob per line, relative to `FTP_REMOTE_PATH`, never uploaded or deleted (e.g. `uploads/**`). `private/**` and `.env` files are always protected |
| `allow_files` | *(empty)* | Exact paths (relative to `artifact_path`) the server-only file check accepts |
| `ftp_security` | `strict` | `strict` verifies the FTPS certificate; `loose` skips it (warning) |

## New site checklist (customer repo)

Use this when onboarding a new static or Next.js customer repository.

1. **Next.js static export** — in `next.config` (or `next.config.mjs`):
   - `output: 'export'`
   - `images: { unoptimized: true }` if the app uses `next/image`
2. **`package.json`** — `packageManager` (matches `pnpm-lock.yaml`), `verify:static-out` (e.g. `test -f out/index.html`)
3. **`public/.htaccess`** — Apache rules for shared hosting (see [below](#recommended-publichtaccess-next-static-export))
4. **Caller workflow** — `.github/workflows/deploy.yml` calling `edenia/crservers-deploy/.../deploy.yml@v2` with FTP secrets mapped explicitly
5. **GitHub Actions** — secrets `FTP_*`; optional variable `SITE_URL` (public URL for deploy summaries only)
6. **First deploy** — run workflow with **dry_run** once, then production; confirm the live site (not only a green Actions run)
7. **Optional contact form** — copy **`static-site-contact/`** into `public/` (or pre-provision on the server), configure SMTP per **`USERS-EASY-START.md`**

## InterWorx / crservers FTP paths

On **InterWorx** shared hosting, the FTP user is usually **chrooted to the account home** (e.g. `/home/ACCOUNT/`). [FTP-Deploy-Action](https://github.com/SamKirkland/FTP-Deploy-Action) treats `FTP_REMOTE_PATH` as **relative to that FTP root**, not as an absolute path on the server.

### Use a relative path (required)

| `FTP_REMOTE_PATH` value | Result |
|-------------------------|--------|
| `example.com/html/` | Correct — files land in `/home/ACCOUNT/example.com/html/` (shared FTP account jailed to the account home) |
| `/` | Correct **only** if the FTP account itself is already jailed directly to the deploy folder (e.g. a dedicated restricted FTP account created for CI, chrooted straight to `.../html/dev/`) — there is nothing left to descend into, so `/` is the whole answer |
| `./` | **Do not use** — looks equivalent to `/` but is not: FTP-Deploy-Action's underlying client walks the path segment by segment and tries to `MKD` a literal `.` directory, which InterWorx/ProFTPd correctly rejects with `550` since `.` already exists. The workflow auto-normalizes `./` → `/` and emits an `::warning::` annotation on the run, but fix the secret directly to remove the warning |
| `/home/ACCOUNT/example.com/html/` | Wrong — uploads often go outside the tree you see over SSH; Actions may still succeed |
| `/home/ACCOUNT/html/` | Wrong for the primary domain — often the account default “Test Page”, not the domain vhost |

**Rule:** Set `FTP_REMOTE_PATH` to the domain’s web root **relative to the FTP account's own jail root**, with a trailing slash and no leading `./`. Confirm in **SiteWorx** (domain → home / document root) or on the server:

```bash
# SSH (paths on disk)
ls /home/ACCOUNT/DOMAIN/html/

# After a successful deploy you should see at least:
#   index.html  _next/  .htaccess
```

### Typical layout (primary domain)

```text
/home/ACCOUNT/                 ← FTP login root
├── html/                      ← account default page (crservers “Test Page”) — usually NOT the live domain
└── DOMAIN/                    ← e.g. example.com/
    ├── html/                  ← document root for https://DOMAIN/  ← deploy here
    └── iworx-backup/
```

Some accounts use `domains/DOMAIN/html/` instead of `DOMAIN/html/`. Always take the path from SiteWorx or `ls` on the server, then express it **relative to `/home/ACCOUNT/`** in the secret.

### Troubleshooting

| Symptom | Likely cause |
|---------|----------------|
| Actions deploy succeeds; live URL still shows crservers “Test Page” | Wrong `FTP_REMOTE_PATH` (wrong folder or absolute path) |
| SSH into `…/DOMAIN/html/` shows only placeholder files (`crservers-logo.*`, old `index.html`) | Deploy never hit that directory — fix path and redeploy |
| `find /home/ACCOUNT -name '_next' -type d` finds `_next` under `html/` or a nested `home/…` path | Stray upload from an absolute path — safe to delete after fixing the secret |
| Deploy fails with `read ECONNRESET (data socket)` right after the first “creating folder” log line, even though FTPS/TLS login clearly succeeds | `FTP_REMOTE_PATH` is set to `./` instead of `/`. Server-side logs show a clean TLS login followed by `MKD .../. ` → `550` — the action tries to create a literal `.` directory, which InterWorx/ProFTPd rejects. Not a firewall/TLS/passive-port issue. The workflow now auto-normalizes this (check the run's `::warning::` annotations) — update the secret to `/` to remove the warning |
| `ERR_TLS_CERT_ALTNAME_INVALID`, or the action says "are you sure your server works via FTP or FTPS? … SFTP" | `FTP_HOST` is your domain or an IP, so the FTPS certificate (issued to the server hostname) doesn't match. Set it to the server hostname, e.g. `iwx41.crservers.com`. Ignore the SFTP hint: CR Servers uses FTPS. The run ends with an `::error::` saying so |
| First deploy to a folder fails with `read ECONNRESET (data socket)` right after "No file exists on the server … first publish" (before v2.0.2) | The action's download of the missing sync-state file fails (550) and breaks its FTPS session on iwx41. Since v2.0.2 the "Prepare sync state" step creates the state file first (own connection), so the action never hits that path |
| A deploy shows "The FTP upload failed; retrying once" (e.g. `ERR_SSL_TLSV1_ALERT_DECODE_ERROR` on the data socket) and then succeeds | A single TLS data connection failed during a large upload (seen once in ~1000 files on iwx41). The workflow retries the upload once; the retry re-sends every file changed since the last successful deploy, because FTP-Deploy-Action saves its sync state only at the end. If both attempts fail, run the job again |
| `ECONNRESET (data socket)` persists with `FTP_REMOTE_PATH` already correct (`/`, no leading `./`), and `ftp_log_level: verbose` shows no FTP command/response transcript at all | `log-level: verbose` only prints FTP-Deploy-Action's own sync-decision logging (“creating folder X”, “uploading file Y”) — it does **not** expose the underlying `basic-ftp` library's raw protocol trace. See [FTP protocol diagnostics](#ftp-protocol-diagnostics) below for a standalone workflow that does |

**Verify the correct folder:** after deploy, `index.html` in the domain `html/` should be small (static export) and include `_next/`. Check the public URL `Last-Modified` or page title changes.

**Verify the public site:** `curl -sI https://DOMAIN/ | grep -i last-modified` and confirm content matches the app (not the default hosting page).

### FTP protocol diagnostics

FTP-Deploy-Action's `log-level: verbose` is scoped to the `@samkirkland/ftp-deploy` package's own sync logic — it never surfaces the raw FTP command/response exchange (confirmed against upstream: [SamKirkland/FTP-Deploy-Action#529](https://github.com/SamKirkland/FTP-Deploy-Action/issues/529)). When a failure needs correlating against server-side FTP/TLS logs (e.g. an `ECONNRESET` whose cause isn't one of the known ones above), use a standalone diagnostic workflow that talks to `basic-ftp` (the library the action wraps) directly, with its own protocol tracing enabled:

```yaml
name: 🔍 FTPS diagnostic
on: workflow_dispatch

jobs:
  ftp-diagnostic:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        variant: [exact-repro, latest-v6]
    steps:
      - uses: actions/setup-node@v7
        with:
          node-version: 24

      - name: Create isolated dependency directory
        run: |
          DIAG_DIR="$(mktemp -d)"
          echo "DIAG_DIR=$DIAG_DIR" >> "$GITHUB_ENV"
          cd "$DIAG_DIR" && npm init -y >/dev/null

      - name: Install exact basic-ftp bundled by FTP-Deploy-Action@v4.4.0
        if: matrix.variant == 'exact-repro'
        working-directory: ${{ env.DIAG_DIR }}
        run: |
          # Verified directly from FTP-Deploy-Action@v4.4.0's own package-lock.json -
          # this is the exact version bundled into that release's dist/index.js.
          # If you're pinned to a different FTP-Deploy-Action tag, re-check its
          # package-lock.json for the "node_modules/basic-ftp" entry before reusing this.
          npm install basic-ftp@5.0.5 --no-save
          echo "BASIC_FTP_VERSION=5.0.5" >> "$GITHUB_ENV"

      - name: Install latest basic-ftp v6 for comparison
        if: matrix.variant == 'latest-v6'
        working-directory: ${{ env.DIAG_DIR }}
        run: |
          npm install basic-ftp@6 --no-save
          echo "BASIC_FTP_VERSION=$(node -p "require('basic-ftp/package.json').version")" >> "$GITHUB_ENV"

      - name: Run raw FTPS trace (${{ matrix.variant }}, basic-ftp@${{ env.BASIC_FTP_VERSION }})
        working-directory: ${{ env.DIAG_DIR }}
        env:
          FTP_HOST: ${{ secrets.FTP_HOST }}
          FTP_USER: ${{ secrets.FTP_USER }}
          FTP_PASSWORD: ${{ secrets.FTP_PASSWORD }}
          FTP_REMOTE_PATH: ${{ secrets.FTP_REMOTE_PATH }}
          RUN_TAG: diag-${{ github.run_id }}-${{ github.run_attempt }}-${{ matrix.variant }}
        run: |
          echo "[diag] variant=${{ matrix.variant }} basic-ftp=$BASIC_FTP_VERSION"
          cat <<'EOF' > ftp-diag.mjs
          import { Client } from "basic-ftp";
          import { Readable } from "stream";

          const client = new Client(30000);
          client.ftp.verbose = true; // raw protocol trace; PASS is auto-redacted by basic-ftp

          const testDir = process.env.RUN_TAG; // unique per run/matrix leg, safe to create+remove
          const testFile = "diag-test.txt";

          try {
            console.log(`[diag] connecting to ${process.env.FTP_HOST} (ftps, cert verification ON)`);
            await client.access({
              host: process.env.FTP_HOST,
              user: process.env.FTP_USER,
              password: process.env.FTP_PASSWORD,
              secure: true,
              secureOptions: {
                rejectUnauthorized: true,
                servername: process.env.FTP_HOST,
              },
            });

            const remoteDir = (process.env.FTP_REMOTE_PATH || "/").replace(/\/$/, "") || "/";
            console.log(`[diag] cd ${remoteDir}`);
            await client.cd(remoteDir);

            console.log(`[diag] ensureDir ${testDir}`);
            await client.ensureDir(testDir);

            console.log("[diag] uploading a small test file into it");
            const body = Readable.from([`diagnostic upload ${new Date().toISOString()}\n`]);
            await client.uploadFrom(body, testFile);

            console.log("[diag] SUCCESS - cleaning up this run's test folder only");
            await client.cd("..");
            await client.removeDir(testDir);
          } catch (err) {
            console.error("[diag] FAILED:", err);
            process.exitCode = 1;
          } finally {
            client.close();
          }
          EOF
          node ftp-diag.mjs
```

Notes:

- **Isolated dependency directory** (`mktemp -d` + fresh `npm init`) so this never touches the caller repo's own `package.json`/`node_modules`.
- **Unique remote test folder per run and matrix leg** (`diag-<run_id>-<attempt>-<variant>`) so concurrent runs/legs can't interfere with each other's upload or cleanup, and cleanup only ever removes the exact folder+file this run created.
- **`basic-ftp`'s built-in verbose trace redacts `PASS`** (`> PASS ###`) automatically — no extra redaction needed beyond GitHub's own secret masking.
- **FTPS and full certificate verification are preserved** (`secure: true`, `rejectUnauthorized: true`, explicit `servername`) — this diagnostic does not relax security to get a trace.
- To find the exact `basic-ftp` version bundled by a *different* pinned `FTP-Deploy-Action` tag, don't rely on resolving `@samkirkland/ftp-deploy`'s semver range today (a newer patch may have been published since that tag was built). Instead check the actual pinned entry:
  ```bash
  curl -sS "https://raw.githubusercontent.com/SamKirkland/FTP-Deploy-Action/<TAG>/package-lock.json" \
    | grep -A2 '"node_modules/basic-ftp"'
  ```

## Publishing (Edenia)

Canonical remote:

`git@github.com:edenia/crservers-deploy.git`

### Repo already exists on GitHub (empty or with a README)

From your local clone of this directory:

```bash
cd crservers-deploy
git remote add origin git@github.com:edenia/crservers-deploy.git   # skip if origin already set
git branch -M main
git add -A && git status
git commit -am "CR Servers Deploy reusable workflow"   # if you have local changes
git push -u origin main
git tag v2 && git push origin v2
```

If GitHub created a first commit (for example a default `README.md`) and `git push` is rejected, run `git fetch origin` and either merge with `git pull origin main --allow-unrelated-histories` and resolve conflicts, or coordinate with your team before any force push.

### Create the repo from scratch with GitHub CLI

```bash
cd crservers-deploy
git init
git add .
git commit -m "CR Servers Deploy reusable workflow"
gh repo create edenia/crservers-deploy --public --source=. --remote=origin --push
git tag v2 && git push origin v2
```

Use a **public** repo if customer sites live in other GitHub orgs or accounts; otherwise callers cannot resolve `uses: edenia/crservers-deploy/...` unless you rely on Enterprise or org access you already control.

## What runs where

- **GitHub Actions:** Node runs only on the **runner** to install dependencies, run `next build`, and upload `out/` over FTP. Official actions are pinned to **v5+** / **FTP-Deploy v4.4+** so they use the **Node 24** action runtime (avoids the Node 20 deprecation on GitHub-hosted runners).
- **Safety checks** run on the runner before the upload: see [What `backend: true` adds](#what-backend-true-adds) (they apply to every deploy).
- **crservers (production):** Only the **static files** under your `FTP_REMOTE_PATH` are needed — typically **Apache** serves `index.html`, assets, and `.htaccess`. **You do not need Node.js on the hosting account** for this setup.

### Contact forms (SMTP mail for static sites)

Static exports cannot send mail from the browser alone. For **contact / inquiry forms**, crservers hosts a small **PHP + PHPMailer** endpoint that authenticates to an **InterWorx mailbox** over SMTP.

| Piece | Location |
|-------|----------|
| Canonical bundle | **`static-site-contact/`** in this repo |
| Edenia ops (rsync / pre-provision) | **`static-site-contact/README-EDENIA-OPS.md`** |
| Customer setup | **`static-site-contact/USERS-EASY-START.md`** → `install-on-server.sh`, then **`../private/smtp.config.php`** (or env vars) |
| Front-end contract / v0 prompt | **`static-site-contact/V0-FORM-PROMPT.md`**, **`OPERATOR.txt`** |

**Deploy with the static site:** copy `contact.php`, `composer.json`, and `composer.lock` into the app’s **`public/`** so `pnpm build` places them in **`out/`** and the [FTP workflow](#usage-customer-repository) uploads them to the domain `html/` (see [InterWorx paths](#interworx--crservers-ftp-paths)). On the server, run **`composer install --no-dev`** once in that directory (or use **`install-on-server.sh`** after Edenia pre-copies the bundle).

**Secrets:** never commit SMTP passwords. Use **`~/private/smtp.config.php`** and/or hosting env vars (`SMTP_HOST`, `SMTP_USER`, `SMTP_PASSWORD`, `MAIL_TO`, optional `TURNSTILE_SECRET`). Optional **Cloudflare Turnstile** for public forms.

Customer repos may mirror the bundle under **`utils/contact-form/`**; treat **`static-site-contact/`** here as the source of truth (`CANONICAL-SOURCE.txt`).

### Recommended `public/.htaccess` (Next static export)

Commit this next to your app as **`public/.htaccess`** so it is copied into **`out/.htaccess`** on build. Directives are wrapped in **`IfModule`** so missing modules do not break the site.

```apache
# Static Next export on Apache (crservers / shared hosting)
DirectoryIndex index.html
Options -Indexes

# Compression when the host has mod_deflate (no-op if missing)
<IfModule mod_deflate.c>
  AddOutputFilterByType DEFLATE text/html text/plain text/xml
  AddOutputFilterByType DEFLATE text/css application/javascript application/json
  AddOutputFilterByType DEFLATE image/svg+xml
</IfModule>

# Long cache for Next.js fingerprinted assets under /_next/static/
<IfModule mod_headers.c>
  <LocationMatch "^/_next/static/">
    Header set Cache-Control "public, max-age=31536000, immutable"
  </LocationMatch>
</IfModule>

# Expires for common image/font types (complements Cache-Control above)
<IfModule mod_expires.c>
  ExpiresActive On
  ExpiresByType image/avif "access plus 30 days"
  ExpiresByType image/webp "access plus 30 days"
  ExpiresByType image/jpeg "access plus 30 days"
  ExpiresByType image/png "access plus 30 days"
  ExpiresByType image/gif "access plus 30 days"
  ExpiresByType image/svg+xml "access plus 30 days"
  ExpiresByType font/woff2 "access plus 180 days"
  ExpiresByType font/woff "access plus 180 days"
</IfModule>
```

## Backend code (PHP)

CR Servers Deploy is the preferred way to put server code (a PHP app, an API) on CR Servers hosting. AI Connect stays static-only on purpose. Code lives in Git, every change can be reviewed, and the FTP password stays in GitHub.

### Caller workflow

```yaml
name: Deploy app

on:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read
  actions: write

jobs:
  deploy:
    uses: edenia/crservers-deploy/.github/workflows/deploy.yml@v2
    secrets:
      FTP_HOST: ${{ secrets.FTP_HOST }}
      FTP_USER: ${{ secrets.FTP_USER }}
      FTP_PASSWORD: ${{ secrets.FTP_PASSWORD }}
      FTP_REMOTE_PATH: ${{ secrets.FTP_REMOTE_PATH }}
    with:
      backend: true
      environment: production
      install_command: "composer install --no-dev --no-interaction --classmap-authoritative"
      build_command: "mkdir -p out && cp -R public/. out/ && cp -R vendor out/"
      skip_verify: true
      protected_paths: |
        uploads/**
        logs/**
```

Adapt `install_command` and `build_command` to the app: the point is that `out/` holds exactly what the server needs, with `vendor/` built in CI so the server runs the versions that were audited. If `vendor/` sits inside the web root, block it from the web with `RedirectMatch 404 ^/vendor/` in the app's `.htaccess`; PHP still reads it from disk.

### What `backend: true` adds

Every deploy, static or backend, runs these checks on the build output **before** it is stored as an artifact, so blocked files never leave the runner:

| Check | Static site | `backend: true` |
|---|---|---|
| Server-only files: `.env`, private keys, `.git` data, DB dumps, backup copies (`.bak`, `.old`, `~`), credential files, anything in `private/`, `secret(s)/`, `credentials/`, and config files (`wp-config.php`, `config.php`, `settings.php`, …) **with a password, key or token written in them** | Blocks | Blocks |
| Secret scan ([gitleaks](https://github.com/gitleaks/gitleaks) 8.30.1, checksum-verified) | Warns (built JS often carries public API keys); if gitleaks can't be downloaded, the deploy goes on with a warning | Blocks, also when gitleaks can't be downloaded |
| PHP syntax (`php -l`, outside `vendor/`) | Blocks | Blocks |
| Risky PHP calls (`eval`, `exec`, `shell_exec`, `system`, includes of request input, …) | Warns for review | Warns for review |
| Composer advisories (`composer audit` on each `composer.lock` in the repo or the upload) | Warns | Blocks |
| `clean_deploy` | Allowed | Refused (it would delete uploads and server-only config) |

Third-party code in `vendor/` and `node_modules/` is skipped by the file check and the secret scan (packages ship files like `cacert.pem` or test `.sql` files); the Composer audit covers it. Placeholder copies such as `config.example.php` or `.env.example` pass. If a finding is public by design, add its fingerprint to `.gitleaksignore` at the repo root (the annotation shows it); a repo with its own `.gitleaks.toml` replaces the built-in config, so extend the defaults and allowlist `vendor/` there; for a file the name check gets wrong, list it in `allow_files` and say why in the workflow.

### Set up the repository

1. **A deploy-only FTP account** jailed to the app folder (see [Required repository secrets](#required-repository-secrets)).
2. **Environments** (Settings → Environments): `production` with **required reviewers** and **Deployment branches: main only**; put the four FTP secrets there as environment secrets, not repository secrets, so a branch or a workflow without the environment can't read them. Optionally `staging`, whose `FTP_REMOTE_PATH` points at a test copy of the app, deployed first.
3. **Triggers:** `push` to `main` and `workflow_dispatch` only. Never `pull_request_target`, and never pass PR titles, branch names or other user input into `install_command` / `build_command`.
4. **Branch protection on `main`:** require a pull request review, so no code reaches the server unreviewed.
5. **Keep secrets on the server:** config with passwords goes in `~/private/` (outside the web root), or in environment variables, and the app reads it from there. The deploy never uploads `private/**` or `.env` files and never deletes them.
6. **Protect what the app writes:** list upload, log and cache folders in `protected_paths`, so a deploy never deletes them.

### On the server (once, with CR Servers support)

- Upload folders must not run PHP. In each upload folder's `.htaccess`:

  ```apache
  <FilesMatch "\.(php|phtml|phar|php\d)$">
    Require all denied
  </FilesMatch>
  Options -Indexes
  ```

- Database creation, migrations and install scripts (`install.php`) are not part of the deploy. Run them once by hand, or ask CR Servers support.

### What it doesn't do

- **No atomic switch:** FTP uploads file by file, so for a few seconds the app can be half old, half new. Deploys never cancel each other mid-upload (a newer run waits).
- **No database changes.** Make schema changes backward compatible, or put the app in maintenance mode while they run.
- **Undo** is `git revert` and deploy again.

## CR Servers Deploy and AI Connect on the same site

Both write to the same folder, so pick one per site. Each deploy uploads **`.htcrservers-deploy.json`** (repository, commit, ref, time; turn off with `deploy_marker: false`). Apache never serves `.ht*` files, so it stays private. When it's there, AI Connect tells the user that the site is published from GitHub and that changes made through the assistant will be replaced by the next deploy.


- **AI Connect protects files changed outside it.** After a CR Servers Deploy upload, AI Connect refuses to publish over, or undo, the files that changed (it reports a conflict instead of overwriting work it didn't make).
- **CR Servers Deploy overwrites whatever is in the repo**, including changes an assistant published, on the next push.

If a site moves from one to the other, say so in the repo README, and stop the deploy workflow (or remove AI Connect's access in the client area) for the tool you no longer use.

## Versioning

Customers pin the major tag **`v2`**. To release, tag the commit (`vX.Y.Z`) and move `v2` to it, after checking that existing inputs and secrets still work (no breaking changes within a major). Current: `v2` = `v2.0.2` (private sync state, created before the upload).

**`v1` stays at `v1.4.0`** (repo then named `crservers-static-deploy`, workflow `deploy-static-site.yml`) and won't move: v1.5.0–v1.6.0 changed defaults that can stop a deploy that worked on v1.4.0, so that work ships as **v2.0.0** instead (backend hardening, `package_manager`, hidden files such as `.htaccess` deployed again, the gitleaks download warning, and the new name).

### Upgrading from v1

1. Change the caller's `uses:` line to `edenia/crservers-deploy/.github/workflows/deploy.yml@v2`. Inputs and secrets are the same; the new inputs are optional.
2. Check the two defaults that can stop a deploy that worked on v1.4.0:
   - **FTPS certificate check is on** (`ftp_security: strict`). A caller with `FTP_HOST` set to its own domain (`ftp.example.com`) instead of the node hostname fails the TLS check. Fix: use the node hostname; or `ftp_security: loose` temporarily.
   - **The server-only file check blocks** `.env`, keys, dumps, backups, `private/` and config files with literal passwords in the build output. Those files were being published, so failing is intended; `allow_files` covers false positives.
3. Hidden files in the build output (`.htaccess`, `.well-known/`) are uploaded again.
4. If branch protection requires the deploy check by name, update it: the jobs are now "CR Servers Deploy — build" and "CR Servers Deploy — deploy (FTPS)".

## Security

- **FTPS only, certificate verified.** The default is `ftps` with `ftp_security: strict` (before v1.5.0 the certificate wasn't checked). `ftp` sends the password unencrypted, logs a warning, and will be refused in a future major version. Use the node hostname as `FTP_HOST` (see [FTPS hostname and certificate](#ftps-hostname-and-certificate)).
- **Private sync state.** FTP-Deploy-Action keeps a list of every deployed file with its hash on the server. Since v2.0.2 it's named `.htcrservers-deploy-state.json`, which Apache never serves; the first v2.0.2 deploy moves an existing public `.ftp-deploy-sync-state.json` to the new name (no full re-upload) and deletes it. Dry runs don't touch the server, so a dry run before that first real deploy shows a full upload.
- **Actions pinned by commit SHA** (Dependabot keeps them current), and gitleaks verified by SHA-256 before it runs.
- **Checks before upload:** server-only files, secret scan, PHP syntax, Composer advisories (see [Backend code (PHP)](#backend-code-php)).
- **Environments:** run the deploy job in a GitHub environment with required reviewers and environment-scoped FTP secrets (`environment` input).
- **A deploy-only FTP account** jailed to the site folder (see [Required repository secrets](#required-repository-secrets)).
- Do not pass untrusted user input into `install_command`, `build_command`, or `verify_command`.
- `clean_deploy` deletes the entire remote `FTP_REMOTE_PATH`; use only for intentional full resets.
- **Contact bundle files:** our nodes already answer 403 for `composer.json` / `composer.lock`. As defense in depth, add this to the site's `public/.htaccess` so the rest of the bundle (setup notes, install script, `vendor/`) is never served; `contact.php` reads `vendor/` from disk, so the form keeps working:

  ```apache
  <FilesMatch "^(composer\.(json|lock)|install-on-server\.sh|smtp\.config\.example\.php|USERS-EASY-START\.md|SETUP\.md|OPERATOR\.txt)$">
    Require all denied
  </FilesMatch>
  RedirectMatch 404 ^/vendor/
  ```

## License

MIT (see `LICENSE`).
