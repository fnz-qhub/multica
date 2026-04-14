# Stack Research: Kubernetes Manifests

**Project:** Multica Kubernetes Manifests
**Researched:** 2026-04-14
**Scope:** Plain manifest production deployment — Go backend (port 8080), Next.js frontend (port 3000), PostgreSQL with pgvector

---

## Recommended Stack

### Core Resource Types

| Resource | apiVersion | Purpose |
|----------|-----------|---------|
| Namespace | v1 | Isolate all Multica workloads per environment |
| Deployment | apps/v1 | Go backend, Next.js frontend (stateless, rolling update) |
| StatefulSet | apps/v1 | PostgreSQL (ordered restart, stable network identity, PVC binding) |
| Service | v1 | Internal ClusterIP for all pods; LoadBalancer or NodePort for ingress controller |
| Ingress | networking.k8s.io/v1 | External HTTP/HTTPS routing, WebSocket upgrade |
| ConfigMap | v1 | Non-secret environment config (ports, URLs, feature flags) |
| Secret | v1 | Passwords, JWT secret, API keys, DB credentials |
| PersistentVolumeClaim | v1 | PostgreSQL data directory |
| ServiceAccount | v1 | Least-privilege identity per workload |
| PodDisruptionBudget | policy/v1 | Minimum availability during node drains / rolling upgrades |

**Note:** `extensions/v1beta1` and `networking.k8s.io/v1beta1` for Ingress are removed since Kubernetes 1.22. Use `networking.k8s.io/v1` exclusively. `policy/v1beta1` for PDB is removed since 1.25 — use `policy/v1`.

---

## Resource Types (Detailed Rationale)

### Workload Resources

**Deployment (apps/v1) — backend and frontend**

Use RollingUpdate strategy for zero-downtime deploys:

```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxUnavailable: 0    # never reduce below desired count
    maxSurge: 1          # allow one extra pod during rollout
```

`maxUnavailable: 0` is critical for the backend because WebSocket connections are long-lived — you do not want to kill the old pod before the new one is ready.

**StatefulSet (apps/v1) — PostgreSQL**

StatefulSet over Deployment because:
- Provides stable, predictable pod names (`postgres-0`, `postgres-1`) required for primary/replica replication if added later
- PVC lifecycle is tied to the pod — data survives pod restarts
- Ordered startup/teardown prevents split-brain scenarios

**PodDisruptionBudget (policy/v1)**

Required for any Deployment with more than one replica to ensure cluster upgrades do not take all pods offline simultaneously:

```yaml
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: multica-backend
```

### Networking

**Service (v1) — ClusterIP for internal, LoadBalancer/NodePort for ingress controller only**

- Backend: ClusterIP on port 8080 — accessed only through ingress, never directly
- Frontend: ClusterIP on port 3000 — accessed only through ingress
- PostgreSQL: ClusterIP on port 5432 — no ingress, backend-only access
- Headless service (`clusterIP: None`) for PostgreSQL StatefulSet: required for stable DNS (`postgres-0.postgres.namespace.svc.cluster.local`)

**Ingress (networking.k8s.io/v1) — ingress-nginx**

ingress-nginx is the recommended ingress controller for plain-manifest deployments. It is:
- The most widely deployed open-source ingress controller (CNCF project)
- Supports WebSocket upgrade headers natively
- Supports cookie-based sticky sessions required for WebSocket connections when running multiple backend replicas
- Installed once per cluster via official manifests; no Helm required

WebSocket-specific annotations required on the backend Ingress:

```yaml
annotations:
  nginx.ingress.kubernetes.io/proxy-http-version: "1.1"
  nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
  nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
  nginx.ingress.kubernetes.io/proxy-connect-timeout: "60"
  # Sticky sessions for multi-replica WebSocket
  nginx.ingress.kubernetes.io/affinity: "cookie"
  nginx.ingress.kubernetes.io/affinity-mode: "persistent"
  nginx.ingress.kubernetes.io/session-cookie-name: "MULTICA_WS_ROUTE"
  nginx.ingress.kubernetes.io/session-cookie-max-age: "172800"
```

