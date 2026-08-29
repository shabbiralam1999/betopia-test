#!/usr/bin/env bash
# Deliberately crash-loops a throwaway pod so PodCrashLoopBackOff fires
# (Task 4 alert verification).
set -euo pipefail
kubectl run alert-test --image=busybox --restart=Always -n app -- sh -c "exit 1"
echo "Pod 'alert-test' created in namespace 'app' and will crash-loop."
echo "Check firing alerts at: kubectl -n observability port-forward svc/kube-prometheus-stack-alertmanager 9093"
echo "Clean up afterwards with: kubectl delete pod alert-test -n app"
