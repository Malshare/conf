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

# Offline Page Setup

```bash
mkdir /opt/static_html
cd /opt/static_html/
wget 'https://raw.githubusercontent.com/Malshare/offline/refs/heads/main/index.html'
wget 'https://github.com/Malshare/offline/blob/main/logo_header.png?raw=true' -O logo_header.png
```

# Startup Docker Compose
```bash
cd /root
mkdir conf-src
cd conf-src
docker compose up
```

# GitHub Setup

https://github.com/Malshare/conf/settings/secrets/actions contains all secrets needed by the files in `.gitlab` to
deploy things. In particular, the following variable: `SERVER_HOST`, `SERVER_SSH_KEY`, and `SERVER_USER`. To
emergency-disable this access, just remove the key `github-deploy` from `/root/.ssh/authorized_keys`.
