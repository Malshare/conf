# Malshare Configuration

This repository is used to continuously deploy software and configure the server node(s).

# Docker Setup

```bash
sudo -i
apt update
apt install ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
tee /etc/apt/sources.list.d/docker.sources <<EOF

apt update
apt install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl status docker
docker run hello-world
```

# GitHub Setup

https://github.com/Malshare/conf/settings/secrets/actions contains all secrets needed by the files in `.gitlab` to
deploy things. In particular, the following variable: `SERVER_HOST`, `SERVER_SSH_KEY`, and `SERVER_USER`. To
emergency-disable this access, just remove the key `github-deploy` from `/root/.ssh/authorized_keys`.

There is also a Bot account with the GitHub username `malshare-bot`. Its purpose is to create Personal Access Tokens
(PATs) for CI/CD automation. Corresponding credentials are stored in `GHCR_USER` and `GHCR_TOKEN`.

## Container Registry Authentication

All GHCR packages in the `Malshare` org are **private**. The deploy workflow (`deploy.yml`) authenticates to GHCR on the
server before pulling images, using the `GHCR_USER` and `GHCR_TOKEN` secrets. New GHCR packages created by CI inherit
org-level permissions automatically — no manual adjustment needed. They are pulled via `docker login` with the
`malshare-bot` credentials.

This repository opts into the repository dispatch type `upstream-image-built` which will be triggered by other MalShare
repositories on GitHub when they finished building their images. Each of those upstream repositories needs a PAT with
write-access to this repository here. This token is stored as `CONF_DISPATCH_TOKEN` in each upstream repo's Actions
secrets.

## Creating a `CONF_DISPATCH_TOKEN`

When adding a new upstream repository that needs to trigger deployments:

1. Log in as `malshare-bot` on GitHub
2. Go to **Settings > Developer settings > Personal access tokens > Fine-grained tokens**
3. Create a new token:
   - **Name:** e.g. `conf-dispatch-<repo-name>`
   - **Resource owner:** `Malshare`
   - **Repository access:** select `Malshare/conf` only
   - **Permissions:** Contents → Read and write
4. Copy the token
5. An **organization owner** must approve the token at **Malshare org > Settings > Personal access tokens > Pending requests**
6. In the upstream repo (e.g. `Malshare/frontend`), go to **Settings > Secrets and variables > Actions**
7. Add a new secret named `CONF_DISPATCH_TOKEN` with the token value

Upstream repos that currently use this token:
- `Malshare/offline`
- `Malshare/frontend`
- `Malshare/pymalshare`

# Operator Commands

All day-to-day operations on the Hetzner host go through the `Makefile` in `/root/conf-src/` (the deployed copy of `src/`). Run `make` with no arguments to print the target list. Common ones:

```bash
make up                # docker compose up -d --pull always
make down              # stop the stack
make ps                # docker compose ps
make logs              # tail all logs (or: make logs SERVICE=frontend)
make restart           # restart everything (or: make restart SERVICE=upload-handler)

make offline           # serve ghcr.io/malshare/offline as the frontend
make online            # restore the normal frontend image

make mysql             # root shell in the local mysql container
make mysql-backup      # gzipped dump into ./backups/
make migrate-from-gcp  # one-shot GCP CloudSQL -> local mysql bootstrap

make validate          # docker compose config check (base + offline overlay)
```

# Frontend Tunnel

The frontend is exposed through a Cloudflare Tunnel instead of binding port `80` on the host.

## Setup

1. Copy `src/frontend.env.example` to `src/frontend.env` and fill in the frontend secrets.
2. In Cloudflare Zero Trust, create a tunnel for this host and copy its token into `TUNNEL_TOKEN` in `src/frontend.env`.
3. In the tunnel's **Public Hostname** settings, point the hostname at `http://frontend:80`.
4. Start the stack from `src/` with `make up` (equivalent to `docker compose up -d --pull always`).

This Compose stack keeps the `frontend` container private on the Docker network and lets `cloudflared` publish it securely through Cloudflare.

## Maintenance mode

`make offline` applies `docker-compose.offline.yml` on top of the base config, swapping `frontend.image` to `ghcr.io/malshare/offline`. The Cloudflare tunnel keeps pointing at `http://frontend:80`, so the public hostname stays up but serves the static "we're offline" page from the [Malshare/offline](https://github.com/Malshare/offline) repo. The DB and worker services are left running — stop them separately if you want a true freeze. `make online` swaps the regular frontend image back in.

# Database

MySQL 8.0.31 runs inside the compose stack as the `mysql` service and is reachable from the other containers as host `mysql:3306`. The data directory is bind-mounted to `/storage/malshare/mysql` on the host, so the database survives container/image churn.

## First-time setup on the host

```bash
mkdir -p /storage/malshare/mysql
chown -R 999:999 /storage/malshare/mysql   # the mysql:8.0.31 image runs as uid/gid 999
```

The mysql container reads `MYSQL_ROOT_PASSWORD`, `MYSQL_USER`, `MYSQL_PASSWORD`, and `MYSQL_DATABASE` from `frontend.env` on first boot. These must match the `MALSHARE_DB_*` values the rest of the stack uses to connect. See `src/frontend.env.example`.

## Migrating from the old GCP CloudSQL instance

The historical primary lived at `34.44.192.195` (GCP CloudSQL, project `malshare`, instance `malsharedb`, MySQL 8.0.31). `src/migrate-from-gcp.sh` performs a one-shot `mysqldump | mysql` over the public IP. Run it on the Hetzner host after the `mysql` service is up and healthy, with the upload-handler and url-task-handler stopped so no writes race the dump:

```bash
cd /root/conf-src
docker compose up -d mysql
docker compose stop upload-handler url-task-handler
./migrate-from-gcp.sh                       # prompts for the GCP root password
docker compose up -d                        # bring the rest of the stack back
```

Compare the per-table row counts the script prints against the source before declaring the cutover done.
