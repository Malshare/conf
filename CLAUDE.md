# MalShare Conf

Deployment and orchestration repository for MalShare server infrastructure.

## What This Repo Does

Manages production Docker Compose config and CI/CD deployment. When upstream repos (Frontend, Offline, pymalshare) push to `main`, they build Docker images, push to GHCR, then trigger this repo's deploy workflow via `repository_dispatch`.

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

- `src/docker-compose.yml` — Production service definitions (mysql, frontend, cloudflared tunnel, upload-handler, url-task-handler, generate-daily, rollup-api-calls, refresh-stats, cleanup-users)
- `src/docker-compose.offline.yml` — Override file that swaps `frontend.image` to `ghcr.io/malshare/offline` for maintenance windows
- `src/Makefile` — Operator entry point on the Hetzner host; `make` with no args prints the target list. See "Operator commands" below
- `src/frontend.env` — Environment variables for all containers (NOT committed with real secrets). Also consumed by the `mysql` service on first boot for `MYSQL_ROOT_PASSWORD` / `MYSQL_USER` / `MYSQL_PASSWORD` / `MYSQL_DATABASE`
- `src/migrate-from-gcp.sh` — One-shot helper run on the Hetzner host that mysqldumps `malshare_db` from the GCP CloudSQL instance and streams it into the local `mysql` container
- `.github/workflows/deploy.yml` — Deployment workflow triggered by push or upstream dispatch

## Operator commands

The `Makefile` in `src/` (deployed to `/root/conf-src/Makefile`) is the canonical entry point on the server. Run `make` with no arguments for the full list. Most useful:

| Target | What it does |
| --- | --- |
| `make up` / `make deploy` | `docker compose up -d --pull always` (matches the CI deploy step) |
| `make down` | Stop the stack (volumes preserved) |
| `make restart [SERVICE=name]` | Restart everything or one service |
| `make offline` | Apply `docker-compose.offline.yml` and bring up frontend+cloudflared with the maintenance image |
| `make online` | Restore the normal frontend image (run after `make offline`) |
| `make logs [SERVICE=name]` | Tail logs |
| `make ps` | `docker compose ps` |
| `make mysql` | Root mysql shell against the local DB |
| `make mysql-backup` | gzipped mysqldump to `./backups/malshare_db-<timestamp>.sql.gz` |
| `make migrate-from-gcp` | Runs the GCP -> local bootstrap script |
| `make validate` | `docker compose config --quiet` on both the base and offline-overlay configs |

## GitHub Secrets (org-level)

- `SERVER_HOST`, `SERVER_USER`, `SERVER_SSH_KEY` — SSH access to production server
- `GHCR_USER`, `GHCR_TOKEN` — malshare-bot credentials for pulling private GHCR images

## Server Layout

On the production server (Hetzner, `46.225.99.0`), `src/*` is copied to `/root/conf-src/`. The `frontend.env` file must exist there alongside `docker-compose.yml`.

### Persistent storage

