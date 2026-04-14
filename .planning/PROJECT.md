# Kubernetes Manifests

## What This Is

Kubernetes deployment manifests for the Multica platform. Provides production-ready K8s configuration files to deploy the Go backend, Next.js frontend, Electron desktop build pipeline, and supporting services (PostgreSQL, WebSocket) on a Kubernetes cluster.

## Core Value

A single `kubectl apply` (or equivalent) deploys the entire Multica stack to any Kubernetes cluster with correct networking, persistence, and scaling defaults.

## Requirements

### Validated

(None yet — ship to validate)

### Active

- [ ] Deployment manifests for Go backend server
- [ ] Deployment manifests for Next.js web frontend
- [ ] StatefulSet or operator config for PostgreSQL with pgvector
- [ ] Service definitions with correct port mappings (backend 8080, frontend 3000)
- [ ] Ingress/networking configuration for external access
- [ ] ConfigMaps and Secrets for environment configuration
- [ ] Persistent volume claims for database storage
- [ ] Health checks (liveness/readiness probes) for all services
- [ ] Resource requests and limits for all containers
- [ ] Namespace isolation

### Out of Scope

- Helm chart packaging — plain manifests first, Helm later if needed
- CI/CD pipeline integration — manifests only, deployment automation separate
- Electron desktop packaging — not a K8s workload
- Service mesh (Istio/Linkerd) — unnecessary complexity for initial deployment
- Multi-cluster federation — single cluster target for now
- Autoscaling (HPA/VPA) — can be added after baseline is stable

## Context

- Multica is a monorepo: Go backend (`server/`), Next.js frontend (`apps/web/`), shared packages
- Backend uses Chi router, sqlc for DB, gorilla/websocket for real-time
- PostgreSQL with pgvector extension required (image: `pgvector/pgvector:pg17`)
- WebSocket connections need sticky sessions or proper load balancing
- Environment variables drive configuration (see `.env` patterns in repo)
- The daemon process (`make daemon`) is a local-only concern, not deployed to K8s

## Constraints

- **Database**: Must use pgvector/pgvector:pg17 image — pgvector extension required
- **Networking**: WebSocket support required for real-time features — ingress must handle upgrade headers
- **Multi-tenancy**: All backend requests use `X-Workspace-ID` header for routing
- **Ports**: Backend 8080, Frontend 3000 (match existing dev setup)

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Plain manifests over Helm | Simpler starting point, easier to understand and debug | — Pending |
| Single namespace per environment | Clear isolation without over-engineering | — Pending |

---
*Last updated: 2026-04-14 after initialization*
