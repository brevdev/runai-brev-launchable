#!/bin/bash
# Runs automatically on instance creation. Sets up everything needed before the user gets access.
set -euo pipefail

DOMAIN="${RUNAI_DOMAIN:-runai.brev.cloud}"
VERSION="${RUNAI_VERSION:-2.24.37}"
CERT_DIR="${RUNAI_CERT_DIR:-/tmp/runai-certs}"

log() { echo "[$(date +'%H:%M:%S')] $*"; }

# --- Fix containerd (just in case) and verify k8s is up ---
sudo sed -i 's/^disabled_plugins = \["cri"\]/# disabled_plugins = ["cri"]/' \
  /var/snap/microk8s/current/args/containerd*.toml 2>/dev/null || true

log "Verifying k8s is ready..."
kubectl wait --for=condition=ready node --all --timeout=60s

# --- GPU support ---
# Brev's preflight ("Still waiting for GPUs") and Run:AI itself both require
# nvidia.com/gpu to appear in node Allocatable. microk8s ships a GPU addon that
# installs the NVIDIA GPU Operator (driver + device plugin). Enable it here.
log "Enabling microk8s GPU addon..."
sudo microk8s enable gpu 2>&1 | sed 's/^/  /' \
  || log "WARN: 'microk8s enable gpu' returned non-zero (may already be enabled)"

log "Waiting for nvidia.com/gpu to appear in node Allocatable (up to 10 min)..."
gpu_ready=0
for _ in $(seq 1 60); do
  if kubectl get nodes -o jsonpath='{.items[*].status.allocatable}' 2>/dev/null \
     | grep -q "nvidia.com/gpu"; then
    gpu_ready=1
    break
  fi
  sleep 10
done
if [[ "${gpu_ready}" -eq 1 ]]; then
  log "GPU allocatable on node(s)."
else
  echo "WARN: nvidia.com/gpu not allocatable after 10 minutes. Diagnose with:" >&2
  echo "  kubectl get nodes -o jsonpath='{.items[*].status.allocatable}'" >&2
  echo "  kubectl get pods -n gpu-operator-resources" >&2
  echo "  nvidia-smi" >&2
fi

# --- Helm ---
log "Installing Helm..."
command -v helm &>/dev/null || curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# --- Ingress (hostNetwork so it binds directly to port 443) ---
log "Installing Ingress..."
kubectl create ns ingress-nginx 2>/dev/null || true
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm upgrade -i ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx \
  --set controller.kind=DaemonSet --set controller.hostNetwork=true \
  --set controller.dnsPolicy=ClusterFirstWithHostNet --set controller.service.type=ClusterIP \
  --set controller.admissionWebhooks.enabled=false --wait --timeout=3m

# --- Namespaces ---
log "Creating namespaces..."
kubectl create ns runai-backend 2>/dev/null || true
kubectl create ns runai 2>/dev/null || true

# --- TLS certs (skip if already generated) ---
if [[ -f "${CERT_DIR}/ca.crt" && -f "${CERT_DIR}/bundle.crt" && -f "${CERT_DIR}/server.key" ]]; then
  log "TLS certificates already exist at ${CERT_DIR}, skipping generation."
  cd "${CERT_DIR}"
else
  log "Generating TLS certificates..."
  rm -rf "${CERT_DIR}" && mkdir -p "${CERT_DIR}" && cd "${CERT_DIR}"

  cat > ca.cnf <<'CAEOF'
[req]
default_bits = 4096
prompt = no
default_md = sha256
distinguished_name = dn
x509_extensions = v3_ca
[dn]
CN = Run:ai CA
[v3_ca]
basicConstraints = critical,CA:TRUE
keyUsage = critical,digitalSignature,keyCertSign,cRLSign
CAEOF

  cat > server.cnf <<SRVEOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = v3_req
