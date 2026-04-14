# Pitfalls Research: Kubernetes Manifests

**Project:** Multica Kubernetes Manifests
**Stack:** Go backend (Chi + gorilla/websocket) + Next.js frontend + PostgreSQL pgvector/pg17
**Researched:** 2026-04-14
**Overall confidence:** HIGH (verified against official K8s docs + multiple community post-mortems)

---

## Critical Mistakes

### CRIT-1: WebSocket connections silently drop after 60 seconds

**What goes wrong:** NGINX Ingress (and most ingress controllers) default `proxy-read-timeout` and `proxy-send-timeout` to 60 seconds. Once a WebSocket is upgraded, it is a long-lived TCP connection with no HTTP activity. The ingress proxy sees no bytes for 60 seconds and closes the connection. The gorilla/websocket client reconnects, but the user experiences visible disconnection. This is invisible in logs — there is no error, just a closed connection.

**Why it happens:** WebSocket connections are not HTTP request/response cycles. Default HTTP proxy timeouts are designed for short-lived requests, not persistent connections.

**Consequences:** Real-time features (live issue updates, agent status changes) drop silently every minute. Users see stale state until they reload.

**Prevention:**
- Set on the Ingress resource:
  ```yaml
  nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
  nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
  ```
- Also ensure `proxy-http-version: "1.1"` and the `Connection: upgrade` / `Upgrade` headers pass through.

**Warning signs:** WebSocket clients reconnecting every ~60 seconds, users reporting "live updates stop working."

**Phase:** Must be addressed in initial Ingress/networking manifest — cannot be patched later without downtime.

---

### CRIT-2: Next.js NEXT_PUBLIC_ variables baked at build time, not injected at runtime

**What goes wrong:** `NEXT_PUBLIC_` environment variables are inlined at `next build` time into the emitted JavaScript bundle. When you build a Docker image and then inject env vars via Kubernetes ConfigMap at runtime, `NEXT_PUBLIC_API_URL` etc. remain the empty string or whatever was set during the Docker build — they do not pick up the pod's environment.

**Why it happens:** Next.js replaces `process.env.NEXT_PUBLIC_*` references with literal string values during compilation, not at runtime. This is a fundamental Next.js design decision, not a Kubernetes problem.

**Consequences:** The frontend points to the wrong API URL (or no URL) in every environment that isn't the build environment. All API calls fail silently. Especially painful when promoting the same image from staging to production.

**Prevention:**
- Server-side env vars (no `NEXT_PUBLIC_` prefix) work correctly at runtime for server components and API routes.
- For values needed client-side, expose them via a Next.js App Router server component that reads `process.env` at render time and injects them into a client component, or expose them via `/api/config` that client code fetches once.
- Alternatively, use `next.config.js` `publicRuntimeConfig` (deprecated in App Router; use carefully).
- Do NOT attempt to inject `NEXT_PUBLIC_*` vars via ConfigMap at runtime — it does not work without rebuilding the image.

**Warning signs:** Frontend shows blank pages or network errors immediately after deployment; behavior differs between environments despite identical manifests.

**Phase:** Must be resolved before the first functional Next.js deployment manifest is written.

---

### CRIT-3: Liveness probe depends on database connectivity — causes restart storm during DB outages

**What goes wrong:** A liveness probe that calls `/healthz` and that endpoint checks PostgreSQL connectivity will kill and restart all application pods when the database is temporarily unavailable (maintenance, failover, restart). This converts a recoverable DB hiccup into a complete service outage.

**Why it happens:** The intent is "if the app can't reach the DB, restart it." The reality is: the app is not broken, the DB is temporarily unavailable. Restarting pods does not fix the DB. Kubernetes keeps restarting pods (CrashLoopBackOff) making things worse.

**Consequences:** A 30-second DB restart causes a 5+ minute application outage as all pods enter CrashLoopBackOff.

**Prevention:**
- Liveness: lightweight check only — "is my process alive and not deadlocked?" (e.g., `GET /livez` returns 200 if the process is running).
- Readiness: checks real dependencies including DB connectivity. A failing readiness probe removes the pod from service without restarting it.
- Use separate `/livez` and `/readyz` endpoints. `/readyz` checks DB; `/livez` does not.
- Set `initialDelaySeconds` long enough (30–60s) for DB connection pools to initialize.

