# Phase 1: Foundation and Database - Context

**Gathered:** 2026-04-14
**Status:** Ready for planning

<domain>
## Phase Boundary

Namespace, ConfigMaps, Secrets, ServiceAccounts, RBAC, and PostgreSQL StatefulSet with pgvector enabled and migration Job. This phase creates the cluster foundation that all subsequent phases depend on.

</domain>

<decisions>
## Implementation Decisions

### Directory structure
- Manifests live in `k8s/base/<service>/` with a Kustomize `kustomization.yaml` at each level
- Phase 1 creates: `k8s/base/namespace.yaml`, `k8s/base/postgres/`, `k8s/base/config/`
- Max 4 levels deep per K8s guidance

### Namespace
- Single namespace `multica` for all resources
- All manifests include `namespace: multica` explicitly (not relying on kubectl context)

### ConfigMaps
- One ConfigMap per service: `backend-config`, `frontend-config`, `postgres-config`
- Backend needs: `DATABASE_URL`, `PORT=8080`, `JWT_SECRET` (via Secret), `RESEND_API_KEY` (via Secret)
- Frontend needs: `REMOTE_API_URL=http://backend:8080` (build-time, documented only)
- PostgreSQL needs: non-secret Postgres config (max_connections, shared_buffers)

### Secrets
- Separate Secret resources: `backend-secrets`, `postgres-secrets`
- `backend-secrets`: `JWT_SECRET`, `RESEND_API_KEY`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`
- `postgres-secrets`: `POSTGRES_PASSWORD`, `DATABASE_URL`
- Placeholder values only in git — real values injected via deployment runbook
- `*-secret.yaml` files added to `.gitignore`

### PostgreSQL StatefulSet
- Image: `pgvector/pgvector:pg17` (project constraint, non-negotiable)
- `replicas: 1` hard-coded (multi-replica without operator = split brain)
- Headless Service for StatefulSet DNS + ClusterIP Service for app connections
- `volumeClaimTemplates` for persistent storage (storageClassName left configurable via Kustomize overlay)
- pgvector extension enabled via ConfigMap mounted as `/docker-entrypoint-initdb.d/init.sql` containing `CREATE EXTENSION IF NOT EXISTS vector;`

### Database migration
- Kubernetes Job resource, NOT the current entrypoint.sh approach
- The existing `./migrate up` binary is already built in the Dockerfile — Job uses the same image with command override
- Job runs once; backend readiness probe gates traffic until DB is ready
- `backoffLimit: 3` for retry on transient failures

### ServiceAccounts and RBAC
- One ServiceAccount per workload: `backend-sa`, `frontend-sa`, `postgres-sa`
- Minimal RBAC — no cluster-wide permissions needed for application workloads
- `automountServiceAccountToken: false` where not needed

### Claude's Discretion
- Exact resource requests/limits for PostgreSQL (conservative starting point)
- ConfigMap naming conventions beyond what's specified
- Kustomization.yaml structure details
- Label and annotation conventions

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- `Dockerfile` (Go backend): Multi-stage build, produces `server`, `multica`, `migrate` binaries. Uses `alpine:3.21` runtime
- `Dockerfile.web` (Next.js frontend): 3-stage build with standalone output, already sets `HOSTNAME=0.0.0.0`
- `docker/entrypoint.sh`: Currently runs `./migrate up` then `./server` — K8s Job replaces the migration part
- `server/cmd/migrate/`: Separate migration binary already exists

### Established Patterns
- Backend reads config from env vars: `DATABASE_URL`, `PORT`, `JWT_SECRET`, `RESEND_API_KEY`
- Backend has `/health` endpoint (used in request logger middleware skip)
- Backend handles SIGTERM gracefully with 10s shutdown timeout
- Frontend uses `NEXT_PUBLIC_*` as build-time args via Dockerfile ARGs (not runtime ConfigMap)

### Integration Points
- `DATABASE_URL` format: `postgres://multica:multica@localhost:5432/multica?sslmode=disable` (default in main.go)
- K8s Service DNS will change host from `localhost` to `postgres.multica.svc.cluster.local`
- Frontend `REMOTE_API_URL` defaults to `http://backend:8080` (already K8s-ready in Dockerfile.web)

</code_context>

<specifics>
## Specific Ideas

No specific requirements — auto mode. Standard Kubernetes patterns apply. Key constraint: the existing Dockerfiles are the build artifacts; manifests reference images built from them.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope (auto mode).

</deferred>

---

*Phase: 01-foundation-database*
*Context gathered: 2026-04-14*
