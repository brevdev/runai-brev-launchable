#!/bin/bash
# Installs RunAI control plane + cluster. Run after setting RUNAI_JFROG_TOKEN.
set -euo pipefail

RUNAI_DOMAIN="${RUNAI_DOMAIN:-runai.brev.cloud}"
RUNAI_VERSION="${RUNAI_VERSION:-2.24.37}"
RUNAI_CERT_DIR="${RUNAI_CERT_DIR:-/tmp/runai-certs}"
RUNAI_CLUSTER_NAME="${RUNAI_CLUSTER_NAME:-brev-cluster}"
RUNAI_USERNAME="${RUNAI_USERNAME:-test@run.ai}"
RUNAI_PASSWORD="${RUNAI_PASSWORD:-Abcd!234}"
RUNAI_CURL_INSECURE="${RUNAI_CURL_INSECURE:-0}"

log()  { echo "[$(date +'%H:%M:%S')] $*"; }
die()  { echo "[$(date +'%H:%M:%S')] ERROR: $*" >&2; exit 1; }

curl_flags=(); [[ "${RUNAI_CURL_INSECURE}" == "1" ]] && curl_flags+=("--insecure")

# --- Pre-flight ---
command -v helm >/dev/null || die "helm not found. Did setup_prereqs.sh run?"
command -v jq >/dev/null  || { sudo apt-get update -y >/dev/null && sudo apt-get install -y jq >/dev/null; }
[[ -n "${RUNAI_JFROG_TOKEN:-}" ]] || die "RUNAI_JFROG_TOKEN is not set. Run:  export RUNAI_JFROG_TOKEN=\"your-token\""
[[ -f "${RUNAI_CERT_DIR}/ca.crt" ]] || die "CA cert not found at ${RUNAI_CERT_DIR}/ca.crt — setup_prereqs.sh may not have run."

log "=== Deploying RunAI (${RUNAI_VERSION}) ==="

# --- Registry secret ---
log "Creating registry secret..."
kubectl delete secret runai-reg-creds -n runai-backend 2>/dev/null || true
kubectl create secret docker-registry runai-reg-creds -n runai-backend \
  --docker-server=runai.jfrog.io \
  --docker-username=self-hosted-image-puller-prod \
  --docker-password="${RUNAI_JFROG_TOKEN}" \
  --docker-email=support@run.ai

# --- Control plane ---
log "Installing control plane..."
helm repo add runai-backend https://runai.jfrog.io/artifactory/cp-charts-prod 2>/dev/null || true
helm repo update >/dev/null 2>&1
helm upgrade -i runai-backend runai-backend/control-plane -n runai-backend \
  --version "${RUNAI_VERSION}" \
  --set "global.domain=${RUNAI_DOMAIN}" \
  --set "global.customCA.enabled=true" \
  --set-file "global.customCA.caPEM=${RUNAI_CERT_DIR}/ca.crt" \
  --set "global.imagePullSecrets[0].name=runai-reg-creds" \
  --wait --timeout=25m

# Restart control plane pods so they pick up the latest CA secret
log "Restarting control plane pods..."
kubectl rollout restart deployment -n runai-backend 2>/dev/null || true
kubectl rollout restart statefulset -n runai-backend 2>/dev/null || true

# --- Ensure host can resolve the domain ---
grep -q "${RUNAI_DOMAIN}" /etc/hosts 2>/dev/null || echo "127.0.0.1 ${RUNAI_DOMAIN}" | sudo tee -a /etc/hosts >/dev/null

# --- Wait for control plane to roll out ---
# Keycloak comes up first, so a token-based readiness check is misleading.
# Block on every Deployment/StatefulSet in runai-backend reaching Ready.
log "Waiting for control plane rollout to complete..."
for r in $(kubectl get deployment,statefulset -n runai-backend -o name); do
  kubectl rollout status -n runai-backend "$r" --timeout=10m \
    || die "Rollout did not complete: $r"
done

log "Obtaining auth token..."
token=$(curl -fsS "${curl_flags[@]}" --location \
  --request POST "https://${RUNAI_DOMAIN}/auth/realms/runai/protocol/openid-connect/token" \
  --header 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode 'grant_type=password' \
  --data-urlencode 'client_id=runai' \
  --data-urlencode "username=${RUNAI_USERNAME}" \
  --data-urlencode "password=${RUNAI_PASSWORD}" \
  --data-urlencode 'scope=openid' \
  --data-urlencode 'response_type=id_token' | jq -r .access_token)