[dn]
CN = ${DOMAIN}
[v3_req]
basicConstraints = CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth,clientAuth
subjectAltName = DNS:${DOMAIN},DNS:*.${DOMAIN},DNS:runai-backend-backend.runai-backend.svc,DNS:localhost
SRVEOF

  openssl req -x509 -new -nodes -days 3650 -newkey rsa:4096 -keyout ca.key -out ca.crt -config ca.cnf 2>/dev/null
  openssl req -new -nodes -newkey rsa:2048 -keyout server.key -out server.csr -config server.cnf 2>/dev/null
  openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out server.crt -days 365 -sha256 -extfile server.cnf -extensions v3_req 2>/dev/null
  cat server.crt ca.crt > bundle.crt
  sudo cp ca.crt /usr/local/share/ca-certificates/runai-ca.crt && sudo update-ca-certificates 2>/dev/null || true
  cp ca.crt ~/runai-ca.crt
  # Also copy to the script directory so it's easy to scp from a known path
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cp ca.crt "${SCRIPT_DIR}/runai-ca.crt"
fi

# --- K8s secrets (delete + recreate to stay in sync with certs on disk) ---
log "Creating K8s secrets..."
kubectl delete secret runai-backend-tls runai-ca-cert -n runai-backend 2>/dev/null || true
kubectl delete configmap runai-ca-bundle -n runai-backend 2>/dev/null || true
kubectl delete secret runai-ca-cert -n runai 2>/dev/null || true
kubectl create secret tls runai-backend-tls -n runai-backend --cert=bundle.crt --key=server.key
kubectl create configmap runai-ca-bundle -n runai-backend --from-file=ca.crt=ca.crt
kubectl create secret generic runai-ca-cert -n runai-backend --from-file=runai-ca.pem=ca.crt
kubectl create secret generic runai-ca-cert -n runai --from-file=runai-ca.pem=ca.crt
kubectl label secret runai-ca-cert -n runai-backend run.ai/cluster-wide=true --overwrite
kubectl label secret runai-ca-cert -n runai run.ai/cluster-wide=true --overwrite

# --- Prometheus ---
log "Installing Prometheus..."
kubectl create ns monitoring 2>/dev/null || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm upgrade -i prometheus prometheus-community/kube-prometheus-stack -n monitoring \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --wait --timeout=5m

# --- Knative ---
log "Installing Knative..."
kubectl apply -f https://github.com/knative/serving/releases/download/knative-v1.18.2/serving-crds.yaml 2>/dev/null || true
sleep 3
kubectl apply -f https://github.com/knative/serving/releases/download/knative-v1.18.2/serving-core.yaml 2>/dev/null || true
kubectl apply -f https://github.com/knative/serving/releases/download/knative-v1.18.2/serving-hpa.yaml 2>/dev/null || true
kubectl wait --for=condition=ready pod -l app=controller -n knative-serving --timeout=120s 2>/dev/null || true
kubectl patch configmap/config-features -n knative-serving --type merge -p '{"data":{"kubernetes.podspec-schedulername":"enabled","kubernetes.podspec-nodeselector":"enabled","kubernetes.podspec-affinity":"enabled","kubernetes.podspec-tolerations":"enabled","multi-container":"enabled"}}' 2>/dev/null || true

# --- Host DNS (so curl from the instance can resolve the domain) ---
log "Adding ${DOMAIN} to /etc/hosts..."
grep -q "${DOMAIN}" /etc/hosts 2>/dev/null || echo "127.0.0.1 ${DOMAIN}" | sudo tee -a /etc/hosts >/dev/null

# --- CoreDNS ---
log "Configuring CoreDNS..."
INGRESS_IP=$(kubectl get svc -n ingress-nginx -o jsonpath="{.items[0].spec.clusterIP}" 2>/dev/null || echo "10.152.183.1")
kubectl apply -f - <<COREDNS
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health
        ready
        hosts {
           ${INGRESS_IP} ${DOMAIN}
           fallthrough
        }
        kubernetes cluster.local in-addr.arpa ip6.arpa {
           pods insecure
           fallthrough in-addr.arpa ip6.arpa
           ttl 30
        }
        prometheus :9153
        forward . /etc/resolv.conf
        cache 30
        loop
        reload
        loadbalance
    }
COREDNS
kubectl rollout restart deployment coredns -n kube-system 2>/dev/null || true

# --- RunAI Helm repos ---
log "Adding RunAI Helm repos..."
helm repo add runai-backend https://runai.jfrog.io/artifactory/cp-charts-prod 2>/dev/null || true
helm repo add runai https://runai.jfrog.io/artifactory/api/helm/run-ai-charts --force-update
helm repo update

log "Prerequisites ready."