**Why sticky sessions:** Multica uses gorilla/websocket for real-time. WebSocket connections are stateful — once established, all frames for that connection must go to the same backend pod. Cookie affinity ensures reconnects land on the same pod. If running a single backend replica initially, this is not strictly required but is a zero-cost configuration that prevents breakage when replicas are added.

### Configuration

**ConfigMap** — non-sensitive values from `.env.example`:
- `PORT`, `FRONTEND_PORT`, `MULTICA_APP_URL`, `ALLOWED_ORIGINS`
- `MULTICA_SERVER_URL`, `NEXT_PUBLIC_API_URL`, `NEXT_PUBLIC_WS_URL`

**Secret** — sensitive values, base64-encoded in manifest (or managed externally):
- `DATABASE_URL`, `POSTGRES_PASSWORD`, `JWT_SECRET`
- `RESEND_API_KEY`, `GOOGLE_CLIENT_SECRET`
- `S3_BUCKET`, `CLOUDFRONT_PRIVATE_KEY`, `CLOUDFRONT_KEY_PAIR_ID`

Native Kubernetes Secrets are stored unencrypted in etcd by default. For a first production deployment with plain manifests, this is acceptable if you restrict etcd access and enable RBAC. For mature deployments, External Secrets Operator (ESO) integrating with AWS Secrets Manager, GCP Secret Manager, or HashiCorp Vault is the standard path. This is out of scope for the initial manifest set but should be documented as a follow-up.

### Storage

**PersistentVolumeClaim (v1) — PostgreSQL**

```yaml
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
  storageClassName: standard  # cluster-specific — override per environment
```

`ReadWriteOnce` is correct for a single-primary PostgreSQL setup. The storage class name is environment-specific — document this as a parameter to set per cluster.

---

## Container Strategy

### Go Backend

**Multi-stage Dockerfile: builder + distroless/static-debian12**

Stage 1 (builder): `golang:1.26-alpine` — compile with `CGO_ENABLED=0 GOOS=linux` and `-ldflags="-w -s"` to produce a static binary.

Stage 2 (runtime): `gcr.io/distroless/static-debian12:nonroot`

Why distroless over scratch:
- Google patches and rebuilds distroless images — you get library CVE fixes by pulling the latest tag
- Includes CA certificates (required for HTTPS calls to Resend, Google OAuth, S3/CloudFront)
- Includes timezone data
- Runs as nonroot by default (UID 65532) — satisfies `runAsNonRoot: true` without extra configuration
- No shell — reduces attack surface, prevents exec-based exploits

Expected final image size: 10–20 MiB.

Security context for the Go backend pod:

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 65532
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]
```

### Next.js Frontend

**Multi-stage Dockerfile: deps + builder + runner**

Stage 1 (deps): `node:22-alpine` — install production + dev deps with `pnpm install --frozen-lockfile`

Stage 2 (builder): `node:22-alpine` — `pnpm build` with `output: 'standalone'` in `next.config.ts`

Stage 3 (runner): `node:22-alpine` — copy `.next/standalone`, `.next/static`, `public/`. Run with `node server.js`.

Why standalone output:
- Bundles only the files and Node modules actually needed at runtime
- Reduces image size from ~1 GB to ~150–250 MiB
- No package manager needed in the runtime image

`next.config.ts` must include:

```typescript
output: 'standalone'
```

Node.js heap for Next.js in Kubernetes — set environment variable in the Deployment:

```yaml
env:
  - name: NODE_OPTIONS
    value: "--max-old-space-size=384"  # 75% of memory limit
