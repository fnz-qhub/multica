.PHONY: dev server daemon cli multica build test migrate-up migrate-down sqlc seed clean setup start stop check worktree-env setup-main start-main stop-main check-main setup-worktree start-worktree stop-worktree check-worktree db-up db-down selfhost selfhost-stop k8s-prereqs k8s-validate k8s-build-staging k8s-build-production k8s-diff k8s-deploy k8s-status k8s-logs docker-build docker-build-web

MAIN_ENV_FILE ?= .env
WORKTREE_ENV_FILE ?= .env.worktree
ENV_FILE ?= $(if $(wildcard $(MAIN_ENV_FILE)),$(MAIN_ENV_FILE),$(if $(wildcard $(WORKTREE_ENV_FILE)),$(WORKTREE_ENV_FILE),$(MAIN_ENV_FILE)))

ifneq ($(wildcard $(ENV_FILE)),)
include $(ENV_FILE)
endif

POSTGRES_DB ?= multica
POSTGRES_USER ?= multica
POSTGRES_PASSWORD ?= multica
POSTGRES_PORT ?= 5432
PORT ?= 8080
FRONTEND_PORT ?= 3000
FRONTEND_ORIGIN ?= http://localhost:$(FRONTEND_PORT)
MULTICA_APP_URL ?= $(FRONTEND_ORIGIN)
DATABASE_URL ?= postgres://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@localhost:$(POSTGRES_PORT)/$(POSTGRES_DB)?sslmode=disable
NEXT_PUBLIC_API_URL ?= http://localhost:$(PORT)
NEXT_PUBLIC_WS_URL ?= ws://localhost:$(PORT)/ws
GOOGLE_REDIRECT_URI ?= $(FRONTEND_ORIGIN)/auth/callback
MULTICA_SERVER_URL ?= ws://localhost:$(PORT)/ws

export

MULTICA_ARGS ?= $(ARGS)

COMPOSE := docker compose

define REQUIRE_ENV
	@if [ ! -f "$(ENV_FILE)" ]; then \
		echo "Missing env file: $(ENV_FILE)"; \
		echo "Create .env from .env.example, or run 'make worktree-env' and use .env.worktree."; \
		exit 1; \
	fi
endef

# ---------- Self-hosting (Docker Compose) ----------

# One-command self-host: create env, start Docker Compose, wait for health
selfhost:
	@if [ ! -f .env ]; then \
		echo "==> Creating .env from .env.example..."; \
		cp .env.example .env; \
		JWT=$$(openssl rand -hex 32); \
		if [ "$$(uname)" = "Darwin" ]; then \
			sed -i '' "s/^JWT_SECRET=.*/JWT_SECRET=$$JWT/" .env; \
		else \
			sed -i "s/^JWT_SECRET=.*/JWT_SECRET=$$JWT/" .env; \
		fi; \
		echo "==> Generated random JWT_SECRET"; \
	fi
	@echo "==> Starting Multica via Docker Compose..."
	docker compose -f docker-compose.selfhost.yml up -d --build
	@echo "==> Waiting for backend to be ready..."
	@for i in $$(seq 1 30); do \
		if curl -sf http://localhost:$${PORT:-8080}/health > /dev/null 2>&1; then \
			break; \
		fi; \
		sleep 2; \
	done
	@if curl -sf http://localhost:$${PORT:-8080}/health > /dev/null 2>&1; then \
		echo ""; \
		echo "✓ Multica is running!"; \
		echo "  Frontend: http://localhost:$${FRONTEND_PORT:-3000}"; \
		echo "  Backend:  http://localhost:$${PORT:-8080}"; \
		echo ""; \
		echo "Log in with any email + verification code: 888888"; \
		echo ""; \
		echo "Next — install the CLI and connect your machine:"; \
		echo "  brew install multica-ai/tap/multica"; \
		echo "  multica setup self-host"; \
	else \
		echo ""; \
		echo "Services are still starting. Check logs:"; \
		echo "  docker compose -f docker-compose.selfhost.yml logs"; \
	fi

# Stop all Docker Compose self-host services
selfhost-stop:
	@echo "==> Stopping Multica services..."
	docker compose -f docker-compose.selfhost.yml down
	@echo "✓ All services stopped."

# ---------- One-click commands ----------

# First-time setup: install deps, start DB, run migrations
setup:
	$(REQUIRE_ENV)
	@echo "==> Using env file: $(ENV_FILE)"
	@echo "==> Installing dependencies..."
	pnpm install
	@bash scripts/ensure-postgres.sh "$(ENV_FILE)"
	@echo "==> Running migrations..."
	cd server && go run ./cmd/migrate up
	@echo ""
	@echo "✓ Setup complete! Run 'make start' to launch the app."

