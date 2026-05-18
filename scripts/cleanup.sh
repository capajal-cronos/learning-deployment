#!/usr/bin/env bash
# =============================================================================
# Cleanup script — deletes every resource this tutorial creates.
# Read it before running.
#
# Resources deleted, in order:
#   1. App VM + DB VM
#   2. Custom firewall rules
#   3. Subnet
#   4. VPC
#   5. Artifact Registry repo (and images inside)
#
# Resources KEPT by default (uncomment to remove):
#   - Secrets in Secret Manager
#   - The GitHub deployer service account
#   - The Workload Identity Pool/Provider
# =============================================================================
set -uo pipefail

PROJECT_ID=$(gcloud config get-value project)
REGION=$(gcloud config get-value compute/region)
ZONE=$(gcloud config get-value compute/zone)
VPC=taskboard-vpc

echo "Project:  $PROJECT_ID"
echo "Region:   $REGION"
echo "Zone:     $ZONE"
echo "VPC:      $VPC"
read -rp "Delete all TaskBoard resources in this project? [y/N] " ok
[[ "$ok" =~ ^[Yy]$ ]] || { echo "aborted"; exit 1; }

gcloud compute instances delete taskboard-app taskboard-db \
  --zone="$ZONE" --quiet || true

for rule in allow-ssh-from-iap allow-http-public allow-internal-db; do
  gcloud compute firewall-rules delete "$rule" --quiet || true
done

gcloud compute networks subnets delete app-subnet --region="$REGION" --quiet || true
gcloud compute networks delete "$VPC" --quiet || true

gcloud artifacts repositories delete taskboard --location="$REGION" --quiet || true

# --- Uncomment the lines below to also wipe identities and secrets ---
# gcloud secrets delete jwt-secret --quiet || true
# gcloud secrets delete db-password --quiet || true
# gcloud iam service-accounts delete \
#   "github-deployer@${PROJECT_ID}.iam.gserviceaccount.com" --quiet || true

echo "Cleanup complete."
