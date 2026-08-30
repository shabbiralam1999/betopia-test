# DevOps Practical Technical Assessment — Solution

A production-grade Kubernetes ecosystem for a polyglot microservice stack
(2 transactional services + PostgreSQL/MySQL/SQL Server), covering
containerization, orchestration, HA storage, disaster recovery, observability,
and GitOps CI/CD. Every task in the assessment brief has its own file(s) —
this README explains **what** was built, **why** it was built that way, and
**how** to run and verify it.

## Repository layout

```
docker/                     Task 1 — Dockerfiles
  service-a/Dockerfile          Node.js multi-stage -> distroless
  service-a/.dockerignore
  service-b/Dockerfile          Python multi-stage -> distroless
  service-b/.dockerignore

k8s/                         Task 2–5 — all cluster manifests
  base/                          environment-agnostic resources
    namespaces.yaml
    deployment-service-a.yaml     Deployment + Service, HA + hardening
    deployment-service-b.yaml
    hpa.yaml                      HorizontalPodAutoscalers
    ingress.yaml                  host/path routing + TLS
    networkpolicy.yaml            zero-trust NetworkPolicies
    kustomization.yaml
  database/                     Task 3 — stateful workloads
    postgres-cluster.yaml         CloudNativePG Cluster (HA + replication)
    mysql-statefulset.yaml
    sqlserver-statefulset.yaml
    secret-management.md          explains the Sealed-Secrets/ESO pattern
  backup/
    backup-cronjob.yaml           Task 3 — daily 02:00 UTC backup job
  observability/                Task 4
    fluent-bit-daemonset.yaml     log shipping + JSON parsing + enrichment
    prometheus-alert-rules.yaml   the 3 required alert rules
    alertmanager-config.yaml      routing to Slack / PagerDuty
  overlays/                     Task 5 — GitOps environments
    staging/kustomization.yaml
    production/kustomization.yaml

/.github/workflows/ci.yaml  Task 5 — lint, scan, build, tag, promote

scripts/
  bootstrap.sh                 ONE-CLICK setup (Task: required deliverable)
  verify-failover.sh           kills the PG primary, confirms auto-failover
  trigger-test-alert.sh        forces a CrashLoopBackOff to test alerting
  verify-backup.sh             runs the backup CronJob on demand
```

**One deliberate deviation from the brief's suggested folder name:** the
brief lists `/helm` as a folder, but I chose **Kustomize overlays** over Helm
for the GitOps layer (see "Task 5" below for why) — so that folder is
`k8s/overlays/{staging,production}` instead of a top-level `/helm`. Nothing
is missing, it's just named for the tool actually used.

---

## Task 1 — Containerization & Hardening (`docker/`)

**What:** Two 3-stage Dockerfiles — `service-a` (Node.js/Express) and
`service-b` (Python/FastAPI). Each has a `deps`/`builder` stage that installs
dependencies, a `build` stage that compiles/copies source, and a final
`runtime` stage built from a **distroless** base image
(`gcr.io/distroless/nodejs20-debian12:nonroot`,
`gcr.io/distroless/python3-debian12:nonroot`).

**Why this design:**
- **Distroless runtime** — no shell, no package manager, no compiler in the
  image that actually runs in production, which removes most of the attack
  surface a CVE scanner would otherwise flag.
- **Multi-stage split** — the build toolchain (gcc, npm devDependencies,
  etc.) never leaves the builder stage, so it can never be exploited at
  runtime even if an attacker gets code execution in the container.
- **UID 10001, non-root** — matches the `runAsUser: 10001` /
  `runAsNonRoot: true` enforced later in the Kubernetes `securityContext`,
  so the image can't accidentally be run as root even outside Kubernetes.
- **Layer ordering** — `package.json`/`requirements.txt` are copied and
  installed *before* the rest of the source, so `docker build` only
  re-installs dependencies when the manifest actually changes, not on every
  source edit.
- **Read-only root filesystem** is *not* baked into the image (images can't
  enforce that themselves) — it's enforced at the Kubernetes layer instead
  (see Task 2), which is the correct place for it.

