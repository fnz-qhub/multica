# Features Research: Kubernetes Manifests

**Domain:** Production Kubernetes deployment — Go backend + Next.js frontend + PostgreSQL (pgvector)
**Researched:** 2026-04-14
**Overall confidence:** HIGH (official Kubernetes docs + current community sources corroborating)

---

## Table Stakes

Features a deployment is unreliable or operationally broken without. Missing any of these means the cluster cannot safely run the stack.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Namespace isolation | Scopes all resources; prevents cross-environment bleed | Low | Single namespace per environment (e.g. `multica-prod`) |
| Deployment manifests — backend | Runs Go server; sets replica count, image, ports (8080) | Low | Include `imagePullPolicy: Always` for CD compatibility |
| Deployment manifests — frontend | Runs Next.js; sets replica count, image, ports (3000) | Low | **Must** set `HOSTNAME=0.0.0.0`; standalone output mode only |
| StatefulSet — PostgreSQL | Stateful workload with stable pod identity and volume binding | Medium | Use `pgvector/pgvector:pg17` image as constrained by project |
| PersistentVolumeClaim — database | Durable storage; data survives pod restarts and node failures | Low | `ReadWriteOnce`; size request matched to expected data growth |
| Service — ClusterIP (backend + DB) | Internal DNS for inter-service communication | Low | One per workload; exposes named ports |
| Service — LoadBalancer or Ingress entrypoint | External traffic ingress to frontend + backend API | Low–Medium | Ingress is preferred over raw LoadBalancer (see below) |
| Ingress with WebSocket support | gorilla/websocket requires HTTP upgrade; default NGINX supports it but needs tuned timeouts | Medium | Annotations: `proxy-read-timeout`, `proxy-send-timeout` (≥60s), `proxy-http-version: "1.1"` |
| ConfigMaps for non-sensitive config | Database host, app port, environment name, feature flags | Low | Separate ConfigMap per component |
| Secrets for sensitive config | DB credentials, JWT secrets, API keys — must not be in ConfigMap | Low | Native k8s Secrets acceptable for initial deploy; base64-encoded, not encrypted — acceptable when etcd encryption-at-rest is enabled by cluster operator |
| Liveness probe — all services | Detects crashed/deadlocked containers; triggers restart | Low | Use `/healthz` HTTP endpoint; **must not** check external deps (DB, cache) to avoid restart storms |
| Readiness probe — all services | Prevents traffic to unready pods during startup and rolling update | Low | Use `/ready` or `/readyz` HTTP endpoint; **may** check DB connectivity |
| Startup probe — backend | Prevents liveness from killing slow-starting Go binary during migration | Low | Covers the window between container start and app ready |
| Resource requests — all containers | Scheduler needs them for placement; without them, no QoS guarantee | Low | CPU: 100m–500m; memory: 128Mi–512Mi as starting point |
| Resource limits — all containers | Without limits, one runaway process starves the node | Low | Memory limit ≈ request (memory is non-compressible). CPU limit 2–4x request |
| Database init / migration job | Schema must exist before backend pods accept traffic | Medium | Kubernetes `Job` resource; backend init container waits on job completion before starting |

---

## Differentiators

