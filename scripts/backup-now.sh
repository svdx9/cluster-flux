#!/bin/sh
set -e
JOB="postgres-backup-manual-$(date +%Y%m%d-%H%M%S)"
kubectl create job -n prod --from=cronjob/postgres-backup "$JOB"
echo "Job created: $JOB"
echo "Follow dump logs:   kubectl logs -n prod -l job-name=$JOB -c dump -f"
echo "Follow upload logs: kubectl logs -n prod -l job-name=$JOB -c upload -f"