```

This prevents OOM kills. Size relative to the memory limit set on the container.

Security context for the Next.js pod: run as UID 1001 (node user in alpine). No `readOnlyRootFilesystem` — Next.js writes temp files to the filesystem.

### PostgreSQL

**Image: `pgvector/pgvector:pg17`** (as required by PROJECT.md constraints)

This is the community image that pre-installs the pgvector extension on top of the official PostgreSQL 17 image. It is the same image used in the local Docker Compose setup, so there is no drift between local and production.

For Kubernetes deployment, the project spec calls for plain StatefulSet manifests (no operator). The pgvector/pgvector:pg17 image works directly in a StatefulSet without any operator. The tradeoff vs. CloudNativePG:

| Approach | Pros | Cons |
|----------|------|------|
| StatefulSet + pgvector/pgvector:pg17 | Zero new CRDs, matches local dev image, simple | Manual backup, no HA, manual failover |
| CloudNativePG operator | HA, automated failover, pgvector bundled | Requires operator install, new CRDs, more complexity |

**Decision: StatefulSet + pgvector/pgvector:pg17.** The PROJECT.md explicitly requires this image and calls for plain manifests. CloudNativePG is the right next step when HA becomes a requirement.

---

## Health Checks

All three services require probes. The pattern is:

**Startup probe:** Longer tolerance for slow initial startup. Prevents liveness probe from killing a container that is still initializing.

**Readiness probe:** Fails when the service cannot handle traffic (DB not connected, cache warming). Controls whether traffic is routed to the pod.

**Liveness probe:** Fails only when the process is stuck (deadlock, OOM state). Simpler check than readiness. Triggers pod restart.

### Go Backend (/healthz endpoint)

The Go server should expose a `/healthz` endpoint. Liveness: lightweight (return 200). Readiness: check DB connection.

```yaml
startupProbe:
  httpGet:
    path: /healthz
    port: 8080
  failureThreshold: 30
  periodSeconds: 5
readinessProbe:
  httpGet:
    path: /healthz
    port: 8080
  initialDelaySeconds: 5
  periodSeconds: 10
  failureThreshold: 3
livenessProbe:
  httpGet:
    path: /healthz
    port: 8080
  initialDelaySeconds: 15
  periodSeconds: 20
  failureThreshold: 3
```

### Next.js Frontend

Next.js 13+ exposes a built-in health route at `/api/health` (or use the custom pages router). For App Router, create `app/api/health/route.ts` returning 200.

Same probe structure as backend, hitting port 3000.

### PostgreSQL

Use `exec` probe (pg_isready) — no HTTP server:

```yaml
readinessProbe:
  exec:
    command: ["pg_isready", "-U", "multica", "-d", "multica"]
  initialDelaySeconds: 10
  periodSeconds: 5
livenessProbe:
  exec:
    command: ["pg_isready", "-U", "multica", "-d", "multica"]
  initialDelaySeconds: 30
  periodSeconds: 10
