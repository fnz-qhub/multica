# Architecture Research: Kubernetes Manifests

**Project:** Multica K8s Manifests
**Researched:** 2026-04-14
**Confidence:** HIGH (pattern is well-established, multiple authoritative sources)

---

## Directory Structure

The recommended layout follows the **flat-per-service** pattern with Kustomize base/overlays for environment promotion. This keeps manifest depth under 4 levels (official guidance), groups resources by service, and supports `kubectl apply -f <dir>` for each component.

```
k8s/
├── namespace.yaml                  # Always first — everything else lands here
│
├── base/                           # Kustomize base (shared across environments)
│   ├── kustomization.yaml
│   │
│   ├── postgres/
│   │   ├── configmap.yaml          # POSTGRES_DB, POSTGRES_USER, PGDATA
│   │   ├── secret.yaml             # POSTGRES_PASSWORD (base64)
│   │   ├── headless-service.yaml   # ClusterIP: None — required for StatefulSet DNS
│   │   ├── service.yaml            # ClusterIP — stable endpoint for app pods
│   │   ├── statefulset.yaml        # pgvector/pgvector:pg17, volumeClaimTemplates
│   │   └── pvc.yaml                # (optional — or embedded in StatefulSet template)
│   │
│   ├── backend/
│   │   ├── configmap.yaml          # Non-secret env vars (DB host, port, feature flags)
│   │   ├── secret.yaml             # DB password ref, JWT secret, API keys
│   │   ├── deployment.yaml         # Go server, port 8080, liveness/readiness probes
│   │   └── service.yaml            # ClusterIP, port 8080
│   │
│   ├── frontend/
│   │   ├── configmap.yaml          # NEXT_PUBLIC_* vars, API base URL
│   │   ├── deployment.yaml         # Next.js, port 3000, liveness/readiness probes
│   │   └── service.yaml            # ClusterIP, port 3000
│   │
│   └── ingress/
│       └── ingress.yaml            # NGINX, TLS, WebSocket annotations, routing rules
│
└── overlays/
    ├── production/
    │   ├── kustomization.yaml      # Patches: replica counts, resource limits, image tags
    │   ├── backend-patch.yaml
    │   ├── frontend-patch.yaml
    │   └── postgres-patch.yaml
    └── staging/
        ├── kustomization.yaml
        └── ...patches
```

**Why Kustomize over raw duplication:** The project is plain-manifests-first (no Helm), but environment promotion (staging vs production) requires varying replica counts, resource limits, and image tags. Kustomize handles this without duplication. It is built into `kubectl` since 1.14 — no extra tooling needed.

**Why per-service subdirectories over one-file-per-resource:** Groups `kubectl apply -f k8s/base/postgres/` for incremental deployment and troubleshooting. Resources belonging to the same workload stay together.

---

## Component Breakdown

### Namespace

Single resource. Everything else uses `namespace: multica` (or `multica-production` for the overlay).

```yaml
kind: Namespace
metadata:
  name: multica
```

**Boundary:** Provides isolation; all other resources reference it. Deploy before anything else.

---

### PostgreSQL (StatefulSet)

The most structurally complex component. Five resources that must exist together:

| Resource | Kind | Purpose |
|---|---|---|
| `postgres/configmap.yaml` | ConfigMap | Non-secret DB config: `POSTGRES_DB`, `POSTGRES_USER`, `PGDATA` |
| `postgres/secret.yaml` | Secret | `POSTGRES_PASSWORD` — base64 encoded, never in ConfigMap |
| `postgres/headless-service.yaml` | Service (clusterIP: None) | Stable DNS for StatefulSet pods (`postgres-0.postgres`) |
| `postgres/service.yaml` | Service (ClusterIP) | Stable endpoint the backend uses: `postgres.multica.svc` |
| `postgres/statefulset.yaml` | StatefulSet | `pgvector/pgvector:pg17`, `volumeClaimTemplates` for PVCs |

**Image constraint:** Must use `pgvector/pgvector:pg17` — the pgvector extension is built into this image. Using a plain postgres image and trying to install the extension at runtime is unreliable in K8s.

**Storage:** `volumeClaimTemplates` inside the StatefulSet (not a standalone PVC) — each replica gets its own bound PVC with `accessModes: ReadWriteOnce`. This is a StatefulSet guarantee.

**Single replica for this project:** Multi-replica Postgres (HA) requires an operator (CloudNativePG, Patroni). The PROJECT.md excludes this complexity. Start with `replicas: 1`.

---

### Backend (Go server)

Three resources:

