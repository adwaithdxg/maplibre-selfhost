# =============================================================================
#  MapLibre Self-Hosted — operator convenience targets
#  Usage: `make help`
# =============================================================================
SHELL := /bin/bash
COMPOSE := docker compose
PROJECT := $(shell grep -E '^COMPOSE_PROJECT_NAME=' .env 2>/dev/null | cut -d= -f2 || echo maplibre)

.DEFAULT_GOAL := help

## --- Lifecycle --------------------------------------------------------------

.PHONY: init
init: ## Create .env from template if missing
	@test -f .env || (cp .env.example .env && echo "Created .env — edit DOMAIN & LETSENCRYPT_EMAIL")

.PHONY: up
up: init ## Build + start the whole stack (the only command you really need)
	$(COMPOSE) up -d --build

.PHONY: down
down: ## Stop and remove containers (keeps volumes/data)
	$(COMPOSE) down

.PHONY: restart
restart: ## Restart all services
	$(COMPOSE) restart

.PHONY: pull
pull: ## Pull newer base images (martin, certbot, nginx)
	$(COMPOSE) pull

## --- Observability ----------------------------------------------------------

.PHONY: ps
ps: ## Show service status + health
	$(COMPOSE) ps

.PHONY: logs
logs: ## Tail logs for all services (Ctrl-C to exit)
	$(COMPOSE) logs -f --tail=120

.PHONY: logs-gen
logs-gen: ## Tail the tile-generation job logs
	$(COMPOSE) logs -f generator

.PHONY: health
health: ## Quick health probe of the public endpoint
	@curl -fsS http://localhost/healthz && echo " (nginx ok)" || echo "nginx DOWN"
	@$(COMPOSE) exec -T martin curl -fsS http://localhost:3000/health && echo " (martin ok)" || echo "martin DOWN"

.PHONY: cert-status
cert-status: ## Show Let's Encrypt certificate status
	$(COMPOSE) exec -T certbot certbot certificates || true

## --- Tiles / data -----------------------------------------------------------

.PHONY: rebuild-tiles
rebuild-tiles: ## Force a fresh tile rebuild then restart Martin
	FORCE_TILE_REBUILD=true $(COMPOSE) up -d --no-deps --force-recreate generator
	$(COMPOSE) up -d --no-deps --force-recreate martin

.PHONY: update-data
update-data: ## Re-download latest OSM extracts and rebuild tiles
	$(COMPOSE) run --rm -e FORCE_TILE_REBUILD=true generator
	$(COMPOSE) restart martin nginx

.PHONY: purge-cache
purge-cache: ## Clear the Nginx edge tile cache
	$(COMPOSE) exec -T nginx sh -c 'rm -rf /var/cache/nginx/tiles/* && nginx -s reload'
	@echo "edge cache purged"

## --- Backup / restore -------------------------------------------------------

.PHONY: backup
backup: ## Snapshot tiles + certs + assets to ./backups/<timestamp>
	@mkdir -p backups
	@ts=$$(date -u +%Y%m%dT%H%M%SZ); \
	for v in tiles assets letsencrypt; do \
	  echo "backing up $(PROJECT)_$$v ..."; \
	  docker run --rm -v $(PROJECT)_$$v:/data -v $$PWD/backups:/backup alpine \
	    tar czf /backup/$$ts-$$v.tgz -C /data . ; \
	done; \
	echo "backup written to backups/$$ts-*.tgz"

.PHONY: restore
restore: ## Restore a volume: make restore VOL=tiles FILE=backups/xxx-tiles.tgz
	@test -n "$(VOL)" && test -n "$(FILE)" || (echo "usage: make restore VOL=tiles FILE=backups/<file>.tgz"; exit 1)
	docker run --rm -v $(PROJECT)_$(VOL):/data -v $$PWD/$(FILE):/backup.tgz:ro alpine \
	  sh -c 'rm -rf /data/* && tar xzf /backup.tgz -C /data'
	@echo "restored $(VOL) from $(FILE)"

## --- Danger zone ------------------------------------------------------------

.PHONY: nuke
nuke: ## Stop and DELETE all volumes (tiles, certs, cache) — irreversible
	$(COMPOSE) down -v

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
