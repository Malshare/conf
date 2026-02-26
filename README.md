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

There is also a Bot account with the GitHub username `malshare-bot`. Its purpose is to create a Personal Access Token
(PAT) with read access to the container registry. Corresponding credentials are stored in `GHCR_USER` and `GHCR_TOKEN`.

This repository opts into the repository dispatch type `upstream-image-built` which will be triggered by other MalShare
repositories on GitHub when they finished building their images. Each of those upstream repositories needs a PAT with
write-access to this repository here.