| Resource | Kind | Purpose |
|---|---|---|
| `backend/configmap.yaml` | ConfigMap | Non-secret config: `DATABASE_HOST`, `DATABASE_PORT`, `DATABASE_NAME` |
| `backend/secret.yaml` | Secret | DB password reference, JWT signing key, any API secrets |
| `backend/deployment.yaml` | Deployment | Chi/gorilla/websocket server at port 8080 |
| `backend/service.yaml` | Service (ClusterIP) | Internal cluster endpoint at port 8080 |

**Health probes on the Deployment:**
- `livenessProbe`: HTTP GET `/health` — restarts crashed pods
- `readinessProbe`: HTTP GET `/ready` — gates traffic until DB migrations complete

The backend must not receive traffic until it has a live DB connection. The readiness probe enforces this.

**WebSocket note:** The backend handles WebSocket upgrade internally (gorilla/websocket). The Service just passes TCP; the upgrade headers arrive from the Ingress. No special Service annotation needed.

---

### Frontend (Next.js)

| Resource | Kind | Purpose |
|---|---|---|
| `frontend/configmap.yaml` | ConfigMap | `NEXT_PUBLIC_API_URL`, `NEXT_PUBLIC_WS_URL` |
| `frontend/deployment.yaml` | Deployment | Next.js server at port 3000 |
| `frontend/service.yaml` | Service (ClusterIP) | Internal cluster endpoint at port 3000 |

**Important:** `NEXT_PUBLIC_*` vars are baked into the Next.js bundle at build time. They must be present when the Docker image is built, not just at runtime. This means the ConfigMap values inform the image build — they are also set as build-args in the Dockerfile. The ConfigMap is still useful for documentation and GitOps visibility, but it does not inject values at container start the way backend env vars do.

**Health probes:** HTTP GET `/` or a dedicated `/api/health` endpoint.

---

### Ingress

Single resource that routes all external traffic:

| Resource | Kind | Purpose |
|---|---|---|
| `ingress/ingress.yaml` | Ingress | NGINX controller, TLS termination, path-based routing, WebSocket annotations |

**Routing rules:**
- `/api/*` and `/ws/*` → backend Service (port 8080)
- `/*` → frontend Service (port 3000)

**WebSocket annotations (MEDIUM confidence — NGINX Ingress Controller specific):**

```yaml
annotations:
  nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
  nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
  nginx.ingress.kubernetes.io/proxy-http-version: "1.1"
  nginx.ingress.kubernetes.io/proxy-buffering: "off"
  nginx.ingress.kubernetes.io/configuration-snippet: |
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_cache off;
```

The default nginx timeout is 60 seconds — any long-lived WS connection will be silently dropped without the `3600` overrides.

**Sticky sessions:** If the backend scales beyond 1 replica, sticky sessions are required because WebSocket connections are stateful:

```yaml
nginx.ingress.kubernetes.io/affinity: "cookie"
nginx.ingress.kubernetes.io/affinity-mode: "persistent"
nginx.ingress.kubernetes.io/session-cookie-name: "multica-route"
nginx.ingress.kubernetes.io/session-cookie-max-age: "172800"
```

At `replicas: 1` (initial deploy), sticky sessions are redundant but harmless.

---

## Dependency Order

This is the order resources must be applied or be healthy before the next layer can function.

```
1. Namespace
   └── Must exist before any namespaced resource

2. Secrets + ConfigMaps (all services)
   └── Referenced by Pods — must exist before Deployments/StatefulSets

3. PostgreSQL headless Service
   └── Must exist before StatefulSet starts (DNS registration)

4. PostgreSQL StatefulSet
   └── Must be Ready (pod Running, PVC Bound) before backend can connect
   └── Run migrations before allowing backend traffic

5. Backend Deployment + Service
   └── Readiness probe gates traffic until DB connection is live
   └── Must be Running before frontend can make API calls at startup

6. Frontend Deployment + Service
   └── Can start in parallel with backend; fails gracefully until backend is ready

7. Ingress
   └── Apply last — no benefit to external traffic until backend + frontend are up
```

**Practical apply sequence:**

```bash
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/base/postgres/
kubectl rollout status statefulset/postgres -n multica
kubectl apply -f k8s/base/backend/
kubectl rollout status deployment/backend -n multica
kubectl apply -f k8s/base/frontend/
kubectl apply -f k8s/base/ingress/
```

Or with Kustomize for production:

```bash
kubectl apply -k k8s/overlays/production/
```

Kustomize applies all resources at once, but readiness probes on the backend enforce the DB dependency at the traffic-routing level.

---

## Networking Architecture

```
Internet
  │
  ▼
[LoadBalancer / NodePort]
  │
  ▼
[NGINX Ingress Controller]  ← TLS termination, WebSocket upgrade, routing
  │
  ├── /api/* + /ws/* ──────► [backend Service :8080]
  │                              │
  │                              ▼
  │                         [backend Pods]
  │                              │
  │                              ▼
  │                         [postgres Service :5432]
  │                              │
  │                              ▼
  │                         [postgres StatefulSet :5432]
  │                              │ (PVC)
  │                              ▼
  │                         [PersistentVolume]
  │
  └── /* ──────────────────► [frontend Service :3000]
                                 │
                                 ▼
                            [frontend Pods]
```

