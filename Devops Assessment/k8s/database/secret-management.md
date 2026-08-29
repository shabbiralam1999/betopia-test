# Secret Management

No plaintext credentials are committed to this repository. Every manifest
that needs a DB password, S3 key, or TLS cert references a Kubernetes
`Secret` by name only (`secretKeyRef`) — the manifests in this folder (and
`k8s/backup/backup-cronjob.yaml`) ship with `CHANGE_ME_*` placeholder
values purely so `kubectl apply -k` doesn't fail on a missing key during
local `kind`/`minikube` demos.

## Secrets this stack expects to exist

| Secret name                 | Namespace | Defined in                              | Used by |
|------------------------------|-----------|------------------------------------------|---------|
| `postgres-app-credentials`   | `data`    | `k8s/database/postgres-cluster.yaml`     | CNPG Cluster bootstrap, service-a, backup job |
| `mysql-app-credentials`      | `data`    | `k8s/database/mysql-statefulset.yaml`    | MySQL StatefulSet, service-b, backup job |
| `sqlserver-credentials`      | `data`    | `k8s/database/sqlserver-statefulset.yaml`| SQL Server StatefulSet, backup job |
| `s3-backup-credentials`      | `data`    | `k8s/backup/backup-cronjob.yaml`         | backup job (AWS CLI upload) |
| `alertmanager-config`        | `observability` | `k8s/observability/alertmanager-config.yaml` | Alertmanager (Slack/PagerDuty routing) |

Every one of these is defined in-repo with a `CHANGE_ME_*` placeholder so
the whole stack is self-contained and `kubectl apply -k` never fails on a
missing key. **Before any real S3 upload will succeed, replace the
`s3-backup-credentials` placeholder with a real AWS access key that has
`s3:PutObject` on the target bucket** — this is the one secret whose
placeholder value the backup CronJob will otherwise fail on the moment it
tries to actually push a dump.

For anything beyond a local demo, replace the placeholder Secrets with one
of:

1. **Sealed Secrets** (bitnami-labs/sealed-secrets) — encrypt the Secret
   client-side with `kubeseal`, commit the resulting `SealedSecret` CR
   (safe to store in git), and let the in-cluster controller decrypt it
   into a normal `Secret` at apply time.

   ```
   kubeseal --format=yaml < postgres-secret.yaml > postgres-sealedsecret.yaml
   git add postgres-sealedsecret.yaml   # safe — ciphertext only
   ```

2. **External Secrets Operator (ESO)** — keep the actual secret value in
   AWS Secrets Manager / SSM Parameter Store / Vault, and declare an
   `ExternalSecret` CR in git that tells ESO which key to sync into which
   Kubernetes Secret. Nothing sensitive ever touches git.

`scripts/bootstrap.sh` installs Sealed Secrets by default for the local
demo cluster, since it needs no external dependency (no AWS account, no
Vault) to prove the pattern end-to-end.