# Start all services (backend + frontend)
start:
	$(REQUIRE_ENV)
	@echo "Using env file: $(ENV_FILE)"
	@echo "Backend: http://localhost:$(PORT)"
	@echo "Frontend: http://localhost:$(FRONTEND_PORT)"
	@bash scripts/ensure-postgres.sh "$(ENV_FILE)"
	@echo "Starting backend and frontend..."
	@trap 'kill 0' EXIT; \
		(cd server && go run ./cmd/server) & \
		pnpm dev:web & \
		wait

# Stop all services
stop:
	$(REQUIRE_ENV)
	@echo "Stopping services..."
	@-lsof -ti:$(PORT) | xargs kill -9 2>/dev/null
	@-lsof -ti:$(FRONTEND_PORT) | xargs kill -9 2>/dev/null
	@case "$(DATABASE_URL)" in \
		""|*@localhost:*|*@localhost/*|*@127.0.0.1:*|*@127.0.0.1/*|*@\[::1\]:*|*@\[::1\]/*) \
			echo "✓ App processes stopped. Shared PostgreSQL is still running on localhost:$(POSTGRES_PORT)." ;; \
		*) \
			echo "✓ App processes stopped. Remote PostgreSQL was not affected." ;; \
	esac

# Full verification: typecheck + unit tests + Go tests + E2E
check:
	$(REQUIRE_ENV)
	@ENV_FILE="$(ENV_FILE)" bash scripts/check.sh

db-up:
	@$(COMPOSE) up -d postgres

db-down:
	@$(COMPOSE) down

worktree-env:
	@bash scripts/init-worktree-env.sh .env.worktree

setup-main:
	@$(MAKE) setup ENV_FILE=$(MAIN_ENV_FILE)

start-main:
	@$(MAKE) start ENV_FILE=$(MAIN_ENV_FILE)

stop-main:
	@$(MAKE) stop ENV_FILE=$(MAIN_ENV_FILE)

check-main:
	@ENV_FILE=$(MAIN_ENV_FILE) bash scripts/check.sh

setup-worktree:
	@if [ ! -f "$(WORKTREE_ENV_FILE)" ]; then \
		echo "==> Generating $(WORKTREE_ENV_FILE) with unique ports..."; \
		bash scripts/init-worktree-env.sh $(WORKTREE_ENV_FILE); \
	else \
		echo "==> Using existing $(WORKTREE_ENV_FILE)"; \
	fi
	@$(MAKE) setup ENV_FILE=$(WORKTREE_ENV_FILE)

start-worktree:
	@$(MAKE) start ENV_FILE=$(WORKTREE_ENV_FILE)

stop-worktree:
	@$(MAKE) stop ENV_FILE=$(WORKTREE_ENV_FILE)

check-worktree:
	@ENV_FILE=$(WORKTREE_ENV_FILE) bash scripts/check.sh

# ---------- Individual commands ----------

# One-command dev: auto-setup env/deps/db/migrations, then start all services
dev:
	@bash scripts/dev.sh

# Go server only
server:
	$(REQUIRE_ENV)
	@bash scripts/ensure-postgres.sh "$(ENV_FILE)"
	cd server && go run ./cmd/server

daemon:
	@$(MAKE) multica MULTICA_ARGS="daemon"

cli:
	@$(MAKE) multica MULTICA_ARGS="$(MULTICA_ARGS)"

multica:
	cd server && go run ./cmd/multica $(MULTICA_ARGS)

VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
COMMIT  ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
DATE    ?= $(shell date -u '+%Y-%m-%dT%H:%M:%SZ')

build:
	cd server && go build -o bin/server ./cmd/server
	cd server && go build -ldflags "-X main.version=$(VERSION) -X main.commit=$(COMMIT) -X main.date=$(DATE)" -o bin/multica ./cmd/multica
	cd server && go build -o bin/migrate ./cmd/migrate

test:
	$(REQUIRE_ENV)
	@bash scripts/ensure-postgres.sh "$(ENV_FILE)"
	cd server && go run ./cmd/migrate up
	cd server && go test ./...

# Database
migrate-up:
	$(REQUIRE_ENV)
	@bash scripts/ensure-postgres.sh "$(ENV_FILE)"
	cd server && go run ./cmd/migrate up

migrate-down:
	$(REQUIRE_ENV)
	@bash scripts/ensure-postgres.sh "$(ENV_FILE)"
	cd server && go run ./cmd/migrate down

sqlc:
	cd server && sqlc generate

# ---------- Kubernetes ----------

IMAGE_REGISTRY ?= ghcr.io/multica-ai/multica
IMAGE_TAG      ?= $(VERSION)
K8S_ENV        ?= staging

# Check cluster prerequisites before deploying
k8s-prereqs:
	@echo "==> Checking prerequisites..."
	@command -v kubectl >/dev/null 2>&1 || { echo "✗ kubectl not found"; exit 1; }
	@kubectl cluster-info >/dev/null 2>&1 || { echo "✗ Cannot connect to cluster. Check your kubeconfig."; exit 1; }
	@echo "  ✓ kubectl connected to $$(kubectl config current-context)"
	@kubectl get ingressclass nginx >/dev/null 2>&1 \
		&& echo "  ✓ ingress-nginx controller installed" \
		|| echo "  ⚠ ingress-nginx not found — Ingress resource will not work until installed"
	@kubectl get storageclass >/dev/null 2>&1 \
		&& echo "  ✓ StorageClass available: $$(kubectl get storageclass -o jsonpath='{.items[0].metadata.name}')" \
		|| echo "  ⚠ No StorageClass found — PostgreSQL PVC may not provision"
	@kubectl get namespace multica >/dev/null 2>&1 \
		&& echo "  ✓ Namespace 'multica' exists" \
		|| echo "  ○ Namespace 'multica' will be created on deploy"
	@kubectl -n multica get secret backend-secrets >/dev/null 2>&1 \
		&& echo "  ✓ backend-secrets configured" \
		|| echo "  ⚠ backend-secrets not found — create before deploying (see k8s/README.md)"
	@kubectl -n multica get secret postgres-secrets >/dev/null 2>&1 \
		&& echo "  ✓ postgres-secrets configured" \
		|| echo "  ⚠ postgres-secrets not found — create before deploying (see k8s/README.md)"
	@echo ""
	@echo "Done. Fix any ✗ errors before deploying. ⚠ warnings may resolve on first apply."

# Validate all manifests render without errors
k8s-validate:
	@echo "==> Validating base manifests..."
	kubectl kustomize k8s/base/ > /dev/null
	@echo "==> Validating staging overlay..."
	kubectl kustomize k8s/overlays/staging/ > /dev/null
	@echo "==> Validating production overlay..."
	kubectl kustomize k8s/overlays/production/ > /dev/null
	@echo "✓ All manifests valid."

# Render staging manifests to stdout
k8s-build-staging:
	kubectl kustomize k8s/overlays/staging/

# Render production manifests to stdout
k8s-build-production:
	kubectl kustomize k8s/overlays/production/

# Show diff between current cluster state and local manifests (requires kubectl access)
k8s-diff:
	kubectl diff -k k8s/overlays/$(K8S_ENV)/ || true

# Deploy to cluster (validates first, then applies)
k8s-deploy: k8s-validate
	@echo "==> Deploying $(K8S_ENV) overlay..."
	kubectl apply -k k8s/overlays/$(K8S_ENV)/
	@echo ""
	@echo "✓ Applied. Watching rollout..."
	@kubectl -n multica rollout status deployment/backend --timeout=120s 2>/dev/null || true
	@kubectl -n multica rollout status deployment/frontend --timeout=120s 2>/dev/null || true
	@echo ""
	@echo "✓ Deploy complete. Run 'make k8s-status' to check health."

# Show deployment status at a glance
k8s-status:
	@echo "==> Pods"
	@kubectl -n multica get pods -o wide 2>/dev/null || echo "  (namespace 'multica' not found)"
	@echo ""
	@echo "==> Services"
	@kubectl -n multica get svc 2>/dev/null || true
	@echo ""
	@echo "==> Ingress"
	@kubectl -n multica get ingress 2>/dev/null || true
	@echo ""
	@echo "==> Jobs"
	@kubectl -n multica get jobs 2>/dev/null || true

# Tail logs for a service (usage: make k8s-logs SVC=backend)
SVC ?= backend
k8s-logs:
	kubectl -n multica logs -l app.kubernetes.io/name=$(SVC) -f --tail=100

# Build backend Docker image
docker-build:
	docker build -t $(IMAGE_REGISTRY)/backend:$(IMAGE_TAG) \
		--build-arg VERSION=$(VERSION) \
		--build-arg COMMIT=$(COMMIT) \
		-f Dockerfile .

# Build frontend Docker image
docker-build-web:
	docker build -t $(IMAGE_REGISTRY)/web:$(IMAGE_TAG) \
		-f Dockerfile.web .

# ---------- Cleanup ----------

clean:
	rm -rf server/bin server/tmp
