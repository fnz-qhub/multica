# Requirements: Kubernetes Manifests

**Defined:** 2026-04-14
**Core Value:** A single `kubectl apply` deploys the entire Multica stack to any Kubernetes cluster with correct networking, persistence, and scaling defaults.

## v1 Requirements

Requirements for initial release. Each maps to roadmap phases.

### Foundation

- [ ] **FOUND-01**: Dedicated namespace isolates all Multica resources from other cluster workloads
- [ ] **FOUND-02**: ConfigMaps provide non-secret environment configuration for all services
- [ ] **FOUND-03**: Secret manifests with placeholder values exist for all sensitive config (DB passwords, API keys)
- [ ] **FOUND-04**: Secret manifest files are excluded from git via .gitignore pattern
- [ ] **FOUND-05**: ServiceAccounts are defined for each workload with least-privilege RBAC

### Database

- [ ] **DB-01**: PostgreSQL runs as a StatefulSet using `pgvector/pgvector:pg17` image with `replicas: 1`
- [ ] **DB-02**: Headless Service provides stable DNS for the StatefulSet
- [ ] **DB-03**: ClusterIP Service provides stable endpoint for application connections
- [ ] **DB-04**: PersistentVolumeClaim via `volumeClaimTemplates` provides durable storage
- [ ] **DB-05**: pgvector extension is auto-enabled via init SQL mounted from ConfigMap
- [ ] **DB-06**: Database migration runs as a Kubernetes Job (not init container)

### Backend

- [ ] **BE-01**: Go backend runs as a Deployment with configurable replicas
- [ ] **BE-02**: Container uses distroless base image (`gcr.io/distroless/static-debian12:nonroot`)
- [ ] **BE-03**: Liveness probe checks process health only (`/livez`, no DB dependency)
- [ ] **BE-04**: Readiness probe checks DB connectivity (`/readyz`)
- [ ] **BE-05**: Startup probe allows slow initialization without liveness kills
- [ ] **BE-06**: ClusterIP Service exposes port 8080
- [ ] **BE-07**: Resource requests and limits are set for CPU and memory
- [ ] **BE-08**: preStop hook with `sleep 10` ensures graceful connection drain during rollouts
- [ ] **BE-09**: Rolling update strategy configured with maxSurge/maxUnavailable

### Frontend

- [ ] **FE-01**: Next.js runs as a Deployment with `output: 'standalone'` image
- [ ] **FE-02**: `HOSTNAME=0.0.0.0` env var set so container binds correctly for K8s probes
- [ ] **FE-03**: Client-side config served dynamically (no reliance on `NEXT_PUBLIC_*` at runtime)
- [ ] **FE-04**: Liveness and readiness probes configured
- [ ] **FE-05**: ClusterIP Service exposes port 3000
- [ ] **FE-06**: Resource requests and limits are set for CPU and memory

### Ingress

- [ ] **ING-01**: Ingress resource routes external traffic to frontend and backend services
- [ ] **ING-02**: WebSocket annotations set: `proxy-read-timeout: "3600"`, `proxy-send-timeout: "3600"`, `proxy-http-version: "1.1"`
- [ ] **ING-03**: Cookie-based sticky sessions configured for backend when replicas > 1
- [ ] **ING-04**: Path-based routing separates API (`/api`) and frontend (`/`) traffic

### Hardening

- [ ] **HARD-01**: PodDisruptionBudgets prevent all pods of a service being evicted simultaneously
- [ ] **HARD-02**: SecurityContext sets `runAsNonRoot: true` and drops all capabilities
- [ ] **HARD-03**: Kustomize base + overlay structure supports staging/production environments
- [ ] **HARD-04**: NetworkPolicy default-deny with explicit allow rules between services

## v2 Requirements

Deferred to future release. Tracked but not in current roadmap.

### Scaling

- **SCALE-01**: HorizontalPodAutoscaler for backend and frontend based on CPU/memory
- **SCALE-02**: VerticalPodAutoscaler recommendations for right-sizing resource limits

### Security

- **SEC-01**: External Secrets Operator integration for secret management
- **SEC-02**: TLS termination via cert-manager + Let's Encrypt
- **SEC-03**: Pod Security Standards (restricted) enforcement

### Operations

- **OPS-01**: Helm chart packaging for easier distribution
- **OPS-02**: CloudNativePG operator for PostgreSQL HA with automatic failover
- **OPS-03**: Prometheus ServiceMonitor + Grafana dashboards for observability

## Out of Scope

| Feature | Reason |
|---------|--------|
| Helm chart | Plain manifests first — Helm adds templating complexity before patterns are validated |
| Service mesh (Istio/Linkerd) | Unnecessary for a 2-10 person team; adds operational overhead |
| Multi-cluster federation | Single cluster target; federation is premature |
| CI/CD pipeline integration | Manifests only; deployment automation is a separate concern |
| Electron/desktop packaging | Not a K8s workload |
| Autoscaling (HPA/VPA) | Deferred until baseline resource usage is profiled |
| Multi-replica PostgreSQL | Requires operator (CloudNativePG); plain StatefulSet must stay at replicas: 1 |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| FOUND-01 | — | Pending |
| FOUND-02 | — | Pending |
| FOUND-03 | — | Pending |
| FOUND-04 | — | Pending |
| FOUND-05 | — | Pending |
| DB-01 | — | Pending |
| DB-02 | — | Pending |
| DB-03 | — | Pending |
| DB-04 | — | Pending |
| DB-05 | — | Pending |
| DB-06 | — | Pending |
| BE-01 | — | Pending |
| BE-02 | — | Pending |
| BE-03 | — | Pending |
| BE-04 | — | Pending |
| BE-05 | — | Pending |
| BE-06 | — | Pending |
| BE-07 | — | Pending |
| BE-08 | — | Pending |
| BE-09 | — | Pending |
| FE-01 | — | Pending |
| FE-02 | — | Pending |
| FE-03 | — | Pending |
| FE-04 | — | Pending |
| FE-05 | — | Pending |
| FE-06 | — | Pending |
| ING-01 | — | Pending |
| ING-02 | — | Pending |
| ING-03 | — | Pending |
| ING-04 | — | Pending |
| HARD-01 | — | Pending |
| HARD-02 | — | Pending |
| HARD-03 | — | Pending |
| HARD-04 | — | Pending |

**Coverage:**
- v1 requirements: 34 total
- Mapped to phases: 0
- Unmapped: 34 (pending roadmap creation)

---
*Requirements defined: 2026-04-14*
*Last updated: 2026-04-14 after initial definition*