**Important — these Dockerfiles are reference implementations, not runnable
apps:** the assessment asks for Dockerfiles for "two sample services," so
that's what's here — `npm run build` producing `dist/server.js`, and a
FastAPI `main.py` served by `uvicorn`, are the *conventions the Dockerfile
assumes*, not source code included in this repo. Drop your actual
`package.json`/`dist/` or `requirements.txt`/`main.py` into
`docker/service-a` / `docker/service-b` and these build as-is; there's
nothing else to change.

**A build-context bug caught in review:** `.dockerignore` originally lived
at `docker/.dockerignore` — one level above both services. Docker only
ever reads a `.dockerignore` from the build **context root**, and every
build command here (`docker build ... docker/service-a`) uses each
service's own folder as that root, so the shared file was silently never
read by either build. Fixed by giving each service its own
`.dockerignore`, scoped to its own language (`node_modules`/`dist` for
service-a, `__pycache__`/`.venv` for service-b).

**How to build (once real app source is present):**
```bash
docker build -t service-a:local docker/service-a
docker build -t service-b:local docker/service-b
```

---

## Task 2 — Kubernetes Orchestration & Zero-Downtime Routing (`k8s/base/`)

**What:**
- `deployment-service-a.yaml` / `deployment-service-b.yaml`: strict
  `requests`/`limits`, readiness+liveness probes, `RollingUpdate` with
  `maxSurge: 25% / maxUnavailable: 0`, and a hardened `securityContext`
  (non-root, read-only root fs, all Linux capabilities dropped).
- `hpa.yaml`: HPAs targeting 70% CPU / 80% memory, with a 5-minute
  scale-down stabilization window so the fleet doesn't flap.
- `ingress.yaml`: one Ingress, host `api.acme.example.com`, routing
  `/api/v1` → service-a and `/api/v2` → service-b, TLS terminated via
  cert-manager.
- `networkpolicy.yaml`: default-deny in the `app` namespace, then explicit
  allow rules so only the ingress controller can reach the services, and
  each service can reach *only* its own database engine — plus a
  database-side policy so Postgres/MySQL/SQL Server only accept connections
  from their one owning service (and the backup job — see the callout
  below).

**Why this design:**
- `maxUnavailable: 0` is what actually guarantees zero-downtime — combined
  with the readiness probe, Kubernetes won't route traffic to a new pod
  (or remove an old one) until the new one is provably healthy.
- Pod **anti-affinity** (`requiredDuringSchedulingIgnoredDuringExecution`,
  `topologyKey: kubernetes.io/hostname`) is a hard requirement, not a soft
  preference — a single node failure should never be able to take down more
  than one replica.
- The NetworkPolicy is written as **explicit-allow over default-deny**
  rather than a handful of ad-hoc rules, which is the only way to actually
  get to "zero trust" rather than "mostly closed."

**A bug caught in review, worth calling out explicitly:** an "only
service-a can reach Postgres" rule, taken completely literally, also blocks
things that legitimately need to reach Postgres and aren't service-a —
namely CloudNativePG's own primary↔replica streaming replication (pod-to-pod
traffic on 5432 within the same `data` namespace), and the nightly backup
CronJob from Task 3. Both got explicit `ingress.from` rules added to
`postgres-allow-service-a-only`/`mysql-allow-service-b-only`, the backup
job's pod template was given a stable `app: db-backup` label so a
NetworkPolicy can select it, and — since no application service talks to
SQL Server directly — it got its own `sqlserver-allow-backup-only` policy
so it isn't left completely unprotected. Also: CloudNativePG manages its
own pods and doesn't apply a plain `app: postgres` label by default, so
`postgres-cluster.yaml` now sets `spec.inheritedMetadata.labels.app:
postgres` explicitly — without it, the NetworkPolicy's `podSelector` would
silently match zero pods and enforce nothing.

**How to verify:**
```bash
kubectl -n app rollout status deployment/service-a
kubectl -n app get hpa
kubectl -n app describe networkpolicy service-a-policy
kubectl -n data get pods --show-labels          # confirm postgres pods carry app=postgres
```

---

## Task 3 — Multi-Database State & Disaster Recovery (`k8s/database/`, `k8s/backup/`)