**Service type summary:**

| Service | Type | Why |
|---|---|---|
| postgres headless | ClusterIP (None) | StatefulSet DNS requirement |
| postgres | ClusterIP | Stable in-cluster endpoint for backend |
| backend | ClusterIP | Internal only; Ingress routes to it |
| frontend | ClusterIP | Internal only; Ingress routes to it |
| ingress-nginx | LoadBalancer | External entry point (cloud) or NodePort (bare metal) |

All application services are ClusterIP — nothing is directly exposed externally except through the Ingress.

**DNS resolution within cluster:**

- Backend connects to Postgres via: `postgres.multica.svc.cluster.local:5432`
- Frontend API calls at SSR time go to: `backend.multica.svc.cluster.local:8080`
- Browser API calls go through Ingress path routing (public URL)

---

## Build Order

This is the order to author the manifests, optimized so each phase is independently testable with `kubectl apply`.

**Phase 1 — Foundation**
1. `namespace.yaml` — validate cluster access and namespace isolation
2. `postgres/secret.yaml` and `postgres/configmap.yaml` — no cluster side effects
3. `postgres/headless-service.yaml` and `postgres/service.yaml`
4. `postgres/statefulset.yaml` — first real workload; validates storage class and PVC provisioning

**Phase 2 — Backend**
5. `backend/configmap.yaml` and `backend/secret.yaml`
6. `backend/deployment.yaml` — health probes configured here; validates DB connectivity
7. `backend/service.yaml`

**Phase 3 — Frontend**
8. `frontend/configmap.yaml`
9. `frontend/deployment.yaml` — health probes; validates Next.js image and runtime
10. `frontend/service.yaml`

**Phase 4 — Ingress**
11. `ingress/ingress.yaml` — WebSocket annotations, TLS config, path routing
    Requires NGINX Ingress Controller to already be installed in the cluster.

**Phase 5 — Kustomize wiring**
12. `base/kustomization.yaml` — lists all resources in the base
13. `overlays/production/kustomization.yaml` — image tag pins, replica patches, resource limit patches
14. `overlays/staging/kustomization.yaml`

**Rationale for this order:** Each phase produces runnable manifests that can be smoke-tested independently. Postgres comes before backend because the backend deployment depends on it via readiness probe (and practically via migration jobs). Ingress comes last because it is cluster-infrastructure-dependent (requires controller pre-installed) and serves no purpose until both services are healthy.

---

## Key Constraints and Decisions

| Decision | Rationale |
|---|---|
| StatefulSet for Postgres, not Deployment | Stable pod identity + stable PVC binding; required for any stateful workload |
| `pgvector/pgvector:pg17` image only | Extension is baked in; runtime install is unreliable |
| All services ClusterIP | Security — nothing exposed except via Ingress |
| Secrets separate from ConfigMaps | Passwords never in ConfigMaps (not encrypted at rest by default) |
| `readinessProbe` on backend | Prevents traffic before DB migrations complete |
| WebSocket timeout annotations at 3600s | Default nginx 60s timeout drops long-lived connections silently |
| Single postgres replica initially | HA requires operator (out of scope); add CloudNativePG later if needed |
| Kustomize for environments | Plain manifests first (no Helm), but environment promotion requires overlay patches |

---

## Sources

- [Kubernetes: Declarative Management with Kustomize](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/) — HIGH confidence
- [Ingress-NGINX annotations reference](https://github.com/kubernetes/ingress-nginx/blob/main/docs/user-guide/nginx-configuration/annotations.md) — HIGH confidence
- [WebSocket with Kubernetes Ingress configuration](https://oneuptime.com/blog/post/2026-01-24-websocket-kubernetes-ingress/view) — MEDIUM confidence
- [Deploy PostgreSQL StatefulSet on Kubernetes](https://devopscube.com/deploy-postgresql-statefulset/) — MEDIUM confidence
- [Kubernetes best practices 2025](https://kodekloud.com/blog/kubernetes-best-practices-2025/) — MEDIUM confidence
- [PostgreSQL on Kubernetes — operators vs StatefulSets](https://opsmoon.com/blog/postgres-in-kubernetes/) — MEDIUM confidence
- [Deploy pgvector on GKE](https://cloud.google.com/kubernetes-engine/docs/tutorials/deploy-pgvector) — HIGH confidence (Google official docs)
- [NGINX sticky sessions](https://kubernetes.github.io/ingress-nginx/examples/affinity/cookie/) — HIGH confidence (official ingress-nginx docs)
