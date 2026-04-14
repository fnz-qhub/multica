# Phase 3: Ingress and Hardening - Context

**Gathered:** 2026-04-14
**Status:** Ready for planning

<domain>
## Phase Boundary

Ingress resource with WebSocket support and path-based routing, PodDisruptionBudgets, SecurityContexts, NetworkPolicies, and Kustomize base+overlay structure for multi-environment support. This is the final phase — after this, the full K8s deployment is production-ready.

</domain>

<decisions>
## Implementation Decisions

### Ingress resource
- Use `networking.k8s.io/v1` Ingress (assumes ingress-nginx controller pre-installed on cluster)
- Single Ingress resource with two path rules:
  - `/api` prefix → backend Service on port 8080 (pathType: Prefix)
  - `/` → frontend Service on port 3000 (pathType: Prefix)
- Host left configurable via Kustomize overlay (no hardcoded domain in base)

### WebSocket annotations (critical)
- `nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"` (prevents 60s silent drop)
- `nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"`
- `nginx.ingress.kubernetes.io/proxy-http-version: "1.1"`
- These apply to the backend path specifically (WebSocket upgrade for real-time features)

### Sticky sessions
- `nginx.ingress.kubernetes.io/affinity: "cookie"` on backend path
- `nginx.ingress.kubernetes.io/affinity-mode: "persistent"`
- Required when backend replicas > 1 to prevent WebSocket reconnects landing on different pods

### PodDisruptionBudgets
- Backend PDB: `minAvailable: 1` (always keep at least 1 pod during voluntary disruption)
- Frontend PDB: `minAvailable: 1`
- PostgreSQL PDB: `minAvailable: 1` (only 1 replica, but PDB prevents accidental eviction)

### SecurityContexts
- All pods: `runAsNonRoot: true`, `allowPrivilegeEscalation: false`
- All containers: `capabilities: { drop: ["ALL"] }`
- Backend: `runAsUser: 65532` (nonroot user on alpine)
- Frontend: `runAsUser: 1001` (nextjs user from Dockerfile.web)
- PostgreSQL: `runAsUser: 999` (postgres user)
- `readOnlyRootFilesystem: true` where possible (backend yes, frontend and postgres may need writable tmp)

### NetworkPolicies
- Default deny all ingress/egress in namespace
- Allow rules:
  - Ingress controller → frontend (port 3000)
  - Ingress controller → backend (port 8080)
  - Backend → postgres (port 5432)
  - Frontend → backend (port 8080, for SSR API calls)
  - Postgres: ingress only from backend and migration job
  - All pods → DNS (kube-dns on port 53 UDP/TCP)
  - Backend → external (for Resend API, Google OAuth) — egress to 0.0.0.0/0 on 443

### Kustomize overlays
- `k8s/overlays/staging/` — lower resource limits, single replica, staging-specific ingress host
- `k8s/overlays/production/` — full resource limits, multiple replicas, production ingress host
- Each overlay has `kustomization.yaml` with patches for replica count, resources, and ingress host
- Base manifests are the source of truth; overlays only patch differences

### Directory structure
- `k8s/base/ingress/` — ingress.yaml, kustomization.yaml
- `k8s/base/hardening/` — pdbs.yaml, network-policies.yaml, kustomization.yaml
- `k8s/overlays/staging/` — kustomization.yaml + patches
- `k8s/overlays/production/` — kustomization.yaml + patches
- Update `k8s/base/kustomization.yaml` to include ingress/ and hardening/
- Update SecurityContexts as patches in existing deployment files (backend, frontend, postgres)

### Claude's Discretion
- Exact NetworkPolicy label selectors
- Whether to split ingress into separate resources per service or single resource
- Overlay patch format (strategic merge patch vs JSON patch)
- TLS configuration placeholder structure in overlays

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- Phase 1 created namespace, ConfigMaps, Secrets, ServiceAccounts — all referenced by labels
- Phase 2 created backend and frontend Deployments with label selectors already defined
- Existing `k8s/base/kustomization.yaml` already includes config/, postgres/, backend/, frontend/

### Established Patterns
- All manifests use `namespace: multica`
- Labels: `app.kubernetes.io/name`, `app.kubernetes.io/component`
- Kustomize kustomization.yaml at each subdirectory level
- Resources referenced by relative path in kustomization.yaml

### Integration Points
- Ingress references Service names: `backend` (port 8080), `frontend` (port 3000)
- NetworkPolicies reference pod labels from Phase 1/2 Deployments
- PDBs reference label selectors matching Deployments
- SecurityContexts added to existing Deployment specs (Phase 2 files)
- Kustomize overlays patch Phase 1/2 resources (replica counts, resource limits)

</code_context>

<specifics>
## Specific Ideas

No specific requirements — auto mode. Key constraints from research:
- WebSocket timeout annotations are the single most critical detail (CRIT-1 from pitfalls research)
- NetworkPolicy enforcement depends on cluster CNI — manifests define policies regardless
- TLS not in v1 scope but overlay structure should make it easy to add

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope (auto mode).

</deferred>

---

*Phase: 03-ingress-hardening*
*Context gathered: 2026-04-14*
