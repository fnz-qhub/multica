# Phase 2: Application Workloads - Context

**Gathered:** 2026-04-14
**Status:** Ready for planning

<domain>
## Phase Boundary

Go backend and Next.js frontend Deployments with health probes, resource limits, rolling update strategy, and ClusterIP Services. Both services must be reachable within the cluster. External ingress is Phase 3.

</domain>

<decisions>
## Implementation Decisions

### Go backend Deployment
- Image reference: uses existing `Dockerfile` (alpine-based runtime with `server`, `multica`, `migrate` binaries)
- Entrypoint override: run `./server` directly (NOT `./entrypoint.sh` which also runs migrations — migration is a Phase 1 Job)
- Configurable replicas (default 2)
- Env vars from Phase 1 ConfigMaps/Secrets: `backend-config`, `backend-secrets`, `postgres-secrets` (for DATABASE_URL)

### Health probes (backend)
- The existing code only has `/health` — manifests should use it for readiness
- Liveness probe: TCP socket check on port 8080 (process alive, no DB dependency to avoid restart storms)
- Readiness probe: HTTP GET `/health` on port 8080 (confirms server started and DB reachable since startup pings DB)
- Startup probe: HTTP GET `/health` with `failureThreshold: 30`, `periodSeconds: 2` (60s max startup)
- Note: Research recommends split `/livez`/`/readyz` but existing code only has `/health`. Manifests use what exists; splitting endpoints is a code change outside K8s manifest scope.

### Backend rolling update
- `maxSurge: 1`, `maxUnavailable: 0` — zero-downtime rollout
- preStop hook: `sleep 10` to allow kube-proxy/ingress to stop routing before container terminates
- `terminationGracePeriodSeconds: 30` (10s sleep + 10s Go shutdown + 10s buffer)
- Backend image: `gcr.io/distroless/static-debian12:nonroot` is research recommendation, but existing Dockerfile uses `alpine:3.21` — use existing image, don't change Dockerfile

### Next.js frontend Deployment
- Image reference: uses existing `Dockerfile.web` (standalone output, HOSTNAME=0.0.0.0 already set)
- Configurable replicas (default 2)
- Build-time args (`NEXT_PUBLIC_*`) are baked into the image — ConfigMap documents values but doesn't inject them at runtime
- Runtime env: `NODE_ENV=production`, `PORT=3000` already in Dockerfile

### Health probes (frontend)
- Liveness probe: HTTP GET `/` on port 3000 (Next.js serves pages)
- Readiness probe: HTTP GET `/` on port 3000
- Startup probe: HTTP GET `/` with `failureThreshold: 30`, `periodSeconds: 2`

### Services
- Backend: ClusterIP Service on port 8080, named `backend`
- Frontend: ClusterIP Service on port 3000, named `frontend`
- Service names match what Dockerfile.web already expects (`REMOTE_API_URL=http://backend:8080`)

### Resource limits
- Backend: requests 100m CPU / 128Mi memory, limits 500m CPU / 512Mi memory
- Frontend: requests 100m CPU / 256Mi memory, limits 500m CPU / 512Mi memory (Node.js needs more memory)
- These are conservative starting points — tune after profiling

### Directory structure
- `k8s/base/backend/` — deployment.yaml, service.yaml, kustomization.yaml
- `k8s/base/frontend/` — deployment.yaml, service.yaml, kustomization.yaml
- Update `k8s/base/kustomization.yaml` to include both new directories

### Claude's Discretion
- Exact label selectors and metadata annotations
- Pod anti-affinity rules (if any)
- NODE_OPTIONS heap sizing for frontend
- Exact startup probe timing parameters

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- `Dockerfile`: Produces Go backend image with `server`, `multica`, `migrate` binaries on `alpine:3.21`
- `Dockerfile.web`: 3-stage build, standalone Next.js on `node:22-alpine`, already sets `HOSTNAME=0.0.0.0`
- `docker/entrypoint.sh`: Runs migrate + server — K8s decouples these (Job for migrate, Deployment for server)

### Established Patterns
- Backend reads all config from env vars: `DATABASE_URL`, `PORT`, `JWT_SECRET`, `RESEND_API_KEY`
- Backend has `/health` endpoint skipped by request logger middleware
- Backend handles SIGTERM gracefully with 10s context timeout
- Frontend `REMOTE_API_URL=http://backend:8080` is already the K8s-compatible default
- Frontend uses `STANDALONE=true` env to enable standalone output mode

### Integration Points
- Backend connects to PostgreSQL via `DATABASE_URL` — must reference `postgres.multica.svc.cluster.local`
- Frontend proxies API calls to backend via `REMOTE_API_URL` — must reference `backend.multica.svc.cluster.local:8080`
- Phase 1 ConfigMaps/Secrets already define these values — Deployments mount them via `envFrom`

</code_context>

<specifics>
## Specific Ideas

No specific requirements — auto mode. Key constraint: use existing Dockerfiles as-is; don't change application code or Dockerfiles. Manifests work with what's already built.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope (auto mode).

</deferred>

---

*Phase: 02-application-workloads*
*Context gathered: 2026-04-14*