**Warning signs:** Pods going into CrashLoopBackOff during any DB maintenance; pods restarting on DB connection errors.

**Phase:** Health check manifest block — initial manifest phase.

---

### CRIT-4: PostgreSQL runs as a Deployment instead of a StatefulSet — data loss on rescheduling

**What goes wrong:** Using `kind: Deployment` for PostgreSQL means pods get random names, can be scheduled on any node, and — critically — PVC binding behavior is undefined. If the pod is rescheduled to a different node, it may not re-attach to its original PVC. Data is either inaccessible or lost.

**Why it happens:** Developers familiar with stateless Deployments use the same pattern for databases. Deployment works fine until the first node failure or pod eviction.

**Consequences:** Database pod reschedules to a different node; PVC does not follow; PostgreSQL starts with an empty data directory. All data gone.

**Prevention:**
- Use `kind: StatefulSet` with `volumeClaimTemplates`. This guarantees a stable pod name (`postgres-0`) and stable PVC binding.
- Set `persistentVolumeReclaimPolicy: Retain` on the StorageClass to prevent accidental data deletion when the StatefulSet is deleted.
- Never set `replicas > 1` on the PostgreSQL StatefulSet without a proper replication operator (see PITFALL PSQL-1).

**Warning signs:** PostgreSQL pod name changing after restarts; mounting a PVC to a "fresh" pod with no data.

**Phase:** Database StatefulSet manifest — foundational, must be correct before any data is written.

---

### CRIT-5: Kubernetes Secrets stored as plain YAML in version control

**What goes wrong:** Secret manifests in YAML encode values as base64 — not encryption. Committing `postgres-secret.yaml` to the git repository exposes all credentials. Base64 is decodable in one command. Automated bots scan GitHub and exploit exposed credentials within hours.

**Why it happens:** The workflow "create manifest, apply it, commit it" treats Secrets like ConfigMaps. The false assumption is that base64 = protection.

**Consequences:** Database credentials, JWT signing keys, API tokens exposed publicly. Full data compromise possible.

**Prevention for plain-manifests project:**
- Never commit Secret YAML files with real values. Use placeholder values (`REPLACE_ME`) in committed files with a documented rotation step.
- Alternatively use `kubeseal` (Sealed Secrets) — encrypt before committing, decrypt only in-cluster.
- Add `*-secret.yaml` and `secrets*.yaml` to `.gitignore`.
- Document the secret injection process in a runbook, separate from the manifest files.

**Warning signs:** Git history containing base64 blobs; `.env` values copied into manifests; "secrets" folder not in `.gitignore`.

**Phase:** Must be addressed in the ConfigMaps/Secrets manifest phase before any real values are used.

---

## Common Oversights

### OV-1: Missing resource requests and limits — noisy neighbor OOMKill

**What goes wrong:** Without `resources.requests` and `resources.limits`, pods have no quality-of-service class. The Go backend or Next.js process can consume all node memory and trigger OOMKill of adjacent pods. The Go runtime has a growing heap; Next.js server-side rendering is memory-hungry under load.

**Prevention:**
- Set requests from observed baseline, limits at 1.5–2x observed peak.
- Memory limit = memory request (Guaranteed QoS) for critical pods like the backend.
- CPU limits are optional but set them to prevent one runaway build from starving the backend.
- CPU limit failures are silent — the process just runs slower, no error emitted.
- Set init container resources separately from main container resources.

**Warning signs:** Pods randomly OOMKilled with no application error; sporadic slowdowns with no obvious cause.

**Phase:** All Deployment/StatefulSet manifests.

---

### OV-2: No preStop hook — gorilla/websocket connections cut mid-message during deployments

**What goes wrong:** When Kubernetes terminates a pod during a rolling update, it simultaneously removes the pod from the Endpoints list (stops routing new traffic) AND sends SIGTERM. These two events race. The ingress/kube-proxy may still route new WebSocket connections to the terminating pod for a few seconds after SIGTERM is sent. Those connections are immediately cut.

**Why it happens:** Endpoint propagation through kube-proxy and ingress is asynchronous and can lag by 5–15 seconds. There is no coordination between "stop routing" and "stop the process."