Production hardening that distinguishes a reliable deployment from a toy one. Not strictly required for first boot, but expected within the first production iteration.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Ingress sticky sessions (cookie-based) | WebSocket reconnects land on the same pod; without this, multi-replica backend will drop in-flight connections on reconnect | Medium | NGINX Ingress annotation: `nginx.ingress.kubernetes.io/affinity: cookie`. Required when `replicas > 1` for backend |
| PodDisruptionBudget — backend | Prevents cluster upgrades/drain from taking down all backend replicas simultaneously | Low | `minAvailable: 1` or `maxUnavailable: 1`; requires `replicas >= 2` for it to be effective |
| Security context — non-root | Reduces container breakout blast radius | Low | `runAsNonRoot: true`, `runAsUser: 1000`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true` (needs writable `/tmp` emptyDir mount) |
| Dedicated ServiceAccounts per workload | Least-privilege identity; `automountServiceAccountToken: false` for workloads that don't call the k8s API | Low | Three accounts: `multica-backend`, `multica-frontend`, `multica-postgres` |
| NetworkPolicy — default deny + allow rules | Limits lateral movement; only backend can reach PostgreSQL on 5432 | Medium | Requires a CNI that enforces NetworkPolicy (Calico, Cilium, Weave). Not effective on all managed clusters |
| PostgreSQL operator (CloudNativePG) | Manages HA, failover, backups, and pgvector extension declaratively better than a raw StatefulSet | High | Bundled pgvector support in default operand image. Adds operator CRD dependency — defer unless HA is required at launch |
| Horizontal Pod Autoscaler — backend | Scales replicas under load without manual intervention | Medium | Out-of-scope per PROJECT.md; include as a stub with `minReplicas: 2, maxReplicas: 10` once baseline is stable |
| Pod anti-affinity — backend | Spreads replicas across nodes; prevents single-node failure taking out all replicas | Low | `preferredDuringSchedulingIgnoredDuringExecution` on hostname topology |
| Topology spread constraints | More granular than anti-affinity; distributes pods across zones | Low–Medium | Useful once cluster spans availability zones |
| Resource quotas per namespace | Prevents one deployment from consuming all cluster resources | Low | `ResourceQuota` object scoped to namespace |
| LimitRange defaults | Sets default requests/limits for any resource that omits them | Low | Protects against unguarded future additions |
| Image pull secrets | Required if registry is private (GitHub Container Registry, ECR, GCR) | Low | `regcred` Secret of type `kubernetes.io/dockerconfigjson` referenced in Deployment |
| Annotations for monitoring scrape | Exposes Go `/metrics` (Prometheus format) for cluster-level scraping | Low | `prometheus.io/scrape: "true"`, `prometheus.io/port: "8080"`, `prometheus.io/path: "/metrics"` |
| Init container for migration coordination | Blocks app containers until migration Job completes; prevents schema-mismatch crashes during rolling deploy | Medium | Init container polls Job status; main container starts only after success |
| `terminationGracePeriodSeconds` tuned | Allows in-flight WebSocket connections to drain before forced kill | Low | 30s default is usually sufficient; backend should handle SIGTERM and close connections |

---

## Anti-Features

Things to deliberately NOT build in the initial manifests.

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|-------------------|
| Helm chart packaging | Adds abstraction and tooling dependency before the manifest set is stable; harder to debug for new contributors | Plain YAML manifests first. Convert to Helm once the manifest shape is stable and templating is actually needed |
| Service mesh (Istio / Linkerd) | Significant operational complexity, per-pod sidecar overhead, steep learning curve — far exceeds needs of a 2–10 person team's initial deploy | NGINX Ingress handles TLS termination and routing; native NetworkPolicy handles segmentation |
| Multi-cluster federation | No current requirement; adds enormous operational surface area | Single cluster; re-evaluate when geographic distribution or DR requirements emerge |
| Autoscaling (HPA/VPA) at day one | Cannot set sensible thresholds without baseline load data; premature optimization leads to flapping | Fixed `replicas: 2` for backend; add HPA after observing real traffic patterns |
| External Secrets Operator (ESO) | Adds a cluster-wide operator with elevated privileges; requires a pre-existing external vault (AWS SM, Vault, etc.) | Native k8s Secrets with base64 encoding are acceptable if etcd encryption-at-rest is enabled. Add ESO when a secret rotation policy or compliance requirement demands it |
| CloudNativePG operator | Correct long-term choice for HA PostgreSQL, but adds a CRD dependency and operator lifecycle to manage from day one | Raw StatefulSet with `pgvector/pgvector:pg17` is sufficient for initial deploy. Migrate to CNPG operator when HA or automated failover is needed |
| Separate ingress per service | Proliferates Ingress objects and LoadBalancer IPs; increases cost and configuration surface | Single Ingress resource with path/host-based routing to both frontend and backend |
| DaemonSets for app workloads | Not appropriate for stateless API or frontend pods | Deployments for stateless workloads; StatefulSet only for PostgreSQL |
| CronJob for daemon process | `make daemon` is local-only per PROJECT.md | Keep daemon out of K8s entirely |

---

## Feature Dependencies

```
Namespace
└── All other resources (must exist first)

StatefulSet (postgres)
└── PersistentVolumeClaim
└── Service (ClusterIP, port 5432)
└── Secret (POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB)
└── ConfigMap (postgres config)

Migration Job
└── StatefulSet (postgres) must be Running
└── Secret (DB credentials)
└── ConfigMap (DB host/port)

Deployment (backend)
└── Init container → Migration Job complete
└── Service (ClusterIP, port 8080)
└── ConfigMap (backend env)
└── Secret (JWT secret, DB credentials)
└── ServiceAccount (multica-backend)
└── Liveness probe → /healthz endpoint in Go binary
└── Readiness probe → /readyz endpoint in Go binary
└── Startup probe → covers migration window

Deployment (frontend)
└── Service (ClusterIP, port 3000)
└── ConfigMap (NEXT_PUBLIC_API_URL etc.)
└── ServiceAccount (multica-frontend)
└── Liveness + Readiness probes → Next.js standalone /api/health or similar

Ingress
└── Service (backend) must exist
└── Service (frontend) must exist
└── TLS Secret (cert-manager or pre-provisioned)
└── Sticky session annotations (required when backend replicas > 1)

