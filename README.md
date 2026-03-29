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
server before pulling images, using the `GHCR_USER` and `GHCR_TOKEN` secrets. This means new images do not need to be
made public — they are pulled via `docker login` with the `malshare-bot` credentials.

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

# Frontend Tunnel

The frontend is exposed through a Cloudflare Tunnel instead of binding port `80` on the host.

## Setup

1. Copy `src/frontend.env.example` to `src/frontend.env` and fill in the frontend secrets.
2. In Cloudflare Zero Trust, create a tunnel for this host and copy its token into `CLOUDFLARE_TUNNEL_TOKEN` in `src/frontend.env`.
3. In the tunnel's **Public Hostname** settings, point the hostname at `http://frontend:80`.
4. Start the stack from `src/` with Docker Compose.

This Compose stack keeps the `frontend` container private on the Docker network and lets `cloudflared` publish it securely through Cloudflare.