**Prevention:**
- Add a `lifecycle.preStop` hook with a `sleep 10` (or longer) before SIGTERM effectively terminates the process. This gives kube-proxy and ingress time to remove the pod from rotation.
- Set `terminationGracePeriodSeconds` to at least 30 seconds (default) but longer if WebSocket sessions have meaningful in-flight state.
- The Go backend must handle SIGTERM gracefully: stop accepting new connections, wait for existing goroutine handlers to finish, then exit.

**Warning signs:** Users seeing dropped connections or "connection reset" errors during deployments.

**Phase:** Deployment manifests for the Go backend.

---

### OV-3: maxUnavailable defaults cause brief downtime on single-replica deployments

**What goes wrong:** If the Go backend or Next.js frontend is deployed with `replicas: 1` (common starting point), the default `maxUnavailable: 25%` rounds down to 0, but `maxSurge: 25%` rounds up to 1. This means a surge pod is created before the old is removed. However, if cluster resources are tight and the surge pod cannot be scheduled, the rolling update stalls indefinitely.

**Prevention:**
- For `replicas: 1`, explicitly set `maxSurge: 1` and `maxUnavailable: 0` to get zero-downtime behavior when resources are available.
- Or accept brief downtime with `maxUnavailable: 1` and `maxSurge: 0` (safer under resource pressure).
- Add `minReadySeconds: 10` so a new pod must pass readiness for 10 seconds before the old one is terminated.

**Warning signs:** Deployment update stalls at 0/1 updated; "Insufficient CPU/memory" events during rollout.

**Phase:** All Deployment manifests.

---

### OV-4: Go backend deployment missing `X-Workspace-ID` header passthrough at ingress

**What goes wrong:** The Multica backend uses `X-Workspace-ID` for multi-tenant routing. Some ingress controllers strip non-standard headers by default, or WAFs/load balancers in front of the cluster drop unfamiliar headers. Requests arrive at the backend without `X-Workspace-ID`, causing 400/403 errors for all requests.

**Prevention:**
- Verify the ingress controller passes custom headers through to the backend (NGINX Ingress does by default, but verify).
- If a WAF or cloud load balancer sits in front, explicitly configure it to pass `X-Workspace-ID`.
- Add a backend integration test that asserts multi-tenant routing works end-to-end through the actual ingress.

**Warning signs:** All workspace-scoped API calls return 400/403; requests succeed when calling the backend Service directly but fail through ingress.

**Phase:** Ingress/networking manifest.

---

### OV-5: NetworkPolicy absent — all pods can communicate freely

**What goes wrong:** Without NetworkPolicy, any pod in the cluster (including a compromised one) can reach the PostgreSQL pod directly. The database is not logically isolated to only the backend pods.

**Prevention:**
- Add a default-deny NetworkPolicy to the namespace.
- Add explicit allow rules: backend pods can reach postgres on port 5432; frontend pods can reach backend on port 8080; nothing else is permitted except DNS (port 53 UDP).
- Note: NetworkPolicy requires a CNI that supports it (Calico, Cilium, Weave). Flannel does not enforce NetworkPolicies — manifests are silently ignored.

**Warning signs:** Any pod can `kubectl exec` curl into the postgres Service; no CNI enforcement configured.

**Phase:** Namespace and networking manifests.

---

### OV-6: Single-replica backend with sticky sessions breaks WebSocket horizontal scaling

**What goes wrong:** If the backend is eventually scaled to multiple replicas, gorilla/websocket connections are stateful and scoped to the pod they connected to. Without sticky sessions, a reconnecting client may land on a different pod that has no knowledge of the prior session. If the application broadcasts messages via in-memory pub/sub (not a message queue), messages are silently dropped for clients on other pods.

**Prevention for current scope (single deployment):**
- Document that horizontal scaling of the Go backend requires either: (a) sticky session affinity in the ingress (`nginx.ingress.kubernetes.io/affinity: cookie`), or (b) a Redis pub/sub layer for message fan-out across pods.
- For the initial single-pod deployment, this is not a problem — but the manifest structure should note the constraint so it is not blindly scaled.

**Warning signs:** After scaling backend replicas > 1, some WebSocket clients stop receiving updates; messages delivered inconsistently.

**Phase:** Document in Ingress/backend Deployment manifests as a comment constraint.

---

## PostgreSQL / pgvector Specific

### PSQL-1: Running pgvector with replicas > 1 using a plain StatefulSet causes split-brain

