# Kubernetes Manifests

Production-ready Kubernetes manifests for deploying the Multica stack. Plain YAML organized with [Kustomize](https://kustomize.io/) -- no Helm required.

## Prerequisites

- Kubernetes cluster (1.27+)
- `kubectl` with cluster access
- [ingress-nginx](https://kubernetes.github.io/ingress-nginx/) controller installed
- A StorageClass that supports `ReadWriteOnce` (default works on GKE/EKS/AKS)
- Container images built and pushed to a registry

## Quick Start

```bash
# 0. Check cluster is ready
make k8s-prereqs

# 1. Build and push images
make docker-build          # Backend image
make docker-build-web      # Frontend image

# 2. Update image references in manifests (or use kustomize images)
#    See "Image Configuration" below

# 3. Create secrets with real values
kubectl create namespace multica
kubectl -n multica create secret generic backend-secrets \
  --from-literal=JWT_SECRET="$(openssl rand -hex 32)" \
  --from-literal=RESEND_API_KEY="your-key" \
  --from-literal=GOOGLE_CLIENT_ID="your-id" \
  --from-literal=GOOGLE_CLIENT_SECRET="your-secret"
kubectl -n multica create secret generic postgres-secrets \
  --from-literal=POSTGRES_PASSWORD="your-password" \
  --from-literal=DATABASE_URL="postgres://multica:your-password@postgres:5432/multica?sslmode=disable"

# 4. Deploy (validates, applies, watches rollout)
make k8s-deploy                    # Staging (default)
make k8s-deploy K8S_ENV=production # Production
```

## Directory Structure

```
k8s/
├── base/                        # Shared base manifests
│   ├── kustomization.yaml       # Root Kustomize config
│   ├── namespace.yaml           # Namespace: multica
│   ├── config/
│   │   ├── backend-config.yaml      # Backend ConfigMap (PORT)
│   │   ├── frontend-config.yaml     # Frontend ConfigMap (NODE_ENV, PORT)
│   │   ├── postgres-config.yaml     # Postgres ConfigMap (DB name, user, PGDATA)
│   │   ├── backend-secrets.yaml     # Backend secrets (placeholder values)
│   │   ├── postgres-secrets.yaml    # Postgres secrets (placeholder values)
│   │   └── serviceaccounts.yaml     # ServiceAccounts for each workload
│   ├── postgres/
│   │   ├── statefulset.yaml         # PostgreSQL StatefulSet (pgvector/pgvector:pg17)
│   │   ├── service.yaml             # ClusterIP Service (port 5432)
│   │   ├── service-headless.yaml    # Headless Service for StatefulSet DNS
│   │   ├── init-configmap.yaml      # pgvector extension init SQL
│   │   └── migration-job.yaml       # Schema migration Job (runs ./migrate up)
│   ├── backend/
│   │   ├── deployment.yaml          # Go backend Deployment
│   │   └── service.yaml             # ClusterIP Service (port 8080)
│   ├── frontend/
│   │   ├── deployment.yaml          # Next.js frontend Deployment
│   │   └── service.yaml             # ClusterIP Service (port 3000)
│   ├── ingress/
│   │   └── ingress.yaml             # Ingress with WebSocket annotations
│   └── hardening/
│       ├── pdbs.yaml                # PodDisruptionBudgets (all services)
│       └── network-policies.yaml    # Default-deny + explicit allow rules
└── overlays/
    ├── staging/
    │   └── kustomization.yaml   # 1 replica, lower resources, staging.multica.dev
    └── production/
        └── kustomization.yaml   # 3 replicas, higher resources, app.multica.dev
```

## Components

### PostgreSQL

Runs as a **StatefulSet** with `replicas: 1` using `pgvector/pgvector:pg17`. The pgvector extension is auto-enabled via an init SQL ConfigMap mounted at `/docker-entrypoint-initdb.d/`.

**Do not set `replicas: 2`** -- multiple PostgreSQL replicas without a replication operator (e.g., CloudNativePG) creates independent databases with no shared data.

Data is persisted via `volumeClaimTemplates` with 10Gi storage.

### Database Migrations

Migrations run as a Kubernetes **Job** (`db-migrate`), not as part of the application entrypoint. The Job uses the same backend image with `./migrate up` as the command.

```bash
# Check migration status
kubectl -n multica get job db-migrate

# Re-run migrations (delete old job first)
kubectl -n multica delete job db-migrate
kubectl apply -k k8s/overlays/staging/
```

### Backend (Go)

Deployment running `./server` directly (bypasses `entrypoint.sh` which would also run migrations).

- **Liveness:** TCP socket on port 8080 (no DB dependency -- avoids restart storms)
- **Readiness:** HTTP GET `/health` (confirms server + DB connectivity)
- **Startup:** HTTP GET `/health` with 60s budget (failureThreshold 30 x period 2s)
- **Graceful shutdown:** `preStop` sleep 10s + Go's built-in 10s SIGTERM handler
- **Rolling update:** maxSurge 1, maxUnavailable 0 (zero-downtime)

### Frontend (Next.js)

Deployment using the standalone Next.js output. `HOSTNAME=0.0.0.0` is set in the Dockerfile so the server binds correctly for Kubernetes probes.

> **Note on `NEXT_PUBLIC_*` variables:** These are baked at **build time** into the Next.js bundle. They cannot be injected via ConfigMap at runtime. Rebuild the image to change them.

### Ingress

Single Ingress resource with nginx annotations for WebSocket support:

| Annotation | Value | Why |
|---|---|---|
| `proxy-read-timeout` | `3600` | Prevents 60s silent drop of WebSocket connections |
| `proxy-send-timeout` | `3600` | Same as above, for send direction |
| `proxy-http-version` | `1.1` | Required for HTTP Upgrade (WebSocket handshake) |
| `affinity` | `cookie` | Sticky sessions -- reconnecting clients hit same backend pod |
| `affinity-mode` | `persistent` | Cookie persists across requests |

Path routing: `/api` -> backend:8080, `/` -> frontend:3000.

### Security

**SecurityContexts** on all workloads:
- `runAsNonRoot: true`
- `allowPrivilegeEscalation: false`
- `capabilities: { drop: [ALL] }`

**NetworkPolicies** (default-deny + explicit allows):
- Ingress controller -> frontend (3000), backend (8080)
- Frontend -> backend (8080, for SSR API proxying)
- Backend -> postgres (5432)
- All pods -> kube-dns (53 UDP/TCP)
- Backend -> external HTTPS (443, for Resend API, Google OAuth)

**Secrets** are gitignored. The checked-in secret files contain `CHANGE_ME` placeholders only. Create real secrets via `kubectl create secret` (see Quick Start).

## Environments

| Setting | Staging | Production |
|---------|---------|------------|
| Backend replicas | 1 | 3 |
| Frontend replicas | 1 | 3 |
| Backend CPU limit | 250m | 1 |
| Backend memory limit | 256Mi | 1Gi |
| Frontend CPU limit | 250m | 1 |
| Frontend memory limit | 256Mi | 1Gi |
| Postgres CPU limit | (base: 1) | 2 |
| Postgres memory limit | (base: 1Gi) | 2Gi |
| Ingress host | staging.multica.dev | app.multica.dev |

## Image Configuration

Base manifests use placeholder image names (`backend:latest`, `frontend:latest`). Override them per-environment using Kustomize `images`:

```yaml
# In overlays/production/kustomization.yaml, add:
images:
  - name: backend
    newName: ghcr.io/multica-ai/multica/backend
    newTag: v1.0.0
  - name: frontend
    newName: ghcr.io/multica-ai/multica/web
    newTag: v1.0.0
  - name: multica-backend  # migration job image
    newName: ghcr.io/multica-ai/multica/backend
    newTag: v1.0.0
```

## Operations

```bash
# Check cluster prerequisites
make k8s-prereqs

# Validate manifests render without errors
make k8s-validate

# Deploy (validate + apply + watch rollout)
make k8s-deploy                     # Staging (default)
make k8s-deploy K8S_ENV=production  # Production

# Check deployment health
make k8s-status

# Tail logs (default: backend)
make k8s-logs                   # Backend logs
make k8s-logs SVC=frontend      # Frontend logs
make k8s-logs SVC=postgres      # PostgreSQL logs

# Render manifests for review
make k8s-build-staging
make k8s-build-production

# Diff against live cluster
make k8s-diff K8S_ENV=staging
make k8s-diff K8S_ENV=production
```

## Deployment Order

Kustomize applies all resources at once, but Kubernetes processes them in dependency order:

1. **Namespace** -- must exist before anything else
2. **ConfigMaps + Secrets** -- configuration referenced by workloads
3. **ServiceAccounts** -- identity for pods
4. **PostgreSQL** (StatefulSet + Services) -- database must be running
5. **Migration Job** -- schema must be applied before backend starts
6. **Backend + Frontend** (Deployments + Services) -- readiness probes gate traffic
7. **Ingress** -- routes external traffic once services are healthy
8. **NetworkPolicies + PDBs** -- hardening applied last

> If deploying for the first time, the migration Job and backend may initially fail until PostgreSQL is ready. Kubernetes will retry automatically (`backoffLimit: 3` on the Job, restart policy on Deployments).

## Customization

To add a new environment overlay:

```bash
mkdir k8s/overlays/my-env
```

```yaml
# k8s/overlays/my-env/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
patches:
  - target:
      kind: Ingress
      name: multica-ingress
    patch: |-
      - op: add
        path: /spec/rules/0/host
        value: my-env.multica.dev
```

## What's Not Included

These are deferred to future iterations:

- **TLS/HTTPS** -- add via cert-manager + Let's Encrypt in the ingress overlay
- **Autoscaling (HPA/VPA)** -- add after baseline resource usage is profiled
- **PostgreSQL HA** -- requires CloudNativePG operator; current setup is single-replica
- **External Secrets Operator** -- for pulling secrets from Vault/AWS/GCP secret managers
- **Helm chart** -- Kustomize overlays are sufficient for now
- **CI/CD integration** -- manifests only; deployment pipeline is a separate concern