**What:**
- **PostgreSQL** runs via the **CloudNativePG (CNPG) operator**
  (`postgres-cluster.yaml`) — a 3-instance `Cluster` CR (1 primary + 2
  streaming replicas), dynamic PVCs on a `Retain`-policy `gp3` StorageClass,
  and required pod anti-affinity across nodes.
- **MySQL** and **SQL Server** run as plain `StatefulSet`s
  (`mysql-statefulset.yaml`, `sqlserver-statefulset.yaml`) with
  `volumeClaimTemplates` bound to the same storage class, so each replica
  gets its own PVC and volumes survive pod rescheduling.
- **Backup**: `backup-cronjob.yaml` runs daily at **02:00 UTC**, dumps all
  three engines (`pg_dump`, `mysqldump`, `sqlcmd BACKUP DATABASE`), gzips
  each dump, and uploads to an S3-compatible bucket via the AWS CLI.
- **Secrets**: every credential is a `secretKeyRef`, never a literal value
  in a Deployment/CronJob spec — see `secret-management.md` for the
  Sealed-Secrets / External-Secrets-Operator pattern used to keep real
  values out of git.

**Why CNPG instead of a hand-rolled Postgres StatefulSet:** streaming
replication, automatic failover, and PITR are genuinely hard to get right
by hand (split-brain, replication lag, promotion races). CNPG is a
CNCF-sandbox operator purpose-built for exactly this, so using it is both
less code and more correct than reinventing it. MySQL and SQL Server don't
have an equally mature free operator in this stack, so those two are
StatefulSets — documented as a **single-primary** limitation (see
"Known limitations" below) rather than pretending they're HA when they
aren't.

**Why the `Retain` reclaim policy:** the whole point of a backup/DR story is
surviving *mistakes*, including someone deleting the StatefulSet or PVC by
accident. `Delete` (the k8s default) would destroy the data at exactly the
moment you need it most.

**How to verify:**
```bash
kubectl -n data get cluster postgres         # CNPG cluster status
./scripts/verify-failover.sh                 # kill primary, watch re-election
./scripts/verify-backup.sh                   # run the CronJob now, tail logs
```

---

## Task 4 — Log Aggregation & Observability (`k8s/observability/`)

