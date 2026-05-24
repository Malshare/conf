# MalShare compose stack helper.
# Run `make` with no arguments to see the available targets.

SHELL          := /usr/bin/env bash
.SHELLFLAGS    := -eu -o pipefail -c
.DEFAULT_GOAL  := help

COMPOSE        ?= docker compose
COMPOSE_FILE   ?= docker-compose.yml
OFFLINE_FILE   ?= docker-compose.offline.yml
ENV_FILE       ?= frontend.env

DC             := $(COMPOSE) -f $(COMPOSE_FILE)
DC_OFFLINE     := $(COMPOSE) -f $(COMPOSE_FILE) -f $(OFFLINE_FILE)

# SERVICE= overrides which service a target operates on (e.g. logs, shell).
SERVICE ?=

##@ General

.PHONY: help
help: ## Show this help.
	@awk 'BEGIN {FS = ":.*##"; printf "MalShare compose helper\n\nUsage:\n  make \033[36m<target>\033[0m [SERVICE=name]\n"} \
		/^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2 } \
		/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

.PHONY: validate
validate: _require_env ## Validate the merged compose config.
	@$(DC) config --quiet && echo "docker-compose.yml: OK"
	@$(DC_OFFLINE) config --quiet && echo "docker-compose.yml + offline override: OK"

##@ Deployment

.PHONY: pull
pull: _require_env ## Pull the latest images for all services.
	$(DC) pull

.PHONY: up
up: _require_env ## Start the full online stack (pulls + recreates as needed).
	$(DC) up -d --pull always

.PHONY: deploy
deploy: up ## Alias for `up` — matches what the GitHub Actions workflow runs.

.PHONY: down
down: _require_env ## Stop and remove all containers (volumes preserved).
	$(DC) down

.PHONY: restart
restart: _require_env ## Restart all services (or one with SERVICE=name).
	$(DC) restart $(SERVICE)

##@ Maintenance mode

.PHONY: offline
offline: _require_env ## Swap the frontend to the static offline/maintenance page.
	$(DC_OFFLINE) up -d --pull always frontend cloudflared
	@echo
	@echo "Site is now serving ghcr.io/malshare/offline."
	@echo "Run 'make online' to restore."

.PHONY: online
online: _require_env ## Restore the normal frontend after `make offline`.
	$(DC) up -d --pull always frontend cloudflared
	@echo
	@echo "Site is back online."

##@ Inspection

.PHONY: ps
ps: _require_env ## List the stack's containers.
	$(DC) ps

.PHONY: logs
logs: _require_env ## Tail logs for all services (or one with SERVICE=name).
	$(DC) logs -f --tail=200 $(SERVICE)

.PHONY: shell
shell: _require_env ## Open a shell in SERVICE=name (defaults to frontend).
	$(DC) exec $(or $(SERVICE),frontend) /bin/sh

##@ Database

.PHONY: mysql
mysql: _require_env ## Open a root mysql shell against the local DB.
	@set -a; . ./$(ENV_FILE); set +a; \
		$(DC) exec mysql mysql -uroot -p"$$MYSQL_ROOT_PASSWORD" "$$MALSHARE_DB_DATABASE"

.PHONY: mysql-backup
mysql-backup: _require_env ## Dump the local DB to ./backups/malshare_db-<timestamp>.sql.gz.
	@mkdir -p backups
	@set -a; . ./$(ENV_FILE); set +a; \
		out="backups/malshare_db-$$(date -u +%Y%m%dT%H%M%SZ).sql.gz"; \
		$(DC) exec -T mysql \
			mysqldump -uroot -p"$$MYSQL_ROOT_PASSWORD" \
				--single-transaction --quick --routines --triggers --events --hex-blob \
				"$$MALSHARE_DB_DATABASE" | gzip > "$$out"; \
		echo "Wrote $$out"

.PHONY: migrate-from-gcp
migrate-from-gcp: _require_env ## Run the one-shot GCP -> local mysqldump bootstrap.
	./migrate-from-gcp.sh

# --- internals -------------------------------------------------------------

.PHONY: _require_env
_require_env:
	@test -f $(ENV_FILE) || { \
		echo "ERROR: $(ENV_FILE) not found. Copy $(ENV_FILE).example and fill it in." >&2; \
		exit 1; \
	}
