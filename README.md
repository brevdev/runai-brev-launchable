# RunAI on [NVIDIA Brev](https://brev.nvidia.com/)

`setup_prereqs.sh` runs automatically when your instance is created. It installs Helm, Ingress, Prometheus, Knative, TLS certs, and CoreDNS.

## Prerequisites

- Brev instance with at least **24 CPUs**
- Port **443** open on the instance

## Deploy RunAI

**1. Set your JFrog token** (get this from Run:AI support):

```bash
export RUNAI_JFROG_TOKEN="your-token-here"
```

**2. Run the deploy script:**

```bash
./deploy_runai.sh
```

**3. On your local machine**, add the hosts entry printed at the end:

```bash
sudo bash -c 'echo "YOUR_PUBLIC_IP runai.brev.cloud" >> /etc/hosts'
```

**4. Open** https://runai.brev.cloud and accept the self-signed cert warning.

**5. Login:** `test@run.ai` / `Abcd!234`

## Re-deploy

Both scripts are idempotent. To tear down and redeploy:

```bash
./reset_runai.sh
./deploy_runai.sh
```

## Configuration

| Variable | Default |
|---|---|
| `RUNAI_DOMAIN` | `runai.brev.cloud` |
| `RUNAI_VERSION` | `2.24.37` |
| `RUNAI_CLUSTER_NAME` | `brev-cluster` |

## Troubleshooting

```bash
kubectl get pods -n runai-backend    # control plane pods
kubectl get pods -n runai            # cluster pods
```
