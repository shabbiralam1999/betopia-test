#!/usr/bin/env bash
# ============================================================================
# One-click bootstrap: spins up a local kind cluster and deploys the entire
# stack end to end — operators, databases, app, observability, network
# policy — with zero manual steps beyond running this script.
#
# Usage:
#   ./scripts/bootstrap.sh            # full setup
#   ./scripts/bootstrap.sh --teardown # delete the cluster
# ============================================================================
set -euo pipefail

CLUSTER_NAME="devops-assessment"
K8S_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../k8s" && pwd)"

log() { printf '\n[bootstrap] %s\n' "$1"; }

teardown() {
  log "Deleting kind cluster '${CLUSTER_NAME}'..."
  kind delete cluster --name "${CLUSTER_NAME}" || true
  exit 0
}

[[ "${1:-}" == "--teardown" ]] && teardown

# Note: the standalone `kustomize` binary is NOT required here — this
# script only ever runs `kubectl apply -k`, and kustomize has been built
# into kubectl since 1.14. The CI pipeline (ci/.github/workflows/ci.yaml)
# installs its own standalone kustomize binary separately, since it needs
# `kustomize build`/`kustomize edit`, which kubectl doesn't expose.
for bin in docker kind kubectl helm; do
  command -v "$bin" >/dev/null 2>&1 || { echo "Missing required tool: $bin"; exit 1; }
done

log "Creating kind cluster '${CLUSTER_NAME}' (3 nodes, matches anti-affinity design)..."
cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 80
        hostPort: 8080
      - containerPort: 443
        hostPort: 8443
  - role: worker
  - role: worker
EOF

log "Installing NGINX ingress controller..."
# Pinned to a tagged release (controller-v1.15.1) instead of `main` — an
# unpinned branch reference means re-running this script next month could
# silently install a different version than today.
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.15.1/deploy/static/provider/kind/deploy.yaml
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s

log "Installing cert-manager (TLS)..."
# Pinned to v1.19.6 for the same reproducibility reason — `releases/latest`
# is a moving target.
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.19.6/cert-manager.yaml
kubectl wait --namespace cert-manager --for=condition=available --timeout=180s deployment --all

log "Installing CloudNativePG operator (PostgreSQL HA)..."
kubectl apply --server-side -f \
  https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/main/releases/cnpg-1.24.0.yaml
kubectl wait --namespace cnpg-system --for=condition=available --timeout=180s deployment --all

log "Installing Sealed Secrets controller..."
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets --force-update
helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace kube-system --version 2.16.1

log "Installing kube-prometheus-stack (Prometheus + Alertmanager + Grafana)..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -

# The Alertmanager routing config (k8s/observability/alertmanager-config.yaml)
# MUST exist before this helm install runs. kube-prometheus-stack is told
# via --set below to point its Alertmanager at that Secret by name
# (alertmanager.alertmanagerSpec.configSecret, which the operator requires
# to contain a key literally named `alertmanager.yaml`); if the Secret
# isn't there yet, the Alertmanager pod can never become Ready and this
# --wait install times out and fails the whole bootstrap. Applying it here
# is not a duplicate of the later `kubectl apply -k` — that step re-applies
# the same manifest idempotently once the full staging overlay goes out.
kubectl apply -f "${K8S_DIR}/observability/alertmanager-config.yaml"

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace observability --version 88.5.4 --wait --timeout 5m \
  --set alertmanager.alertmanagerSpec.configSecret=alertmanager-config

log "Installing Loki (log storage for Fluent Bit)..."
# NOTE: grafana/loki-stack is deprecated upstream in favor of grafana/loki
# (monolithic mode). It's pinned here to a known-working version rather
# than swapped for the newer chart, since the newer chart's config is
# meaningfully more involved (explicit schemaConfig, storage backend,
# deploymentMode, and a MinIO-subchart deprecation to navigate) and this
# repo can't be end-to-end tested against a live cluster before shipping —
# a rewrite here that couldn't be verified would be a worse risk than a
# pinned, working, deprecated chart. If you're taking this to production,
# migrate to grafana/loki with deploymentMode: SingleBinary and
# storage.type: filesystem — see https://grafana.com/docs/loki/latest/setup/install/helm/install-monolithic/
helm repo add grafana https://grafana.github.io/helm-charts --force-update
helm upgrade --install loki grafana/loki-stack --namespace observability --version 2.10.3 --wait --timeout 5m

log "Deploying application stack (staging overlay)..."
kubectl apply -k "${K8S_DIR}/overlays/staging"

log "Waiting for workloads to become ready..."
kubectl wait --namespace app --for=condition=available --timeout=300s deployment --all || true
kubectl wait --namespace data --for=condition=ready pod -l app=mysql --timeout=300s || true

log "Done. Verify with: kubectl get pods -A"
log "App reachable at: http://staging-api.acme.example.com:8080 (add to /etc/hosts -> 127.0.0.1)"