The MySQL data directory is bind-mounted to `/storage/malshare/mysql` on the host. This path **must** exist and be empty before the first `docker compose up -d mysql`. The `mysql` container runs as UID/GID 999 (the official image's `mysql` user); ensure the directory is owned by `999:999` or just `root:root` with `chmod 700`.

```bash
mkdir -p /storage/malshare/mysql
chown -R 999:999 /storage/malshare/mysql
```

## Shared Volumes

- `daily_exports` (named volume) — Written by `generate-daily`, mounted read-only into `frontend` at `/var/www/html/daily/`. Serves browsable directory listings of daily hash exports at the `/daily/` URL path.
- `/storage/malshare/mysql` (bind mount) — MySQL 8.0.31 data directory.

## Database

Production MySQL runs in-container (`mysql:8.0.31`, matching the prior GCP CloudSQL version). Frontend and pymalshare services reach it as host `mysql` over the compose network — port 3306 is **not** exposed on the host.

The historical source was a GCP CloudSQL instance at `34.44.192.195` (project `malshare`, instance `malsharedb`). It was migrated onto the Hetzner host using `src/migrate-from-gcp.sh`, which mysqldumps the schema + data over the public IP and streams it into the local container.

### Initial migration runbook

```bash
# On the Hetzner host:
mkdir -p /storage/malshare/mysql
chown -R 999:999 /storage/malshare/mysql

cd /root/conf-src
# Populate frontend.env, including MYSQL_ROOT_PASSWORD and matching
# MALSHARE_DB_* / MYSQL_* credentials.

# Park the public site on the maintenance page for the duration of the cutover:
make offline

# Bring up the local mysql service and wait for healthcheck:
docker compose up -d mysql
make ps

# Stop the writers so the dump is consistent:
docker compose stop upload-handler url-task-handler

# Run the migration (will prompt for the GCP root password):
make migrate-from-gcp

# Spot-check row counts in the script's output against the GCP source,
# then flip the rest of the stack onto the local DB:
make online
make up
```

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
- **`url_task_handler.py`** — Long-running daemon that polls `tbl_url_download_tasks` for user-submitted URLs, downloads them via Tor (SOCKS5 proxy bundled in container), ingests as samples via `submit_buffer()`. Tor bandwidth is capped at 1MB/s (burst 2MB/s) in the entrypoint to avoid saturating the server link during consensus downloads
- **`generate_daily.py`** — Generates daily hash export files (MD5, SHA1, SHA256, combined) for each day since the first sample. Also copies the latest day's files as `malshare.current.*` to the output root
- **`rollup_api_calls.py`** — Two-tier aggregation of `tbl_api_calls` into `tbl_api_calls_daily` (30+ days → per-user/endpoint/day; 365+ days → endpoint-only). Run daily
- **`refresh_stats.py`** — Precomputes expensive sample statistics (COUNT, GROUP BY year, GROUP BY ftype, all-time API calls) into `tbl_stats_cache`. Frontend reads from this table instead of running full table scans. Run hourly
- **`cleanup_users.py`** — Clears IP address history for users inactive 90+ days. Run daily

## Key Files

- `lib/db.py` — MariaDB database layer (uses `mariadb` Python package)
- `lib/storage.py` — S3/Wasabi storage abstraction (boto3)
- `lib/pymalshare.py` — Core class: sample processing, DB updates
- `docker/Dockerfile.base` — Shared base image (`ghcr.io/malshare/pymalshare-base`) with python:3.13, ssdeep, libmagic, pymysql, boto3. All pymalshare services except generate-daily inherit from this
- `docker/Dockerfile.upload_handler` — Upload handler, extends base
- `docker/Dockerfile.url_task_handler` — URL task handler, extends base + adds tor and requests[socks]
- `docker/Docker.generate_daily` — Daily export (independent, python:3.14 + mariadb client)
- `docker/Dockerfile.rollup_api_calls` — API call rollup (python:3.14 + mariadb)
- `docker/Dockerfile.refresh_stats` — Stats cache refresh (python:3.14 + mariadb)
- `docker/Dockerfile.cleanup_users` — User IP cleanup (python:3.14 + mariadb)

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
6. pymalshare containers (upload-handler, url-task-handler, generate-daily, rollup-api-calls, refresh-stats, cleanup-users) run alongside the frontend as additional services

---

# Working Notes

- When discovering new information about the projects (conf, Frontend, Offline, pymalshare), update both `CLAUDE.md` and `README.md` in the conf repo to keep them current.
- The Frontend requires a FULLTEXT index (`ft_source`) on `tbl_sample_sources.source` for source searches. If deploying to a fresh database, ensure `malshare_db.sql` is loaded (it includes the index). For existing databases, run: `ALTER TABLE tbl_sample_sources ADD FULLTEXT KEY ft_source (source);`
- `tbl_url_download_tasks` uses `'1970-01-01 00:00:01'` (UTC) as the sentinel default for `started_at` and `finished_at` — NOT `01:00:01`. The url-task-handler polls for rows where `started_at` equals this value.
- The schema file `malshare_db.sql` in the Frontend repo should be kept in sync with the production database. To get the current schema: `mysqldump --no-data -h HOST -u USER -p malshare_db`