PodDisruptionBudget (backend)
└── Deployment (backend)
└── replicas >= 2 (minAvailable: 1 is meaningless with replicas: 1)

NetworkPolicy
└── Namespace
└── CNI plugin must support NetworkPolicy enforcement
```

### Critical ordering for first deploy

1. Namespace
2. Secrets + ConfigMaps
3. PostgreSQL StatefulSet + Service
4. Migration Job (waits for postgres ready)
5. Backend Deployment + Service (init container waits for migration job)
6. Frontend Deployment + Service
7. Ingress

---

## Multica-Specific Considerations

These arise from the project's constraints and are not generic Kubernetes patterns.

| Concern | Implication | Manifest Feature |
|---------|-------------|-----------------|
| `X-Workspace-ID` header routing | Backend must receive this header; Ingress must not strip it | Ingress annotation: `nginx.ingress.kubernetes.io/configuration-snippet` to preserve custom headers |
| gorilla/websocket real-time | WebSocket upgrade must pass through Ingress | NGINX Ingress WebSocket annotations + extended timeouts (120s minimum) |
| `pgvector/pgvector:pg17` image required | Cannot use standard `postgres:17` image | StatefulSet image pinned to `pgvector/pgvector:pg17`; init SQL: `CREATE EXTENSION IF NOT EXISTS vector;` |
| `pgvector` extension must be created | Extension is in image but not auto-enabled | PostgreSQL init ConfigMap with `CREATE EXTENSION IF NOT EXISTS vector;` mounted as `/docker-entrypoint-initdb.d/init.sql` |
| Next.js standalone mode | Image must be built with `output: 'standalone'` in `next.config.js` | Deployment uses standalone build; `HOSTNAME=0.0.0.0` env var required or pod health checks fail (pod unreachable on 127.0.0.1) |
| Multi-tenancy (all queries filter by workspace_id) | No K8s-level per-tenant isolation needed — handled in app code | Single namespace per environment is sufficient |

---

## Sources

- [Kubernetes Production Checklist 2026 — KubeLauncher](https://kubelauncher.com/kubernetes-production-checklist/)
- [Kubernetes Production Checklist: 40 Things — ATNO for DevOps Engineers, Mar 2026](https://medium.com/@atnofordevops/kubernetes-production-checklist-40-things-to-verify-before-going-live-5801943cf8d6)
- [Configure Liveness, Readiness and Startup Probes — kubernetes.io](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/)
- [Pod Security Standards — kubernetes.io](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [RBAC Good Practices — kubernetes.io](https://kubernetes.io/docs/concepts/security/rbac-good-practices/)
- [Specifying a Disruption Budget — kubernetes.io](https://kubernetes.io/docs/tasks/run-application/configure-pdb/)
- [WebSocket Kubernetes Ingress: NGINX, Traefik & HAProxy — websocket.org](https://websocket.org/guides/infrastructure/kubernetes/)
- [How to Configure WebSocket with Kubernetes Ingress, Jan 2026](https://oneuptime.com/blog/post/2026-01-24-websocket-kubernetes-ingress/view)
- [CloudNativePG + pgvector Recipe 18, Jun 2025](https://www.gabrielebartolini.it/articles/2025/06/cnpg-recipe-18-getting-started-with-pgvector-on-kubernetes-using-cloudnativepg/)
- [Deploy a PostgreSQL vector database on GKE — Google Cloud Docs](https://cloud.google.com/kubernetes-engine/docs/tutorials/deploy-pgvector)
- [How to Deploy PostgreSQL StatefulSet on Kubernetes — devopscube.com](https://devopscube.com/deploy-postgresql-statefulset/)
- [How to Run Database Migrations in Kubernetes — freecodecamp.org](https://www.freecodecamp.org/news/how-to-run-database-migrations-in-kubernetes/)
- [Kubernetes Secrets Management 2025 — Infisical](https://infisical.com/blog/kubernetes-secrets-management-2025)
- [Optimizing Next.js Docker Images with Standalone Mode — DEV Community](https://dev.to/angojay/optimizing-nextjs-docker-images-with-standalone-mode-2nnh)
- [Deploying Next.js to Kubernetes — Deni Bertovic](https://denibertovic.com/posts/deploying-nextjs-to-kubernetes-a-practical-guide-with-a-complete-devops-pipeline/)
- [Secrets of Self-hosting Next.js at Scale in 2025 — Sherpa.sh](https://www.sherpa.sh/blog/secrets-of-self-hosting-nextjs-at-scale-in-2025)
- [How to Implement Kubernetes RBAC Best Practices, Jan 2026](https://oneuptime.com/blog/post/2026-01-19-kubernetes-rbac-multi-tenant-best-practices/view)
- [How to implement securityContext runAsNonRoot, Feb 2026](https://oneuptime.com/blog/post/2026-02-09-security-context-runasnonroot/view)