**What:**
- `fluent-bit-daemonset.yaml`: Fluent Bit as a **DaemonSet** (one pod per
  node — required so no node's logs are missed), tailing
  `/var/log/containers/*.log`, parsing the app's structured JSON fields
  (`timestamp`, `level`, `trace_id`, `caller`, `request_id`), enriching
  every record with the Kubernetes metadata filter (pod, namespace,
  labels), and shipping to **Loki**.
- `prometheus-alert-rules.yaml`: a `PrometheusRule` with the three required
  alerts — HTTP 5xx rate > 5% over 5m, database PVC usage > 85%, and
  `CrashLoopBackOff` detection.
- `alertmanager-config.yaml`: critical alerts route to PagerDuty, warnings
  batch into Slack, so a database PVC filling up doesn't page someone at
  3am while a genuine outage does.

**Why Fluent Bit over Filebeat/Fluentd:** it's a DaemonSet-native, low
memory-footprint (~50MB) log shipper written in C, which matters when it's
running on *every single node* in the cluster regardless of app load.

**A wiring bug caught in review:** writing `alertmanager-config.yaml` as a
plain `Secret` isn't enough by itself — left alone, kube-prometheus-stack's
Helm chart auto-generates and uses its *own* Alertmanager config, with no
reason to know this separate Secret exists, so the whole
PagerDuty/Slack routing design would silently never take effect (the alert
*rules* would still fire correctly; only the *routing* would quietly
default to the chart's own config instead of this one). Fixed two ways in
`scripts/bootstrap.sh`: the Secret is applied *before* the
`kube-prometheus-stack` Helm install (not after, via the later
`kubectl apply -k` — ordering matters here, see the comment in the script),
and the install is given `--set
alertmanager.alertmanagerSpec.configSecret=alertmanager-config` to actually
point Alertmanager at it. The Secret's key is `alertmanager.yaml` — that
exact key name is a hard requirement of the Prometheus Operator, not
configurable.

**How to verify:**
```bash
kubectl -n observability get daemonset fluent-bit
kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090
# open http://localhost:9090/alerts and confirm the 3 rules are loaded
./scripts/trigger-test-alert.sh   # forces CrashLoopBackOff, watch it fire

# Confirm Alertmanager actually loaded OUR config, not the chart's default —
# this should print the pagerduty-critical / slack-warnings receivers:
kubectl -n observability exec alertmanager-kube-prometheus-stack-alertmanager-0 \
  -- amtool config show --alertmanager.url=http://localhost:9093
```

---

## Task 5 — GitOps & CI/CD (`ci/`, `k8s/overlays/`)

**What:**
- `ci/.github/workflows/ci.yaml`: on every push/PR —
  1. renders and lints every manifest (`kustomize build | kubeconform`)
  2. builds both images, scans them with **Trivy**, and **fails the build**
     on any unpatched CRITICAL/HIGH CVE
  3. pushes images tagged with the short **git commit SHA**
  4. on `main`, automatically bumps the production overlay's image tag to
     that SHA and commits it back (the actual "GitOps" step — the desired
     state in git is what changes, not a live `kubectl apply` from CI).
- `k8s/overlays/staging` and `k8s/overlays/production`: **Kustomize**
  overlays over the same `k8s/base`, patching only what differs — replica
  counts, image tag, ingress hostname, HPA ceiling.

**A permissions gap caught in review:** the workflow didn't originally
declare a `permissions:` block. GitHub defaults `GITHUB_TOKEN` to
**read-only** on any repo created since February 2023, so the "Push image"
step to GHCR would fail with a 403 the first time this ran on a fresh
repo — regardless of how the repo's own Actions settings are configured.
Fixed with an explicit workflow-level `permissions: { contents: read,
packages: write }` rather than relying on ambient repo/org defaults.

**Why Kustomize over Helm here:** the brief allows either. Kustomize was
chosen because the manifests in this assessment don't need templating
logic (loops, conditionals, `{{ if }}` blocks) — they need the *same*
YAML with a handful of environment-specific values patched in, which is
exactly Kustomize's `patches:` model. It also means `kubectl apply -k`
works with zero extra tooling beyond kubectl itself, which keeps
`bootstrap.sh` simpler.

**A design choice worth flagging:** the staging overlay deliberately does
**not** use Kustomize's `namePrefix`. It's tempting to prefix every staging
resource (`staging-service-a`, etc.) for clarity, but several manifests
here hardcode a literal `namespace: app|data|observability` rather than
relying on Kustomize's `namespace:` transformer, and the CloudNativePG
`Cluster` CR points at its bootstrap Secret through a custom CRD field
(`spec.bootstrap.initdb.secret.name`) that Kustomize's built-in
name-reference rewriting doesn't know about. A `namePrefix` would rename
the Secret but leave that field pointing at the old, now-nonexistent name
— breaking Postgres bootstrap silently. Staging is distinguished from
production by image tag, replica count, and Ingress hostname instead,
which sidesteps the issue entirely.

**Required repo secret:** the `update-production-overlay` job in
`ci.yaml` pushes a commit back to the repo, which needs a
`GITOPS_PAT` (a personal access token or fine-grained token with
`contents: write`) configured under **Settings → Secrets → Actions** —
the default `GITHUB_TOKEN` is deliberately not used there since,
depending on branch protection, it may not be permitted to push.

**How to verify:**
```bash
kustomize build k8s/overlays/staging | kubeconform -strict
git log --oneline -- k8s/overlays/production/kustomization.yaml   # CI's auto-bump commits
```

---

## Running everything end-to-end

Prerequisites: Docker, `kind`, `kubectl`, `helm`. (The standalone
`kustomize` binary is *not* required to run `bootstrap.sh` — see the note
in the script; it's only needed separately for the CI pipeline.)

```bash
git clone <this-repo> && cd devops-assessment
./scripts/bootstrap.sh
```

This single script (no manual steps) will:
1. create a 3-node `kind` cluster (so anti-affinity has somewhere to spread to)
2. install the NGINX ingress controller and cert-manager (pinned versions)
3. install the CloudNativePG operator
4. install Sealed Secrets (for the secret-management pattern)
5. apply the Alertmanager routing Secret, then install kube-prometheus-stack
   (Prometheus + Alertmanager + Grafana) wired to use that Secret, and Loki
6. deploy the full app stack from `k8s/overlays/staging`
7. wait for everything to report healthy

Tear it down with:
```bash
./scripts/bootstrap.sh --teardown
```

### Verification runbook

| What to test         | Command                            | What you should see |
|-----------------------|-------------------------------------|----------------------|
| Zero-downtime rollout | `kubectl -n app rollout restart deployment/service-a` while curling the Ingress in a loop | no failed requests |
| DB failover           | `./scripts/verify-failover.sh`      | a new pod is elected `primary` within ~15–30s |
| Alert firing          | `./scripts/trigger-test-alert.sh`   | `PodCrashLoopBackOff` alert visible in Alertmanager |
| Log ingestion         | `kubectl -n observability port-forward svc/loki 3100` then query by `namespace="app"` | structured JSON logs with `trace_id`, `request_id` fields |
| Backup execution      | `./scripts/verify-backup.sh`        | job completes, logs show 3 successful `aws s3 cp` uploads |

---

## Known limitations / things I'd change for a real production rollout

- MySQL and SQL Server are **single-primary StatefulSets**, not HA clusters
  — a real deployment would add MySQL InnoDB Cluster/Orchestrator or an
  Azure Arc-enabled SQL MI equivalent. Called out here rather than
  glossed over.
- `alertmanager-config.yaml` and the placeholder DB secrets contain
  `CHANGE_ME` values so the manifests are self-contained and diffable in
  this repo; a real rollout replaces them via Sealed Secrets/ESO as
  described in `k8s/database/secret-management.md` — never commit the
  real values.
- The backup job stores dumps compressed in S3 but doesn't yet encrypt
  them client-side or manage retention/lifecycle rules — I'd add an S3
  lifecycle policy and SSE-KMS in a follow-up iteration.
- `docker/service-b`'s distroless runtime ships a Python venv but not a
  full OS — if your actual `requirements.txt` pulls in packages with
  compiled C extensions that expect shared libraries beyond what
  `python3-debian12` provides (e.g. certain `psycopg2`/`pyodbc` builds),
  they can fail at runtime with a missing `.so` rather than at build time.
  The usual fix is switching those specific packages to their pure-Python
  or statically-linked wheel (`psycopg2-binary`, `pyodbc`'s manylinux
  wheel), which is a one-line `requirements.txt` change, not a Dockerfile
  change.
- The `data` namespace does not have a blanket default-deny NetworkPolicy
  the way `app` does — only the three database StatefulSets/Cluster have
  explicit ingress allow-lists (see Task 2). Egress *from* the database
  pods themselves isn't restricted. For this stack that's a reasonable
  line to draw (databases don't originate outbound connections under
  normal operation), but a stricter posture would add an egress default-deny
  there too, with explicit DNS/replication exceptions.
- `scripts/bootstrap.sh` pins every external manifest and Helm chart it
  installs (ingress-nginx `controller-v1.15.1`, cert-manager `v1.19.6`,
  CNPG `v1.24.0`, sealed-secrets chart `2.16.1`, kube-prometheus-stack chart
  `88.5.4`, loki-stack chart `2.10.3`) so re-running it next month
  reproduces today's setup rather than whatever happens to be `latest` or
  `main` by then. One exception left deliberately unpinned: the CNPG
  manifest is fetched from `raw.githubusercontent.com/.../main/releases/`
  rather than a tagged path, because CNPG's release manifests are only
  published under `main` for that specific file — the version is still
  pinned by filename (`cnpg-1.24.0.yaml`), just not by git ref.
- `grafana/loki-stack` (used for log storage) is deprecated upstream in
  favor of `grafana/loki` in monolithic mode. It's kept here — pinned to a
  known-working version — rather than swapped for the newer chart, because
  the replacement needs real config (explicit `schemaConfig`, a storage
  backend, `deploymentMode`, and a MinIO-subchart deprecation to navigate
  as of chart v17+) that this repo has no way to verify against a live
  cluster before shipping. See the comment in `scripts/bootstrap.sh` for
  the migration path when you're ready to move off it.
