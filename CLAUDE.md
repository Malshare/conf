# MalShare Conf

Deployment and orchestration repository for MalShare server infrastructure.

## What This Repo Does

Manages production Docker Compose config and CI/CD deployment. When upstream repos (Frontend, Offline) push to `main`, they build Docker images, push to GHCR, then trigger this repo's deploy workflow via `repository_dispatch`.

## Deployment Flow

```
Upstream push (Frontend or Offline)
  → Build & push Docker image to ghcr.io/malshare/*
  → Trigger `upstream-image-built` dispatch event on this repo
  → deploy.yml: SCP src/* to server at /root/conf-src
  → SSH: docker login to GHCR with malshare-bot creds
  → SSH: docker compose up -d --pull always
```

## Key Files

- `src/docker-compose.yml` — Production service definitions (frontend, cloudflared tunnel, upload-handler, url-task-handler, generate-daily)
- `src/frontend.env` — Environment variables for the frontend container (NOT committed with real secrets)
- `.github/workflows/deploy.yml` — Deployment workflow triggered by push or upstream dispatch

## GitHub Secrets (org-level)

- `SERVER_HOST`, `SERVER_USER`, `SERVER_SSH_KEY` — SSH access to production server
- `GHCR_USER`, `GHCR_TOKEN` — malshare-bot credentials for pulling private GHCR images

## Server Layout

On the production server, `src/*` is copied to `/root/conf-src/`. The `frontend.env` file must exist there alongside `docker-compose.yml`.

## Shared Volumes

- `daily_exports` — Written by `generate-daily`, mounted read-only into `frontend` at `/var/www/html/daily/`. Serves browsable directory listings of daily hash exports at the `/daily/` URL path.

---

# MalShare Frontend

PHP web application — the main malshare.com site for sharing and searching malware samples.

## Tech Stack

- PHP 8.4 on Apache
- MySQL 8
- Wasabi S3-compatible storage for sample binaries
- Bootstrap CSS, jQuery, D3.js
- Mailgun for registration emails
- Google reCAPTCHA v2
- VirusTotal context widget

## Key Files

- `html/server_includes.php` — Core framework: DB connection, S3 integration, sample queries (~2000 lines)
- `html/server_registration.php` — User registration, email (Mailgun)
- `html/api.php` — REST API endpoints (getlist, getsources, dailysum, etc.)
- `html/sample.php` — Sample detail view
- `Dockerfile` — Production image (php:8.4-apache, installs mysqli + PEAR Mail)
- `docker/docker-compose.yaml` — Local dev environment (MySQL + Nginx proxy + PHP)
- `malshare_db.sql` — Database schema and stored procedures
- `.github/workflows/docker.yml` — Build, push to GHCR, trigger conf repo dispatch

## Environment Variables (read via `getenv()`)

### Database
`MALSHARE_DB_HOST`, `MALSHARE_DB_USER`, `MALSHARE_DB_PASS`, `MALSHARE_DB_DATABASE`, `MALSHARE_DB_PORT`, `MALSHARE_DB_CERT`

### Storage
`MALSHARE_SAMPLES_ROOT`, `MALSHARE_UPLOAD_SAMPLES_ROOT`
`WASABI_ENDPOINT`, `WASABI_REGION`, `WASABI_KEY`, `WASABI_SECRET`, `WASABI_BUCKET`

### Services
`MALSHARE_RECAPTCHA_SECRET` (set to `DISABLED` to skip)
`VT_CONTEXT_KEY`, `VT_CONTEXT_URL`
`MALSHARE_MAILGUN_SMTP`, `MALSHARE_MAILGUN_PORT`, `MALSHARE_MAILGUN_FROM`, `MALSHARE_MAILGUN_USERNAME`, `MALSHARE_MAILGUN_PASSWORD`

## Local Dev

```bash
cd docker
docker-compose up
# Access at http://localhost/
```

---

# MalShare Offline

Static maintenance/offline page served by nginx. Displayed when the main site is down.

## Tech Stack

- nginx:alpine
- Static HTML + CSS (single `index.html`)

## Key Files

- `index.html` — Offline message page directing users to @Mal_Share on Twitter
- `Dockerfile` — Copies static files into nginx document root
- `.github/workflows/docker.yml` — Build, push to GHCR, trigger conf repo dispatch

## CI/CD

Same pattern as Frontend: push to `main` → build Docker image → push to `ghcr.io/malshare/offline` → trigger conf repo deployment.

---

# MalShare pymalshare

Python backend for MalShare — handles work PHP can't do efficiently.

## Components

- **`upload_handler.py`** — Long-running daemon that polls for pending samples, downloads from S3, detects file type (libmagic), computes ssdeep hash, and updates DB
- **`url_task_handler.py`** — Long-running daemon that polls `tbl_url_download_tasks` for user-submitted URLs, downloads them via Tor (SOCKS5 proxy bundled in container), ingests as samples via `submit_buffer()`
- **`generate_daily.py`** — Generates daily hash export files (MD5, SHA1, SHA256, combined) for each day since the first sample. Also copies the latest day's files as `malshare.current.*` to the output root

## Key Files

- `lib/db.py` — MariaDB database layer (uses `mariadb` Python package)
- `lib/storage.py` — S3/Wasabi storage abstraction (boto3)
- `lib/pymalshare.py` — Core class: sample processing, DB updates
- `docker/Dockerfile.upload_handler` — Container for upload handler (python:3.13, needs ssdeep/magic)
- `docker/Dockerfile.url_task_handler` — Container for URL task handler (python:3.13, needs ssdeep/magic/tor)
- `docker/Docker.generate_daily` — Container for daily export (python:3.13, needs mariadb client)

## Environment Variables

### Database (both scripts)
`MALSHARE_DB_HOST`, `MALSHARE_DB_USER`, `MALSHARE_DB_PASS`, `MALSHARE_DB_DATABASE` (default: `malshare_db`)

### S3 Storage (upload_handler, url_task_handler)
`WASABI_BUCKET`, `WASABI_KEY`, `WASABI_SECRET`, `WASABI_ENDPOINT`

### Output (generate_daily only)
`OUTPUT_DIR` — directory for generated hash lists

---

# Cross-Repo Architecture

All repos follow the same deployment pattern:

1. **Frontend**, **Offline**, and **pymalshare** are upstream image builders
2. Upstream repos use `CONF_DISPATCH_TOKEN` (malshare-bot fine-grained PAT) to trigger conf
3. **Conf** is the downstream deployer — receives dispatch events and deploys via SSH
4. All container images are private in GHCR; malshare-bot authenticates to pull them. New GHCR packages created by CI inherit org-level permissions automatically — no manual adjustment needed
5. To switch between Frontend and Offline on the server, change the `image:` in `src/docker-compose.yml`
6. pymalshare containers (generate-daily, upload-handler, url-task-handler) run alongside the frontend as additional services

---

# Working Notes

- When discovering new information about the projects (conf, Frontend, Offline, pymalshare), update both `CLAUDE.md` and `README.md` in the conf repo to keep them current.
- The Frontend requires a FULLTEXT index (`ft_source`) on `tbl_sample_sources.source` for source searches. If deploying to a fresh database, ensure `malshare_db.sql` is loaded (it includes the index). For existing databases, run: `ALTER TABLE tbl_sample_sources ADD FULLTEXT KEY ft_source (source);`