**What goes wrong:** The pgvector extension does not have cluster-aware logic. If you set `replicas: 2` on a PostgreSQL StatefulSet, each pod gets its own PVC. Pod 0 and Pod 1 do NOT share data. Tables created on pod 0 (including vector columns) do not exist on pod 1. `CREATE EXTENSION vector` on the secondary can hang indefinitely. This is documented in the pgvector GitHub issue tracker.

**Why it happens:** A StatefulSet with multiple replicas is not the same as database replication. Each pod is an independent PostgreSQL instance with its own storage.

**Consequences:** Silent data divergence; vector search queries fail or return empty results depending on which pod serves the request.

**Prevention:**
- Run `replicas: 1` on the PostgreSQL StatefulSet for this project's initial scope.
- If HA is later required, use CloudNativePG operator (ships with pgvector bundled) which provides proper streaming replication with pgvector support.
- Never scale the StatefulSet replica count without first setting up proper streaming replication.

**Warning signs:** Inconsistent query results; `CREATE EXTENSION vector` hanging; tables missing on some pods.

**Phase:** PostgreSQL StatefulSet manifest — foundational constraint.

---

### PSQL-2: PVC reclaim policy defaults to Delete — StatefulSet deletion destroys all data

**What goes wrong:** The default `persistentVolumeReclaimPolicy` on many StorageClasses is `Delete`. When the StatefulSet is deleted (e.g., during a namespace teardown, accidental `kubectl delete statefulset postgres`), the PVC is also deleted, and the PV is released and destroyed. All database data is permanently lost.

**Prevention:**
- Set the StorageClass `reclaimPolicy: Retain` or patch the PV directly after creation: `kubectl patch pv <pv-name> -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'`.
- Add a note in the StatefulSet manifest: "Do not delete this StatefulSet without first backing up the PVC."
- Consider adding a PVC protection annotation or PodDisruptionBudget to prevent accidental deletion.

**Warning signs:** PV disappears after StatefulSet deletion; StorageClass shows `reclaimPolicy: Delete`.

**Phase:** PostgreSQL StatefulSet and PVC manifests.

---

### PSQL-3: PostgreSQL init container for migrations runs on every pod restart, not just initial deploy

**What goes wrong:** A common pattern is an init container that runs `migrate-up` before the main container starts. If the init container runs on every pod restart (not just initial creation), it can cause issues: concurrent migration attempts if multiple pods restart simultaneously, or migration failures treated as init container failures that block pod startup.

**Prevention:**
- Use a Kubernetes `Job` (not an init container) for database migrations. The Job runs once and is retried on failure, but not on every pod restart.
- Alternatively, make migrations idempotent and safe to run concurrently (use advisory locks in the migration tool).
- The Go backend (`make migrate-up` via golang-migrate or similar) should handle "already applied" gracefully.
- Run migrations as a separate step in the deployment process, not as part of the application container startup.

**Warning signs:** Multiple pods restarting simultaneously trigger concurrent migration errors; init container fails with "already migrated" errors causing pod startup failures.

**Phase:** Database migration Job manifest (separate from the StatefulSet).

---

### PSQL-4: pgvector extension not pre-installed in a custom PostgreSQL image

**What goes wrong:** If a custom or minimal PostgreSQL Docker image is used (not `pgvector/pgvector:pg17`), the pgvector extension is absent. `CREATE EXTENSION vector` fails silently or with a cryptic error. The constraint from PROJECT.md is clear: must use `pgvector/pgvector:pg17`, but this can be accidentally overridden.

**Prevention:**
- Pin the image in the StatefulSet manifest: `image: pgvector/pgvector:pg17` — never use `latest` or `postgres:17`.
- Add an init container or migration that verifies `SELECT extname FROM pg_extension WHERE extname = 'vector'` and fails fast if absent.

**Warning signs:** `ERROR: extension "vector" does not exist` in application logs; vector similarity searches return errors.

**Phase:** PostgreSQL StatefulSet image specification.

---

## WebSocket Specific

### WS-1: HTTP/1.0 proxying prevents WebSocket upgrade

