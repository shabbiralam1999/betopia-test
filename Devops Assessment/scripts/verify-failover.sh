#!/usr/bin/env bash
# Kills the current PostgreSQL primary pod and confirms CNPG promotes a
# replica automatically (streaming replication failover, Task 3).
set -euo pipefail
NS=data

PRIMARY=$(kubectl get pods -n "$NS" -l cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}')
echo "Current primary: $PRIMARY"
echo "Deleting primary pod to force failover..."
kubectl delete pod -n "$NS" "$PRIMARY"

echo "Waiting for a new primary to be elected..."
sleep 15
kubectl get pods -n "$NS" -l cnpg.io/cluster=postgres -o custom-columns=NAME:.metadata.name,ROLE:.metadata.labels.cnpg\\.io/instanceRole