[[ -n "${token}" && "${token}" != "null" ]] || die "Failed to get auth token."

# --- Create or find cluster ---
log "Creating cluster '${RUNAI_CLUSTER_NAME}'..."
create_response=$(curl -sS "${curl_flags[@]}" -w "\n%{http_code}" \
  -X POST "https://${RUNAI_DOMAIN}/api/v1/clusters" \
  -H "Authorization: Bearer ${token}" \
  -H "Content-Type: application/json" \
  -H "accept: application/json" \
  -d "{\"name\":\"${RUNAI_CLUSTER_NAME}\",\"version\":\"${RUNAI_VERSION}\",\"domain\":\"${RUNAI_DOMAIN}\"}")
http_code=$(echo "${create_response}" | tail -1)
body=$(echo "${create_response}" | sed '$d')

if [[ "${http_code}" == "409" ]]; then
  log "Cluster already exists, looking up UUID..."
  uuid=$(curl -fsS "${curl_flags[@]}" \
    "https://${RUNAI_DOMAIN}/api/v1/clusters" \
    -H "Authorization: Bearer ${token}" \
    -H "accept: application/json" \
    | jq -r ".[] | select(.name==\"${RUNAI_CLUSTER_NAME}\") | .uuid")
elif [[ "${http_code}" =~ ^2 ]]; then
  uuid=$(echo "${body}" | jq -r .uuid)
else
  die "POST /api/v1/clusters returned HTTP ${http_code}: ${body}"
fi
[[ -n "${uuid}" && "${uuid}" != "null" ]] \
  || die "Cluster UUID empty (http=${http_code}, body=${body})."
log "Cluster UUID: ${uuid}"

# --- Install cluster ---
log "Retrieving cluster install command..."
installationStr=$(curl -fsS "${curl_flags[@]}" \
  "https://${RUNAI_DOMAIN}/api/v1/clusters/${uuid}/cluster-install-info?version=${RUNAI_VERSION}" \
  -H 'accept: application/json' \
  -H "Authorization: Bearer ${token}" \
  -H 'Content-Type: application/json' | jq -r .installationStr)
[[ -n "${installationStr}" && "${installationStr}" != "null" ]] || die "Failed to get install string."

evalStr=$(echo "${installationStr}" | sed '1,2d' | sed ':a;N;$!ba;s/\n/ /g' | tr '\\' ' ')
# Normalize to "helm upgrade --install" so re-runs don't fail with "name still in use"
evalStr=$(echo "${evalStr}" | sed -E 's/helm (upgrade -i|upgrade --install|install) /helm upgrade --install /g')
[[ "${evalStr}" =~ ^helm[[:space:]] ]] || die "Invalid install command: ${evalStr}"

# The cluster chart reads the CA from a K8s secret (created by setup_prereqs).
# Set enabled + explicit secret name/key so the chart mounts the CA into all pods.
[[ "${evalStr}" == *"global.customCA.enabled"* ]] || evalStr="${evalStr} --set global.customCA.enabled=true"
evalStr="${evalStr} --set global.customCA.secret.name=runai-ca-cert --set global.customCA.secret.key=runai-ca.pem"

# Ensure the cluster chart repo exists (JFrog requires auth for cluster charts)
log "Adding RunAI cluster Helm repo..."
helm repo add runai https://runai.jfrog.io/artifactory/api/helm/run-ai-charts --force-update \
  || die "Failed to add runai Helm repo. Check RUNAI_JFROG_TOKEN and network."
helm repo update || die "Failed to update Helm repos."

log "Installing cluster..."
eval "${evalStr}"

PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || echo "YOUR_PUBLIC_IP")
echo ""
echo "====================================================="
echo " Done! UI: https://${RUNAI_DOMAIN}"
echo " Login:    ${RUNAI_USERNAME} / ${RUNAI_PASSWORD}"
echo "====================================================="
echo ""
echo "On your LOCAL machine, run:"
echo ""
echo "  sudo bash -c 'echo \"${PUBLIC_IP} ${RUNAI_DOMAIN}\" >> /etc/hosts'"
echo ""
echo "Then open https://${RUNAI_DOMAIN} and accept the cert warning."
echo ""