**What goes wrong:** Some ingress configurations default to HTTP/1.0 or HTTP/1.1 without explicit `Upgrade` header support. The WebSocket handshake requires HTTP/1.1 with `Connection: Upgrade` and `Upgrade: websocket` headers. If the proxy strips these headers or downgrades to HTTP/1.0, the WebSocket handshake fails with HTTP 400 or 426.

**Prevention for NGINX Ingress:**
```yaml
nginx.ingress.kubernetes.io/proxy-http-version: "1.1"
nginx.ingress.kubernetes.io/configuration-snippet: |
  proxy_set_header Upgrade $http_upgrade;
  proxy_set_header Connection "upgrade";
```

**Warning signs:** WebSocket connections fail immediately with HTTP 400/426; `101 Switching Protocols` never received; connections work when bypassing ingress.

**Phase:** Ingress manifest — must be verified before any WebSocket functionality is tested.

---

### WS-2: Missing terminationGracePeriodSeconds — active WebSocket sessions killed immediately

**What goes wrong:** The default `terminationGracePeriodSeconds` is 30 seconds, which is sufficient for HTTP requests but may not be enough if the backend has long-lived WebSocket sessions with meaningful state (agent task streams, editor collaboration). SIGKILL is sent after the grace period expires regardless of active connections.

**Prevention:**
- For the Go backend, set `terminationGracePeriodSeconds: 60` (or longer if agent task durations warrant it).
- The Go backend must listen for `os.Signal` (SIGTERM), stop accepting new WS connections, close existing connections with a close frame (`1001 Going Away`), drain in-flight HTTP handlers, then exit.
- The preStop `sleep` must be shorter than `terminationGracePeriodSeconds` — leave at least 20 seconds for the application drain.

**Warning signs:** Agent tasks reporting mid-execution disconnects during deployments; `SIGKILL` appearing in pod events.

**Phase:** Go backend Deployment manifest.

---

### WS-3: Service type ClusterIP with multiple ports — wrong port targeted

**What goes wrong:** The Go backend serves both HTTP (port 8080) and WebSocket connections on the same port (gorilla/websocket upgrades on the same HTTP listener). If a separate WebSocket service or port is accidentally configured, the ingress may route WebSocket upgrade requests to the wrong port, which does not handle upgrades.

**Prevention:**
- Use a single Service with port 8080 for the backend. WebSocket upgrades happen on the same port as HTTP.
- Do not create a separate "websocket service" — this is a common over-engineering mistake.
- Verify the Ingress `backend.service.port.number` matches the Service `port`, not `targetPort`.

**Warning signs:** WebSocket connections fail with connection refused; HTTP requests succeed but WebSocket upgrade fails.

**Phase:** Service and Ingress manifests.

---

## Prevention Checklist

Use this checklist when reviewing each manifest before applying to a cluster.

### Ingress Manifest
- [ ] `proxy-read-timeout` and `proxy-send-timeout` set to `3600` (not default 60)
- [ ] `proxy-http-version: "1.1"` set
- [ ] `Upgrade` and `Connection` headers configured for WebSocket passthrough
- [ ] `X-Workspace-ID` header not stripped by any middleware
- [ ] TLS termination configured if applicable

### Go Backend Deployment
- [ ] `resources.requests` and `resources.limits` set for both CPU and memory
- [ ] Liveness probe does NOT check database connectivity
- [ ] Readiness probe DOES check database connectivity
- [ ] `initialDelaySeconds` >= 30 for readiness probe (DB connection pool warmup)
- [ ] `lifecycle.preStop` sleep hook configured (minimum 10s)
- [ ] `terminationGracePeriodSeconds` >= 60
- [ ] Rolling update: `maxUnavailable: 0`, `maxSurge: 1`, `minReadySeconds: 10`
- [ ] SIGTERM handler implemented in Go code (not a manifest issue but must be verified)

### Next.js Frontend Deployment
- [ ] No `NEXT_PUBLIC_*` vars injected via ConfigMap (they will be ignored)
- [ ] Server-side env vars used for API endpoints; client-side config served dynamically
- [ ] `resources.requests` and `resources.limits` set

### PostgreSQL StatefulSet
- [ ] `kind: StatefulSet`, NOT `kind: Deployment`
- [ ] `replicas: 1` (no multi-replica without a replication operator)
- [ ] Image pinned to `pgvector/pgvector:pg17` exactly
- [ ] `volumeClaimTemplates` used, NOT `volumes.persistentVolumeClaim`
- [ ] StorageClass `reclaimPolicy: Retain` verified (or PV patched after creation)
- [ ] Database migrations run as a separate Job, not an init container