```

---

## Resource Requests and Limits

Starting values based on Go and Next.js characteristics. These are intentionally conservative — instrument with metrics-server and tune after first deployment.

| Service | CPU Request | CPU Limit | Memory Request | Memory Limit |
|---------|------------|-----------|---------------|--------------|
| Go backend | 100m | 500m | 128Mi | 256Mi |
| Next.js frontend | 100m | 500m | 256Mi | 512Mi |
| PostgreSQL | 250m | 1000m | 512Mi | 1Gi |

**Rationale:**
- Go is memory-efficient — 128Mi request is conservative headroom above idle
- Next.js Node.js process is heavier — 256Mi request. Set `NODE_OPTIONS=--max-old-space-size=384` (75% of 512Mi limit)
- PostgreSQL: generous limits because shared_buffers and work_mem benefit from memory headroom
- CPU limits: set higher than requests to allow burst. Never set CPU limit too tight on Go — the runtime uses goroutines that can burst
- Memory limits are hard caps — OOM kills happen at the limit. Memory request should be at or above the typical high-water mark

---

## What NOT to Use

### Do NOT use: Helm (for this milestone)

PROJECT.md explicitly scopes this out: "plain manifests first, Helm later if needed." Helm adds templating complexity, chart versioning, and requires Helm CLI on the cluster. Plain YAML is easier to read, audit, and debug. Kustomize is the right graduation path when environment overlays (staging/prod) are needed.

### Do NOT use: Kustomize (initially)

Kustomize is built into kubectl since 1.14 and is the right tool once you have multiple environments. For a single-cluster initial deployment, it adds a layer of indirection that makes manifests harder to understand. Start with plain manifests, add kustomize overlays when the second environment appears.

### Do NOT use: CloudNativePG operator

The constraint is `pgvector/pgvector:pg17` (matches local dev). CloudNativePG uses its own operand images — you would need to build a custom image layering pgvector on top. The StatefulSet approach directly uses the required image with zero operator overhead.

### Do NOT use: deprecated API versions

- Never `extensions/v1beta1` — removed in 1.16 (NetworkPolicy) and 1.22 (Ingress)
- Never `networking.k8s.io/v1beta1` — removed in 1.22
- Never `policy/v1beta1` — removed in 1.25
- Never `apps/v1beta1` or `apps/v1beta2` — removed in 1.16

### Do NOT use: naked Pods

Never define a `Pod` resource directly in production manifests. Always use Deployment (stateless) or StatefulSet (stateful). Naked Pods are not rescheduled on node failure.

### Do NOT use: `latest` image tags

Always pin to a specific image digest or version tag. `latest` makes deployments non-reproducible and breaks rollback.

### Do NOT use: `hostNetwork: true` or `hostPID: true`

These bypass Kubernetes networking isolation and are security anti-patterns for application workloads.

### Do NOT use: requests without limits (or limits without requests)

Setting only limits creates a Burstable QoS class — the pod can be OOM-killed during node pressure. Setting only requests with no limits allows runaway resource consumption. Both must be set.

### Do NOT use: Ingress without TLS in production

The Ingress should terminate TLS. Use cert-manager with Let's Encrypt for automated certificate provisioning. Plain HTTP is acceptable for an initial internal cluster deployment but must not reach the internet.

---

## Confidence Levels

| Area | Confidence | Basis |
|------|-----------|-------|
| API versions (apps/v1, networking.k8s.io/v1, policy/v1) | HIGH | Official Kubernetes deprecation guide confirms these are current stable versions |
| ingress-nginx for WebSocket + sticky sessions | HIGH | Official ingress-nginx docs confirm cookie affinity and WebSocket timeout annotations |
| pgvector/pgvector:pg17 StatefulSet | HIGH | Matches project constraint; standard StatefulSet pattern, well documented |
| distroless/static-debian12 for Go | HIGH | Google distroless GitHub, multiple authoritative comparisons confirm pattern |
| Next.js standalone output in Dockerfile | HIGH | Official Next.js deployment docs confirm `output: 'standalone'` for containers |
| Resource requests/limits values | MEDIUM | Conservative starting values based on general Go/Node.js guidance; actual values need profiling |
| NODE_OPTIONS heap sizing | MEDIUM | Verified from vercel/next.js GitHub discussion and multiple community sources |
| Secret management (plain Secrets vs ESO) | MEDIUM | Plain Secrets are correct for initial deployment; ESO recommendation is community-standard but not yet validated for this cluster |

---

## Sources

- [Kubernetes Deprecated API Migration Guide](https://kubernetes.io/docs/reference/using-api/deprecation-guide/)
- [Kubernetes Configuration Good Practices](https://kubernetes.io/blog/2025/11/25/configuration-good-practices/)
- [Kubernetes Resource Management](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/)
- [Kubernetes Liveness, Readiness, Startup Probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/)
- [Kubernetes Secrets Good Practices](https://kubernetes.io/docs/concepts/security/secrets-good-practices/)
- [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [ingress-nginx WebSocket Configuration](https://websocket.org/guides/infrastructure/kubernetes/)
- [ingress-nginx Sticky Sessions](https://kubernetes.github.io/ingress-nginx/examples/affinity/cookie/)
- [CNPG Recipe 18: pgvector on Kubernetes](https://www.gabrielebartolini.it/articles/2025/06/cnpg-recipe-18-getting-started-with-pgvector-on-kubernetes-using-cloudnativepg/)
- [PostgreSQL on Kubernetes: Deployment Methods](https://cicube.io/blog/postgres-kubernetes/)
- [Next.js Deploying to Kubernetes](https://denibertovic.com/posts/deploying-nextjs-to-kubernetes-a-practical-guide-with-a-complete-devops-pipeline/)
- [Next.js Official Deployment Docs](https://nextjs.org/docs/app/building-your-application/deploying)
- [Google Distroless Images](https://github.com/GoogleContainerTools/distroless)
- [Alpine vs Distroless vs Scratch (2025)](https://medium.com/google-cloud/alpine-distroless-or-scratch-caac35250e0b)
- [Kubernetes Secrets Management 2025](https://infisical.com/blog/kubernetes-secrets-management-2025)
- [PodDisruptionBudget and Rollout Strategies](https://www.flightcrew.io/blog/pdb-rollout-guide)
- [Next.js OOM in Kubernetes discussion](https://github.com/vercel/next.js/discussions/46873)
