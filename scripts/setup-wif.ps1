# Setup Workload Identity Federation for GitHub Actions → GCP.
# Run once from your local machine (PowerShell).
#
# Usage:
#   .\scripts\setup-wif.ps1 -Repo "your-github-user/your-repo"
#
# What this creates:
#   - A least-privilege service account (github-deployer)
#   - A workload identity pool + OIDC provider trusting GitHub
#   - An IAM binding that lets the specified repo impersonate the SA
#
# Prints at the end: the GCP_WIF_PROVIDER value you'll paste into GitHub
# repo secrets, plus the service-account email for GCP_SA_EMAIL.

param(
    [Parameter(Mandatory=$true)]
    [string]$Repo,

    [string]$Pool     = "github-pool",
    [string]$Provider = "github",
    [string]$Sa       = "github-deployer"
)

$ErrorActionPreference = "Stop"

$PROJECT_ID     = (gcloud config get-value project)
$PROJECT_NUMBER = (gcloud projects describe $PROJECT_ID --format='value(projectNumber)')

Write-Host "Project:      $PROJECT_ID ($PROJECT_NUMBER)"
Write-Host "Repo:         $Repo"
Write-Host "SA:           $Sa"
Write-Host "Pool/provider: $Pool / $Provider"
Write-Host ""

# 1) Create the service account GitHub will impersonate.
Write-Host "==> 1/4 Creating service account..."
gcloud iam service-accounts create $Sa `
    --display-name="GitHub Actions deployer"

# Wait until IAM sees the new SA — there's a propagation delay where the SA
# is "created" but role bindings still fail with "does not exist" for a few
# seconds. Poll until describe succeeds (max ~30s).
$saEmail = "${Sa}@${PROJECT_ID}.iam.gserviceaccount.com"
Write-Host "    waiting for service account to propagate..."
for ($i = 0; $i -lt 15; $i++) {
    gcloud iam service-accounts describe $saEmail 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { break }
    Start-Sleep -Seconds 2
}

# 2) Grant least-privilege roles. Retry once on failure to cover any residual
# propagation lag for the first binding.
Write-Host "==> 2/4 Granting roles..."
$roles = @(
    "roles/artifactregistry.writer",
    "roles/compute.instanceAdmin.v1",
    "roles/iap.tunnelResourceAccessor",
    "roles/iam.serviceAccountUser",
    "roles/secretmanager.secretAccessor"
)
foreach ($role in $roles) {
    Write-Host "    - $role"
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        gcloud projects add-iam-policy-binding $PROJECT_ID `
            --member="serviceAccount:$saEmail" `
            --role=$role `
            --condition=None `
            | Out-Null
        if ($LASTEXITCODE -eq 0) { break }
        Write-Host "      (attempt $attempt failed, retrying in 3s...)"
        Start-Sleep -Seconds 3
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to grant $role after 3 attempts"
        exit 1
    }
}

# 3) Create the workload identity pool + OIDC provider.
Write-Host "==> 3/4 Creating workload identity pool and provider..."
gcloud iam workload-identity-pools create $Pool `
    --location=global `
    --display-name="GitHub pool"

gcloud iam workload-identity-pools providers create-oidc $Provider `
    --location=global `
    --workload-identity-pool=$Pool `
    --display-name="GitHub provider" `
    --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" `
    --attribute-condition="assertion.repository == '$Repo'" `
    --issuer-uri="https://token.actions.githubusercontent.com"

# 4) Allow this repo's GitHub identity to impersonate the SA.
Write-Host "==> 4/4 Binding GitHub identity to the service account..."
gcloud iam service-accounts add-iam-policy-binding "${Sa}@${PROJECT_ID}.iam.gserviceaccount.com" `
    --role="roles/iam.workloadIdentityUser" `
    --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${Pool}/attribute.repository/$Repo"

# Done — print the values you need for GitHub repo secrets.
$wifProvider = "projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${Pool}/providers/${Provider}"

Write-Host ""
Write-Host "================================================================"
Write-Host " Done. Add these as GitHub repo secrets:"
Write-Host "================================================================"
Write-Host "  GCP_WIF_PROVIDER = $wifProvider"
Write-Host "  GCP_SA_EMAIL     = $saEmail"
Write-Host "================================================================"