### Secrets and ConfigMaps
- [ ] No Secret YAML files with real values committed to git
- [ ] `*-secret.yaml` in `.gitignore`
- [ ] Placeholder values documented with rotation runbook
- [ ] PostgreSQL password in a Secret, not a ConfigMap
- [ ] JWT/signing keys in Secrets

### NetworkPolicy
- [ ] Default-deny policy applied to namespace
- [ ] Explicit allow: backend pods -> postgres:5432
- [ ] Explicit allow: frontend pods -> backend:8080
- [ ] Explicit allow: all pods -> kube-dns:53 UDP
- [ ] CNI supports NetworkPolicy enforcement (verify, not assumed)

---

## Phase Mapping

| Phase Topic | Primary Pitfall | Prevention Action |
|---|---|---|
| PostgreSQL StatefulSet | CRIT-4, PSQL-1, PSQL-2, PSQL-4 | StatefulSet + Retain PV + replicas:1 + pinned image |
| Database migrations | PSQL-3 | Separate Job resource, not init container |
| Go backend Deployment | OV-2, OV-3, WS-2, CRIT-3 | preStop hook + terminationGracePeriod + split health probes |
| Next.js Deployment | CRIT-2 | No NEXT_PUBLIC_ via ConfigMap; server-side env var strategy |
| Ingress/Networking | CRIT-1, WS-1, WS-3, OV-4 | WebSocket timeout annotations + upgrade headers |
| Secrets/ConfigMaps | CRIT-5 | No real values in git; gitignore Secret files |
| NetworkPolicy | OV-5 | Default-deny + explicit allow rules |
| Resource limits | OV-1 | requests+limits on every container |
| Horizontal scaling (future) | OV-6, PSQL-1 | Document constraints; sticky sessions or Redis pub/sub |

---

## Sources

- [Kubernetes Official: Seven Common Pitfalls (2025)](https://kubernetes.io/blog/2025/10/20/seven-kubernetes-pitfalls-and-how-to-avoid/)
- [Kubernetes Official: Liveness, Readiness, and Startup Probes](https://kubernetes.io/docs/concepts/configuration/liveness-readiness-startup-probes/)
- [Kubernetes Official: Good Practices for Secrets](https://kubernetes.io/docs/concepts/security/secrets-good-practices/)
- [Kubernetes Official: Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [WebSocket.org: Kubernetes WebSocket Ingress — NGINX, Traefik & HAProxy](https://websocket.org/guides/infrastructure/kubernetes/)
- [ingress-nginx Issue #5167: Websockets closing after 60s despite proxy-read-timeout](https://github.com/kubernetes/ingress-nginx/issues/5167)
- [pgvector Issue #176: Using pgvector on Kubernetes with n > 1 replicas](https://github.com/pgvector/pgvector/issues/176)
- [Next.js Discussion #25474: Public environment variables don't work in Kubernetes](https://github.com/vercel/next.js/discussions/25474)
- [Crunchy Data: Stateful Postgres Storage Using Kubernetes](https://www.crunchydata.com/blog/stateful-postgres-storage-using-kubernetes)
- [Google Cloud Blog: Kubernetes Best Practices — Terminating with Grace](https://cloud.google.com/blog/products/containers-kubernetes/kubernetes-best-practices-terminating-with-grace)
- [Infisical: Kubernetes Secrets Management in 2025](https://infisical.com/blog/kubernetes-secrets-management-2025)
- [Sysdig: Kubernetes OOM and CPU Throttling](https://www.sysdig.com/blog/troubleshoot-kubernetes-oom)
- [vCluster: Kubernetes Readiness Probes — Common Pitfalls](https://www.vcluster.com/blog/kubernetes-readiness-probes-examples-and-common-pitfalls)
- [Atlas Guides: Run Database Schema Migrations in Kubernetes Using Init Containers](https://atlasgo.io/guides/deploying/k8s-init-container)
- [DEV Community: Scaling Horizontally — Kubernetes, Sticky Sessions, and Redis](https://dev.to/deepak_mishra_35863517037/scaling-horizontally-kubernetes-sticky-sessions-and-redis-578o)
