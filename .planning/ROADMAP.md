# Roadmap: Kubernetes Manifests

## Overview

Three phases deliver production-ready Kubernetes manifests for the Multica stack. Phase 1 lays the cluster foundation and persistent database. Phase 2 deploys the Go backend and Next.js frontend as observable workloads. Phase 3 opens external access via a properly configured ingress and hardens the deployment with security controls and multi-environment support.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [ ] **Phase 1: Foundation and Database** - Namespace, config/secrets, RBAC, and PostgreSQL StatefulSet with migration job
- [ ] **Phase 2: Application Workloads** - Go backend and Next.js frontend deployments with probes, resources, and services
- [ ] **Phase 3: Ingress and Hardening** - External routing with WebSocket support, security controls, and Kustomize overlays

## Phase Details

### Phase 1: Foundation and Database
**Goal**: The cluster has isolated Multica resources, all configuration is loaded, and PostgreSQL is running with pgvector enabled and migrations applied
**Depends on**: Nothing (first phase)
**Requirements**: FOUND-01, FOUND-02, FOUND-03, FOUND-04, FOUND-05, DB-01, DB-02, DB-03, DB-04, DB-05, DB-06
**Success Criteria** (what must be TRUE):
  1. All Multica resources live in a dedicated namespace and are not visible in the default namespace
  2. ConfigMaps and Secrets exist for all services; secret files are absent from git history
  3. PostgreSQL pod is Running with pgvector extension active (verifiable via `\dx` in psql)
  4. The migration Job completes successfully and the schema is applied before any app pod starts
  5. Each workload identity has a ServiceAccount with least-privilege RBAC
**Plans**: TBD

Plans:
- [ ] 01-01: Namespace, ConfigMaps, Secrets, ServiceAccounts, RBAC
- [ ] 01-02: PostgreSQL StatefulSet, Services, PVC, pgvector init, migration Job

### Phase 2: Application Workloads
**Goal**: The Go backend and Next.js frontend are deployed, healthy, and reachable within the cluster
**Depends on**: Phase 1
**Requirements**: BE-01, BE-02, BE-03, BE-04, BE-05, BE-06, BE-07, BE-08, BE-09, FE-01, FE-02, FE-03, FE-04, FE-05, FE-06
**Success Criteria** (what must be TRUE):
  1. Backend pods reach Ready state and the readiness probe confirms DB connectivity at `/readyz`
  2. Frontend pods reach Ready state and serve the Next.js app on port 3000 within the cluster
  3. Rolling updates complete without downtime (maxSurge/maxUnavailable configured, preStop drain active)
  4. Resource requests and limits are set on every container; no pod is Burstable-unset
**Plans**: TBD

Plans:
- [ ] 02-01: Go backend Deployment, Service, probes, resources, rolling update config
- [ ] 02-02: Next.js frontend Deployment, Service, probes, resources, runtime config

### Phase 3: Ingress and Hardening
**Goal**: External traffic reaches the stack correctly, WebSocket connections are stable, and the deployment meets baseline security and multi-environment requirements
**Depends on**: Phase 2
**Requirements**: ING-01, ING-02, ING-03, ING-04, HARD-01, HARD-02, HARD-03, HARD-04
**Success Criteria** (what must be TRUE):
  1. Browser can reach the frontend and API through a single ingress with `/api` and `/` path routing
  2. WebSocket connections to the backend stay alive for long-lived sessions (timeout annotations present)
  3. Applying the staging overlay produces a valid, independent configuration without editing the base
  4. No pod runs as root; all capabilities are dropped; services cannot reach each other without explicit NetworkPolicy allow rules
**Plans**: TBD

Plans:
- [ ] 03-01: Ingress resource with WebSocket annotations, sticky sessions, path routing
- [ ] 03-02: PodDisruptionBudgets, SecurityContexts, NetworkPolicies, Kustomize base+overlays

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Foundation and Database | 0/2 | Not started | - |
| 2. Application Workloads | 0/2 | Not started | - |
| 3. Ingress and Hardening | 0/2 | Not started | - |
