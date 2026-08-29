#!/usr/bin/env bash
# Manually triggers the backup CronJob on demand and tails its logs
# (Task 3 backup verification, without waiting for 02:00 UTC).
set -euo pipefail
JOB_NAME="manual-backup-$(date +%s)"
kubectl create job -n data "$JOB_NAME" --from=cronjob/db-backup
kubectl wait -n data --for=condition=complete "job/$JOB_NAME" --timeout=180s
kubectl logs -n data "job/$JOB_NAME"
