# K3s Cluster Setup Documentation

This documentation covers the complete setup of a K3s cluster with Flux for GitOps and Vault for secrets management.

## Table of Contents

- [Mesh VPN Installation](#mesh-vpn-installation)
- [K3s Installation](#k3s-installation)
- [Control Plane Setup](#control-plane-setup)
- [Worker Node Setup](#worker-node-setup)
- [Mac Worker via Multipass](#mac-worker-via-multipass)
- [Flux Installation](#flux-installation)
- [Helm Installation](#helm-installation)
- [Vault Installation](#vault-installation)
- [MinIO Installation](#minio-installation)
- [Phoenix Installation](#phoenix-installation)
- [OpenObserve Installation](#openobserve-installation)
- [Inference API Services](#inference-api-services)
- [Troubleshooting](#troubleshooting)

## Mesh VPN for mac os workers

### (Optional) Install Headscale server and tailscale clients for mac os colima vm as a worker

You need to headscale server on your choosen server

```bash
mkdir -p ./headscale/{config,lib,run}

cd ./headscale

docker run \
  --name headscale \
  --detach \
  --volume "$(pwd)/config:/etc/headscale" \
  --volume "$(pwd)/lib:/var/lib/headscale" \
  --volume "$(pwd)/run:/var/run/headscale" \
  --publish 0.0.0.0:8080:8080 \
  --publish 0.0.0.0:9090:9090 \
  docker.io/headscale/headscale:<VERSION> \
  serve

docker exec -it headscale \
  headscale users create myfirstuser

curl -fsSL https://tailscale.com/install.sh | sh

sudo tailscale up --login-server=http://<IP_SERVER>:8080

headscale nodes register --user USERNAME --key <GENERATED_KEY>
```

## K3s Installation

### Control Plane Setup

#### 1. Basic Installation

```bash
curl -sfL https://get.k3s.io | sh -
```

#### 2. Troubleshooting cgroups v2 (Raspberry Pi OS)

If you encounter the error "failed to find memory cgroup (v2)", follow these steps:

**Enable cgroups v2:**

1. Edit the boot configuration:

```bash
sudo nano /boot/firmware/cmdline.txt
```

2. Add the following parameters to the end of the existing line (everything must be on one line):

```
cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1
```

3. Reboot the Raspberry Pi:

```bash
sudo reboot
```

4. Restart K3s service:

```bash
sudo systemctl start k3s
sudo systemctl status k3s
```

5. Verify the cluster is working:

```bash
sudo k3s kubectl get nodes
```

### Worker Node Setup

#### 1. Get Control Plane Information

On the control plane node, retrieve the token and IP:

```bash
# Get the node token
sudo cat /var/lib/rancher/k3s/server/node-token

# Get the control plane IP
hostname -I
```

#### 2. Install K3s Agent (Worker)

On the worker node, run:

```bash
curl -sfL https://get.k3s.io | K3S_URL=https://CONTROL_PLANE_IP:6443 K3S_TOKEN=YOUR_TOKEN sh -
```

or

```bash
curl -sfL https://get.k3s.io | K3S_URL=https://CONTROL_PLANE_IP:6443 \
  K3S_TOKEN=YOUR_TOKEN \
  sh -s - --node-ip=$(tailscale ip -4)
```

Replace:

- `CONTROL_PLANE_IP` with the actual IP of your control plane
- `YOUR_TOKEN` with the token from the previous step

#### 3. Verify Worker Installation

```bash
sudo systemctl status k3s-agent
```

### Mac Worker via Colima

For Mac systems, use Colima to create a Ubuntu VM:

#### 1. Create VM

```bash
colima start --cpu 4 --memory 4 --disk 30
```

#### 2. Access VM and Install Worker

```bash
colima ssh
```

Then follow the worker installation steps above within the VM.

## Flux Installation

### 1. Install Flux CLI

**macOS:**

```bash
brew install fluxcd/tap/flux
```

**Linux:**

```bash
curl -s https://fluxcd.io/install.sh | sudo bash
```

### 2. Install Flux in Cluster

```bash
flux install
```

### 3. Verify Flux Installation

After installation, you should see Flux components running:

```bash
kubectl get pods -A
```

Expected output should include:

```
NAMESPACE     NAME                                       READY   STATUS    RESTARTS   AGE
flux-system   helm-controller-5c898f4887-568tw           1/1     Running   0          28s
flux-system   kustomize-controller-7bcf986f97-67hfv      1/1     Running   0          28s
flux-system   notification-controller-5f66f99d4d-s6qll   1/1     Running   0          28s
flux-system   source-controller-54bc45dc6-7zcpk          1/1     Running   0          28s
```

## Helm Installation

Helm is required for installing Vault and other applications in the cluster.

### 1. Install Helm CLI

**macOS:**

```bash
brew install helm
```

**Linux:**

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

### 2. Verify Helm Installation

```bash
helm version
```

## Vault Installation

### 1. Add Helm Repository

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
```

### 2. Install OpenBao

```bash
helm install openbao openbao/openbao --namespace soludev -f config/dev/openbao/values.yaml
```

Note: Make sure you have a `values.yaml` file configured for your Vault setup.

### 3. Initialize and Unseal Vault

#### Initialize Vault

```bash
kubectl exec -n soludev openbao-0 -- vault operator init
```

This command will output unseal keys and a root token. **Save these securely!**

#### Unseal Vault

Use any 3 of the 5 unseal keys provided during initialization:

```bash
kubectl exec -n soludev openbao-0 -- vault operator unseal '<key1>'
kubectl exec -n soludev openbao-0 -- vault operator unseal '<key2>'
kubectl exec -n soludev openbao-0 -- vault operator unseal '<key3>'
```

Replace `<key1>`, `<key2>`, and `<key3>` with actual unseal keys from the initialization step.

### 4. Enable Kubernetes Authentication

After unsealing Vault, you need to enable and configure Kubernetes authentication to allow pods to authenticate with Vault.

#### Addexternal secrets CRD

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
helm install external-secrets external-secrets/external-secrets \
    -n external-secrets-system
```

#### Enable Kubernetes Auth Method

```bash
export VAULT_TOKEN=<YOUR_TOKEN>
kubectl exec -n soludev openbao-0 -- \
  env VAULT_TOKEN="$VAULT_TOKEN" \
  bao auth enable kubernetes
```

#### Create Service Account for Vault Authentication

```bash
# Create service account
kubectl create serviceaccount openbao-auth -n soludev

# Create cluster role binding
kubectl create clusterrolebinding openbao-auth \
  --clusterrole=system:auth-delegator \
  --serviceaccount=soludev:openbao-auth

kubectl create serviceaccount external-secrets-sa -n soludev

# Generate token for the service account
kubectl create token openbao-auth -n soludev 
```

#### Configure Kubernetes Auth in Vault

```bash
# Get the Kubernetes host URL (usually the API server)
K8S_HOST=$(kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[].cluster.server}')

# Get the service account token
SA_TOKEN=$(kubectl create token openbao-auth -n kaiohz)

# Get the CA certificate
K8S_CA_CERT=$(kubectl get configmap kube-root-ca.crt -o jsonpath='{.data.ca\.crt}')

# Configure the Kubernetes auth method
kubectl exec -n soludev openbao-0 -- env VAULT_TOKEN="$VAULT_TOKEN" \
  bao write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  disable_iss_validation=true
```

#### Create a Role for External Secrets

```bash
kubectl exec -n soludev openbao-0 -- env VAULT_TOKEN="$VAULT_TOKEN" \
  bao write auth/kubernetes/role/external-secrets-role \
  bound_service_account_names=external-secrets-sa \
  bound_service_account_namespaces=soludev \
  policies=external-secrets-policy \
  ttl=24h
```

#### Create Policy for External Secrets

```bash
kubectl exec -n soludev openbao-0 -- sh -c "echo 'path \"kv/data/*\" {
  capabilities = [\"read\", \"list\"]
}
path \"kv/metadata/*\" {
  capabilities = [\"read\", \"list\"]
}' | env VAULT_TOKEN=\"$VAULT_TOKEN\" bao policy write external-secrets-policy -"
```

## Flux GitOps Configuration

After installing Flux, you need to configure GitRepository and Kustomization resources to enable GitOps workflows.

### 1. Create GitRepository Configuration

Create a GitRepository resource to tell Flux where to find your configuration:

```yaml
# config/dev/gitrepository.yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: kaiohz-repo
  namespace: flux-system
spec:
  interval: 1m
  url: https://github.com/Kaiohz/flux.git
  ref:
    branch: main
```

Apply the configuration:

```bash
kubectl apply -f config/dev/gitrepository.yaml
```

### 2. Create Kustomization Configuration

Create a Kustomization resource to define how Flux should reconcile your manifests:

```yaml
# config/dev/kustomization.yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: kaiohz-kustomization
  namespace: flux-system
spec:
  interval: 2m
  timeout: 90s
  wait: false # set wait to true if you deploy resources like Deployment, ConfigMap without Helm, for HelmRelease set wait to false
  targetNamespace: kaiohz
  sourceRef:
    kind: GitRepository
    name: kaiohz-repo
  # If the helmreleases are in a directory use the parameter below
  path: "dev"
  #When the Git revision changes, the manifests are reconciled automatically. If previously applied objects are missing from the current revision, these objects are deleted from the cluster when spec.prune is enabled
  prune: true
```

Apply the configuration:

```bash
kubectl apply -f config/dev/kustomization.yaml
```

### 3. Additional GitRepository for External Projects

You can also configure additional GitRepository resources for external projects:

```yaml
# dev/gitrepositories.yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: prospection-api-mcp
  namespace: kaiohz
spec:
  interval: 2m
  url: https://github.com/Kaiohz/prospectio-api-mcp.git
  ref:
    branch: main
```

Apply the configuration:

```bash
kubectl apply -f dev/gitrepositories.yaml
```

## Inference API Services

This section covers setting up services to access inference APIs running on external machines (Jetson) from within the K3s cluster.

### Overview

The inference services allow pods in the cluster to access AI inference APIs running on external machines using standard Kubernetes service discovery. This enables applications to use inference endpoints via cluster-internal URLs.

### 1. Jetson Inference Service

For accessing the Ollama inference API running on a Jetson device:

```yaml
# dev/ollama-inference-jetson.yaml
apiVersion: v1
kind: Service
metadata:
  name: ollama-inference-jetson
  namespace: kaiohz
spec:
  type: ExternalName
  externalName: 192.168.1.6  # Replace with your Jetson IP
  ports:
    - port: 11434
```

**Access from pods:**

```
http://ollama-inference-jetson.kaiohz.svc.cluster.local:11434
```

### 2. Mac Inference Service

For accessing the inference API running on a Mac:

```yaml
# dev/ollama-inference-mac.yaml
apiVersion: v1
kind: Service
metadata:
  name: ollama-inference-mac
  namespace: kaiohz
spec:
  type: ExternalName
  externalName: 192.168.1.10  # Replace with your Mac IP
  ports:
    - port: 11434
```

**Access from pods:**

```
http://ollama-inference-mac.kaiohz.svc.cluster.local:11434
```

### 3. Service Configuration Options

**ExternalName Service:**

- `type: ExternalName`: Creates a CNAME record pointing to the external host
- `externalName`: IP address or hostname of the external service
- `ports`: Port mapping for the service

**Alternative: Endpoint-based Service**

For more control, you can create a service with explicit endpoints:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: mac-inference-endpoints
  namespace: kaiohz
spec:
  ports:
    - port: 11434
      targetPort: 11434
      protocol: TCP
---
apiVersion: v1
kind: Endpoints
metadata:
  name: mac-inference-endpoints
  namespace: kaiohz
subsets:
  - addresses:
      - ip: 192.168.1.10  # Mac IP
    ports:
      - port: 11434
```

### 4. Usage in Applications

In your application pods, you can now access the inference APIs using cluster-internal URLs:

```yaml
# Example deployment using the inference service
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
spec:
  template:
    spec:
      containers:
        - name: app
          image: my-app:latest
          env:
            - name: MAC_INFERENCE_URL
              value: "http://ollama-inference-mac.kaiohz.svc.cluster.local:11434"
            - name: JETSON_INFERENCE_URL
              value: "http://ollama-inference-jetson.kaiohz.svc.cluster.local:11434"
```

### 5. Health Checks and Monitoring

You can add health checks to monitor the external services:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: inference-healthcheck
spec:
  containers:
    - name: healthcheck
      image: curlimages/curl
      command:
        - /bin/sh
        - -c
        - |
          while true; do
            echo "Checking Mac inference..."
            curl -f http://ollama-inference-mac.kaiohz.svc.cluster.local:11434/health || echo "Mac inference down"
            echo "Checking Jetson inference..."
            curl -f http://ollama-inference-jetson.kaiohz.svc.cluster.local:11434/health || echo "Jetson inference down"
            sleep 30
          done
```

### 6. Network Requirements

Ensure that:

1. The external machines (Mac/Jetson) are accessible from the K3s cluster nodes
2. Firewall rules allow traffic on the inference API ports (11434)
3. The inference services are running and bound to the correct network interfaces

### 7. Apply the Services

Deploy the inference services to your cluster:

```bash
# Apply Jetson service
kubectl apply -f dev/ollama-inference-jetson.yaml

# Apply Mac service
kubectl apply -f dev/ollama-inference-mac.yaml

# Verify services are created
kubectl get services -A | grep inference
```

### 8. Testing Connectivity

Test the services from within the cluster:

```bash
# Create a test pod
kubectl run test-pod --image=curlimages/curl --rm -it -- /bin/sh

# Test Mac inference service
curl http://ollama-inference-mac:11434

# Test Jetson inference service
curl http://ollama-inference-jetson:11434
```

### 9. Verify Flux GitOps Setup

Check that Flux is monitoring your repositories:

```bash
# Check GitRepository resources
kubectl get gitrepositories -A

# Check Kustomization resources
kubectl get kustomizations -A

# Check Flux reconciliation status
flux get sources git
flux get kustomizations
```

### 10. Directory Structure for GitOps

Your repository should be structured like this for optimal GitOps workflow:

```
flux/
├── config/
│   └── dev/
│       ├── gitrepository.yaml    # Main repo configuration
│       └── kustomization.yaml    # Main kustomization
└── dev/
    ├── gitrepositories.yaml      # Additional repos
    ├── pgvector/                 # Application manifests
    ├── prospectio-api-mcp/       # Application manifests
    └── vault/                    # Vault configuration
```

### Configuration Options

**GitRepository Parameters:**

- `interval`: How often Flux checks for changes
- `url`: Git repository URL (HTTPS or SSH)
- `ref.branch`: Branch to monitor
- `ref.tag`: Specific tag to use (alternative to branch)

**Kustomization Parameters:**

- `interval`: How often to reconcile manifests
- `timeout`: Maximum time for reconciliation
- `wait`: Whether to wait for resources to be ready
- `targetNamespace`: Default namespace for resources
- `path`: Directory in the repo containing manifests
- `prune`: Remove resources not present in the current revision

## Traefik CRD Installation

### Prerequisites

Before deploying IngressRouteTCP resources, ensure Traefik CRDs are installed in your cluster.

### Option 1: Install CRDs manually

```bash
kubectl apply -f https://raw.githubusercontent.com/traefik/traefik/v3.3.6/docs/content/reference/dynamic-configuration/kubernetes-crd-definition-v1.yml
```

### Option 2: Install CRDs via Helm Chart

Add `installCRDs: true` to your Traefik HelmChart values:

```yaml
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: traefik
  namespace: kube-system
spec:
  chart: https://%{KUBERNETES_API}%/static/charts/traefik-34.2.1+up34.2.0.tgz
  valuesContent: |-
    installCRDs: true
    additionalArguments:
      - "--entrypoints.postgres.address=:5432/tcp"
    ports:
      postgres:
        port: 5432
        expose:
          default: true
        exposedPort: 5432
        protocol: TCP
    # ... rest of your configuration
```

### Verify CRDs Installation

Check if Traefik CRDs are installed:

```bash
kubectl get crd | grep traefik
```

You should see output similar to:

```
ingressroutes.traefik.containo.us
ingressroutetcps.traefik.containo.us
ingressrouteudps.traefik.containo.us
middlewares.traefik.containo.us
middlewaretcps.traefik.containo.us
serverstransports.traefik.containo.us
tlsoptions.traefik.containo.us
tlsstores.traefik.containo.us
traefikservices.traefik.containo.us
```

### CRD Troubleshooting

If you get the error "no matches for kind 'IngressRouteTCP'", it means the CRDs are not installed. Follow one of the installation methods above.

Common issues:

- **CRDs not found**: Ensure Traefik is deployed with `installCRDs: true` or install manually
- **Version mismatch**: Make sure the CRD version matches your Traefik version
- **Permissions**: Ensure you have cluster-admin permissions to install CRDs

## Synchronizing Vault secrets to K3s

This section explains how to automatically synchronize secrets stored in Vault to Kubernetes secrets using External Secrets Operator (ESO).

### 1. Installing External Secrets Operator

#### Via Helm (recommended)

```bash
# Add the repo
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

# Install ESO
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets-system \
  --create-namespace

# Verify installation
kubectl get pods -n external-secrets-system
```

#### Via YAML manifests (alternative)

```bash
kubectl apply -f https://raw.githubusercontent.com/external-secrets/external-secrets/main/deploy/crds/bundle.yaml
kubectl apply -f https://raw.githubusercontent.com/external-secrets/external-secrets/main/deploy/charts/external-secrets/templates/deployment.yaml
```

### 2. SecretStore Configuration

#### Create the SecretStore

```yaml
# vault-secret-store.yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: vault-backend
  namespace: kaiohz
spec:
  provider:
    vault:
      server: "http://vault.kaiohz.svc.cluster.local:8200"
  path: "secret"          # Path to your KV engine
  version: "v2"           # Version of the KV engine (v1 or v2)
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "external-secrets-role"
          serviceAccountRef:
            name: "external-secrets-sa"
```

```bash
# Apply the configuration
kubectl apply -f vault-secret-store.yaml

# Verify the SecretStore
kubectl get secretstore vault-backend -n kaiohz
kubectl describe secretstore vault-backend -n kaiohz
```

### 3. Create secrets in Vault (examples)

#### Via Vault UI

- Secrets > secret/ (or your engine)
- Create secret

Example structures:

```
# Secrets for an application
Path: myapp/database
- username: mydbuser
- password: supersecret123
- host: db.example.com
- port: 5432

# Secrets for the API
Path: myapp/api
- key: abc123xyz
- secret: def456uvw
- endpoint: https://api.example.com

# Secrets for certificates
Path: myapp/tls
- cert: -----BEGIN CERTIFICATE-----...
- key: -----BEGIN PRIVATE KEY-----...
```

#### Via Vault CLI

```bash
# Secrets de base de données
vault kv put secret/myapp/database \
    username=mydbuser \
    password=supersecret123 \
    host=db.example.com \
    port=5432

# Secrets d'API
vault kv put secret/myapp/api \
    key=abc123xyz \
    secret=def456uvw \
    endpoint=https://api.example.com

# Configuration générale
vault kv put secret/myapp/config \
    env=production \
    debug=false \
    log_level=info
```

### 4. Create ExternalSecrets

#### Basic ExternalSecret - Individual secrets

```yaml
# myapp-database-secret.yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: myapp-database
  namespace: kaiohz
spec:
  refreshInterval: 60s  # Synchronize every minute
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: myapp-db-secret    # Name of the K8s secret to be created
    creationPolicy: Owner    # ESO manages the secret
    type: Opaque            # Type of K8s secret
  data:
  - secretKey: DB_USERNAME        # Key in the K8s secret
    remoteRef:
      key: myapp/database        # Path in Vault
      property: username         # Specific property
  - secretKey: DB_PASSWORD
    remoteRef:
      key: myapp/database
      property: password
  - secretKey: DB_HOST
    remoteRef:
      key: myapp/database
      property: host
  - secretKey: DB_PORT
    remoteRef:
      key: myapp/database
      property: port
```

#### ExternalSecret - Full secret synchronization

```yaml
# myapp-api-secret.yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: myapp-api
  namespace: kaiohz
spec:
  refreshInterval: 30s
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: myapp-api-secret
    creationPolicy: Owner
  dataFrom:
  - extract:
    key: myapp/api  # Retrieves ALL keys from this Vault secret
```

#### ExternalSecret - TLS Secret

```yaml
# myapp-tls-secret.yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: myapp-tls
  namespace: kaiohz
spec:
  refreshInterval: 300s  # 5 minutes for certificates
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: myapp-tls-secret
    creationPolicy: Owner
  type: kubernetes.io/tls  # Special type for TLS
  data:
  - secretKey: tls.crt
    remoteRef:
      key: myapp/tls
      property: cert
  - secretKey: tls.key
    remoteRef:
      key: myapp/tls
      property: key
```

### 5. Apply the ExternalSecrets

```bash
# Apply all ExternalSecrets
kubectl apply -f myapp-database-secret.yaml
kubectl apply -f myapp-api-secret.yaml
kubectl apply -f myapp-tls-secret.yaml

# Check status
kubectl get externalsecrets -n kaiohz

# View details (important for debugging)
kubectl describe externalsecret myapp-database -n kaiohz
```

### 6. Verify that K8s secrets are created

```bash
# List created secrets
kubectl get secrets -n kaiohz | grep myapp

# View the content of a secret (base64)
kubectl get secret myapp-db-secret -n kaiohz -o yaml

# Decode a secret to verify
kubectl get secret myapp-db-secret -n kaiohz -o jsonpath='{.data.DB_USERNAME}' | base64 -d
```

### 7. Use the secrets in your applications

#### In a Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
  namespace: kaiohz
spec:
  replicas: 1
  selector:
    matchLabels:
      app: myapp
  template:
    metadata:
      labels:
        app: myapp
    spec:
      containers:
      - name: app
        image: myapp:latest
        env:
        # Environment variables from secrets
        - name: DB_USERNAME
          valueFrom:
            secretKeyRef:
              name: myapp-db-secret
              key: DB_USERNAME
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: myapp-db-secret
              key: DB_PASSWORD
        - name: API_KEY
          valueFrom:
            secretKeyRef:
              name: myapp-api-secret
              key: key
        # Volume for TLS certificates
        volumeMounts:
        - name: tls-certs
          mountPath: /etc/ssl/certs/app
          readOnly: true
      volumes:
      - name: tls-certs
        secret:
          secretName: myapp-tls-secret
```

#### Environment variables from an entire secret

```yaml
    envFrom:
    - secretRef:
      name: myapp-api-secret  # All keys become environment variables
```

### 8. Configure NFS server inside Colima

Run these commands inside the Colima VM:

# Create storage directory

sudo mkdir -p /var/lib/k3s-storage
sudo chmod 777 /var/lib/k3s-storage

# Install NFS server

sudo apt update
sudo apt install -y nfs-kernel-server

# Configure NFS export for Headscale network

echo "/var/lib/k3s-storage 100.64.0.0/10(rw,sync,no_subtree_check,no_root_squash,insecure)" | sudo tee -a /etc/exports

# Apply and start

sudo exportfs -ra
sudo systemctl enable nfs-kernel-server
sudo systemctl restart nfs-kernel-server

# Verify

showmount -e localhost

Test port NFS (2049)
bash# Avec netcat
nc -zv <IP_HEADSCALE_COLIMA> 2049

# Ou avec telnet

telnet <IP_HEADSCALE_COLIMA> 2049

# Ou avec nmap si installé

nmap -p 2049 <IP_HEADSCALE_COLIMA>

## MinIO Installation

MinIO is a high-performance, S3-compatible object storage service. This section covers deploying MinIO in your K3s cluster using Helm.

### 1. Add MinIO Helm Repository

```bash
helm repo add minio https://charts.min.io/
helm repo update
```

### 2. Create MinIO Namespace

```bash
kubectl create namespace minio
```

### 3. Configure MinIO Values

Create or update your `config/dev/minio/values.yaml` file with the following configuration:

```yaml
# MinIO Helm values
mode: standalone
replicas: 1

# Root credentials (change these in production!)
rootUser: minioadmin
rootPassword: minioadmin

# Storage configuration
persistence:
  enabled: true
  storageClass: nfs-cluster-global  # Use your storage class
  size: 50Gi                        # Adjust based on your PV capacity

# Resource limits
resources:
  requests:
    memory: 512Mi
    cpu: 250m
  limits:
    memory: 1Gi
    cpu: 500m

# Service configuration
service:
  type: ClusterIP
  port: 9000

consoleService:
  type: ClusterIP
  port: 9001

# Auto-create buckets
buckets:
  - name: documents
    policy: none
  - name: uploads
    policy: none
```

### 4. Install MinIO with Helm

```bash
helm install minio minio/minio \
  -n minio \
  -f config/dev/minio/values.yaml
```

### 5. Verify MinIO Installation

```bash
# Check if MinIO pod is running
kubectl get pods -n minio

# Check PVC binding
kubectl get pvc -n minio

# View MinIO service
kubectl get svc -n minio
```

### 6. Access MinIO Console

#### Port Forward (Development)

```bash
kubectl port-forward -n minio svc/minio 9001:9001
```

Then access the console at: `http://localhost:9001`

#### Using Ingress (Production)

Create an Ingress resource to expose MinIO API and Console:

```yaml
# dev/minio/ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: minio-ingress
  namespace: minio
spec:
  rules:
    # MinIO Console
    - host: minio-console.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: minio
                port:
                  number: 9001
    # MinIO API
    - host: minio-api.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: minio
                port:
                  number: 9000
```

Apply the ingress:

```bash
kubectl apply -f dev/minio/ingress.yaml
```

### 7. Create Access Keys

After MinIO is running, create access keys for applications:

```bash
# Port forward to MinIO
kubectl port-forward -n minio svc/minio 9001:9001 &

# Access console at http://localhost:9001
# Login with minioadmin/minioadmin
# Create new access key under "Access Keys"
```

Or use MinIO CLI:

```bash
# Install MinIO CLI
curl https://dl.min.io/client/mc/release/darwin-amd64/mc \
  -o /usr/local/bin/mc
chmod +x /usr/local/bin/mc

# Configure MinIO alias
mc config host add minio http://localhost:9000 minioadmin minioadmin

# Create service account
mc admin user svcacct add minio minioadmin
```

### 8. Use MinIO in Applications

#### Store Credentials in Kubernetes Secret

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: minio-credentials
  namespace: default
type: Opaque
stringData:
  MINIO_ROOT_USER: minioadmin
  MINIO_ROOT_PASSWORD: minioadmin
  MINIO_ENDPOINT: minio.minio.svc.cluster.local:9000
  MINIO_USE_SSL: "false"
```

#### Use in Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-with-minio
  namespace: default
spec:
  template:
    spec:
      containers:
        - name: app
          image: myapp:latest
          envFrom:
            - secretRef:
                name: minio-credentials
          env:
            - name: MINIO_BUCKET
              value: "uploads"
```

### 9. Configure MinIO for Multiple Namespaces

If you need MinIO access from multiple namespaces, create a PersistentVolumeClaim in each namespace:

```yaml
# Each namespace needs its own PVC
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minio-pvc
  namespace: my-app-namespace
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: nfs-cluster-global
  resources:
    requests:
      storage: 20Gi  # Size per namespace claim
```

### 10. MinIO Management Commands

```bash
# Check MinIO status
kubectl get all -n minio

# View MinIO logs
kubectl logs -n minio -l app=minio -f

# Scale MinIO (for HA setup, change mode to distributed)
kubectl scale statefulset minio -n minio --replicas=3

# Delete MinIO (data persists if using Retain policy)
helm uninstall minio -n minio

# Delete MinIO with data
kubectl delete namespace minio
```

### 11. Troubleshooting MinIO

**PVC not binding:**

```bash
kubectl describe pvc -n minio
kubectl get pv
```

**Pod stuck in Pending:**

```bash
kubectl describe pod -n minio -l app=minio
```

**Connection issues from applications:**

- Verify DNS resolution: `kubectl run -it --rm debug --image=busybox --restart=Never -- nslookup minio.minio.svc.cluster.local`
- Check network policies and firewall rules
- Verify credentials are correct

## Phoenix Installation

Phoenix is an open-source AI observability platform for LLM applications. This section covers deploying Phoenix in your K3s cluster with external PostgreSQL and secrets managed by OpenBao.

### Prerequisites

- Running PostgreSQL instance in the cluster
- OpenBao/Vault configured and unsealed
- External Secrets Operator installed
- Helm 3.x installed

### Important Notes

**Chart Version Limitations:**

- Phoenix Helm chart version 4.0.6 does NOT support the `additionalEnv` parameter for injecting external secrets
- The chart always creates its own secret for authentication credentials
- Cannot use `auth.name` to point directly to an external secret (causes ownership conflicts with External Secrets Operator)
- Secrets must be provided at Helm upgrade time via command-line or temporary values file

**Secret Requirements:**

- `PHOENIX_SECRET`: Must be at least 32 characters long
- `PHOENIX_ADMIN_SECRET`: Must be at least 32 characters long
- Other secrets can be any length

### 1. Prepare PostgreSQL Database

Before installing Phoenix, create a dedicated database and user in your PostgreSQL instance.

#### Connect to PostgreSQL

```bash
# Find your PostgreSQL pod
kubectl get pods -n soludev | grep postgres

# Connect to PostgreSQL
kubectl exec -it -n soludev <postgres-pod-name> -- psql -U <postgres-user>
```

#### Create Database and User

```sql
-- Create the phoenix user
CREATE USER phoenix WITH PASSWORD 'your-secure-password';

-- Create the phoenix database
CREATE DATABASE phoenix OWNER phoenix;

-- Grant permissions
GRANT ALL PRIVILEGES ON DATABASE phoenix TO phoenix;

-- Verify
\l  -- List databases
\du -- List users
```

### 2. Create Secrets in OpenBao

Phoenix requires several secrets to be stored in OpenBao. Create them with the following structure:

#### Generate Strong Secrets

```bash
# Generate 32+ character secrets for PHOENIX_SECRET and PHOENIX_ADMIN_SECRET
openssl rand -base64 32  # For PHOENIX_SECRET
openssl rand -base64 32  # For PHOENIX_ADMIN_SECRET

# Generate other secrets
openssl rand -base64 16  # For PHOENIX_SMTP_PASSWORD (if using email)
openssl rand -base64 16  # For PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD
```

#### Store Secrets in OpenBao

Using the OpenBao CLI:

```bash
# Set your vault token
export VAULT_TOKEN=<your-root-token>

# Port forward to OpenBao (if needed)
kubectl port-forward -n soludev svc/openbao 8200:8200 &

# Store Phoenix secrets
kubectl exec -n soludev openbao-0 -- env VAULT_TOKEN="$VAULT_TOKEN" \
  bao kv put soludev/phoenix \
  PHOENIX_SECRET="<your-32+-char-secret>" \
  PHOENIX_ADMIN_SECRET="<your-32+-char-secret>" \
  PHOENIX_POSTGRES_PASSWORD="<your-db-password>" \
  PHOENIX_SMTP_PASSWORD="" \
  PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD="<your-admin-password>"
```

**Using the OpenBao UI:**

1. Port forward to OpenBao: `kubectl port-forward -n soludev svc/openbao 8200:8200`
2. Access UI at `http://localhost:8200`
3. Login with your root token
4. Navigate to **Secrets** → **soludev/**
5. Create a new secret named `phoenix`
6. Add the following keys:
   - `PHOENIX_SECRET` (32+ characters)
   - `PHOENIX_ADMIN_SECRET` (32+ characters)
   - `PHOENIX_POSTGRES_PASSWORD` (your database password)
   - `PHOENIX_SMTP_PASSWORD` (empty string if not using email)
   - `PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD` (admin password)

### 3. Configure ExternalSecret

Create an ExternalSecret resource to sync secrets from OpenBao to Kubernetes:

```yaml
# dev/soludev/phoenix/external-secret.yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: soludev-phoenix-external-secret
  namespace: soludev
spec:
  refreshInterval: 60s
  secretStoreRef:
    name: openbao-backend
    kind: ClusterSecretStore
  target:
    name: soludev-phoenix-secret
    creationPolicy: Owner
  dataFrom:
  - extract:
      key: soludev/phoenix
```

Apply the ExternalSecret (if not using Flux):

```bash
kubectl apply -f dev/soludev/phoenix/external-secret.yaml
```

**Verify Secret Synchronization:**

```bash
# Check ExternalSecret status
kubectl get externalsecret -n soludev soludev-phoenix-external-secret

# Verify all keys are synced
kubectl get secret -n soludev soludev-phoenix-secret -o jsonpath='{.data}' | jq -r 'keys[]'

# Expected output:
# PHOENIX_ADMIN_SECRET
# PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD
# PHOENIX_POSTGRES_PASSWORD
# PHOENIX_SECRET
# PHOENIX_SMTP_PASSWORD

# Verify secret lengths (should be 32+ for PHOENIX_SECRET and PHOENIX_ADMIN_SECRET)
kubectl get secret -n soludev soludev-phoenix-secret -o json | \
  jq -r '.data | to_entries[] | "\(.key): \(.value | @base64d | length) chars"'
```

### 4. Create Phoenix Values Configuration

Create a values file for Phoenix that references your PostgreSQL instance:

```yaml
# config/dev/phoenix/values.yaml
postgresql:
  enabled: false  # We're using external PostgreSQL

database:
  postgres:
    host: "postgres"  # Short name works for same-namespace services
    port: 5432
    db: "phoenix"
    user: "phoenix"
    password: ""  # Will be provided via command-line during upgrade

auth:
  enableAuth: true  # Enable authentication

persistence:
  enabled: false  # Use PostgreSQL for persistence instead of SQLite

ingress:
  enabled: false  # Configure based on your needs

server:
  port: 6006
```

### 5. Install Phoenix with Helm

Since the Helm chart doesn't support external secrets directly, we need to pass secrets at upgrade time.

#### Initial Installation

```bash
# Create temporary values file with secrets from Kubernetes secret
cat > /tmp/phoenix-secrets.yaml <<EOF
database:
  postgres:
    password: "$(kubectl get secret -n soludev soludev-phoenix-secret -o jsonpath='{.data.PHOENIX_POSTGRES_PASSWORD}' | base64 -d)"
auth:
  secret:
    - key: "PHOENIX_SECRET"
      value: "$(kubectl get secret -n soludev soludev-phoenix-secret -o jsonpath='{.data.PHOENIX_SECRET}' | base64 -d)"
    - key: "PHOENIX_ADMIN_SECRET"
      value: "$(kubectl get secret -n soludev soludev-phoenix-secret -o jsonpath='{.data.PHOENIX_ADMIN_SECRET}' | base64 -d)"
    - key: "PHOENIX_POSTGRES_PASSWORD"
      value: "$(kubectl get secret -n soludev soludev-phoenix-secret -o jsonpath='{.data.PHOENIX_POSTGRES_PASSWORD}' | base64 -d)"
    - key: "PHOENIX_SMTP_PASSWORD"
      value: "$(kubectl get secret -n soludev soludev-phoenix-secret -o jsonpath='{.data.PHOENIX_SMTP_PASSWORD}' | base64 -d)"
    - key: "PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD"
      value: "$(kubectl get secret -n soludev soludev-phoenix-secret -o jsonpath='{.data.PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD}' | base64 -d)"
EOF

# Install Phoenix
helm install phoenix oci://registry-1.docker.io/arizephoenix/phoenix-helm \
  --version 4.0.6 \
  -n soludev \
  -f config/dev/phoenix/values.yaml \
  -f /tmp/phoenix-secrets.yaml

# Clean up temporary file
rm /tmp/phoenix-secrets.yaml
```

#### Upgrading Phoenix

When you need to upgrade Phoenix or update configuration:

```bash
# Create temporary values file with current secrets
cat > /tmp/phoenix-secrets.yaml <<EOF
database:
  postgres:
    password: "$(kubectl get secret -n soludev soludev-phoenix-secret -o jsonpath='{.data.PHOENIX_POSTGRES_PASSWORD}' | base64 -d)"
auth:
  secret:
    - key: "PHOENIX_SECRET"
      value: "$(kubectl get secret -n soludev soludev-phoenix-secret -o jsonpath='{.data.PHOENIX_SECRET}' | base64 -d)"
    - key: "PHOENIX_ADMIN_SECRET"
      value: "$(kubectl get secret -n soludev soludev-phoenix-secret -o jsonpath='{.data.PHOENIX_ADMIN_SECRET}' | base64 -d)"
    - key: "PHOENIX_POSTGRES_PASSWORD"
      value: "$(kubectl get secret -n soludev soludev-phoenix-secret -o jsonpath='{.data.PHOENIX_POSTGRES_PASSWORD}' | base64 -d)"
    - key: "PHOENIX_SMTP_PASSWORD"
      value: "$(kubectl get secret -n soludev soludev-phoenix-secret -o jsonpath='{.data.PHOENIX_SMTP_PASSWORD}' | base64 -d)"
    - key: "PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD"
      value: "$(kubectl get secret -n soludev soludev-phoenix-secret -o jsonpath='{.data.PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD}' | base64 -d)"
EOF

# Upgrade Phoenix
helm upgrade phoenix oci://registry-1.docker.io/arizephoenix/phoenix-helm \
  --version 4.0.6 \
  -n soludev \
  -f config/dev/phoenix/values.yaml \
  -f /tmp/phoenix-secrets.yaml

# Clean up
rm /tmp/phoenix-secrets.yaml
```

### 6. Verify Phoenix Installation

```bash
# Check if Phoenix pod is running
kubectl get pods -n soludev -l app=phoenix

# Expected output:
# NAME                       READY   STATUS    RESTARTS   AGE
# phoenix-xxxxxxxxxx-xxxxx   1/1     Running   0          2m

# Check Phoenix logs
kubectl logs -n soludev -l app=phoenix --tail=50

# Look for successful startup messages:
# - "Application startup complete"
# - "Uvicorn running on http://0.0.0.0:6006"
# - Database connection: "postgresql://phoenix:***@postgres:5432/phoenix"
```

### 7. Access Phoenix

#### Port Forward (Development)

```bash
kubectl port-forward -n soludev svc/phoenix-svc 6006:6006
```

Access Phoenix at: `http://localhost:6006`

#### Get Admin Credentials

```bash
# Get admin password
kubectl get secret -n soludev phoenix-secret \
  -o jsonpath='{.data.PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD}' | base64 -d

echo  # Print newline

# Default username: admin
```

### 8. Configure Ingress (Optional)

To expose Phoenix externally:

```yaml
# dev/soludev/phoenix/ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: phoenix-ingress
  namespace: soludev
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod  # If using cert-manager
spec:
  rules:
    - host: phoenix.yourdomain.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: phoenix-svc
                port:
                  number: 6006
  tls:
    - hosts:
        - phoenix.yourdomain.com
      secretName: phoenix-tls
```

### 9. Troubleshooting Phoenix

#### Common Issues

**1. DNS Resolution Errors**

```
Error: [Errno -2] Name or service not known
```

**Solution:**

- Verify PostgreSQL service exists: `kubectl get svc -n soludev postgres`
- For same-namespace services, short hostname (`postgres`) should work
- For different namespaces, use FQDN: `postgres.soludev.svc.cluster.local`
- Test DNS from Phoenix pod: `kubectl exec -n soludev <phoenix-pod> -- nslookup postgres`

**2. Password Authentication Failed**

```
FATAL: password authentication failed for user "phoenix"
```

**Solution:**

- Verify database password in secret: `kubectl get secret -n soludev soludev-phoenix-secret -o jsonpath='{.data.PHOENIX_POSTGRES_PASSWORD}' | base64 -d`
- Check PostgreSQL user exists: `kubectl exec -it -n soludev <postgres-pod> -- psql -U logto -c "\du" | grep phoenix`
- Verify password matches what you set in PostgreSQL
- Ensure secrets are properly synced from OpenBao

**3. Secret Validation Errors**

```
ValueError: Phoenix secret must be at least 32 characters long
```

**Solution:**

- Check secret lengths: `kubectl get secret -n soludev soludev-phoenix-secret -o json | jq -r '.data | to_entries[] | "\(.key): \(.value | @base64d | length) chars"'`
- Regenerate secrets in OpenBao with proper length (32+ chars)
- Wait for ExternalSecret to sync (60s refresh interval)
- Force sync: Restart External Secrets Operator pod

**4. Chart Limitations**

If you see that `additionalEnv` is not being applied:

- Chart version 4.0.6 doesn't support `additionalEnv` parameter
- This feature exists in the GitHub main branch but hasn't been released
- Use the temporary values file method shown above as a workaround
- Watch for future chart versions that support external secrets natively

**5. Pod Stuck in CrashLoopBackOff**

```bash
# Check pod events
kubectl describe pod -n soludev <phoenix-pod-name>

# View detailed logs
kubectl logs -n soludev <phoenix-pod-name> --previous

# Common causes:
# - Database connection issues
# - Invalid secret values
# - Database migration failures
```

**6. Database Connection Troubleshooting**

```bash
# Test PostgreSQL connectivity from Phoenix pod
kubectl run -it --rm debug --image=postgres:16 --restart=Never -n soludev -- \
  psql -h postgres -U phoenix -d phoenix -c "SELECT version();"

# If connection fails:
# - Verify PostgreSQL service is running
# - Check PostgreSQL logs for authentication errors
# - Ensure database and user exist
# - Verify network policies allow traffic
```

### 10. Updating Secrets

When you need to update Phoenix secrets:

1. **Update secrets in OpenBao:**

   ```bash
   kubectl exec -n soludev openbao-0 -- env VAULT_TOKEN="$VAULT_TOKEN" \
     bao kv patch soludev/phoenix \
     PHOENIX_SECRET="<new-32+-char-secret>"
   ```

2. **Wait for ExternalSecret to sync** (60 seconds) or force sync:

   ```bash
   kubectl delete pod -n external-secrets-system -l app.kubernetes.io/name=external-secrets
   ```

3. **Verify secrets updated:**

   ```bash
   kubectl get secret -n soludev soludev-phoenix-secret -o jsonpath='{.data.PHOENIX_SECRET}' | base64 -d
   ```

4. **Upgrade Phoenix** with new secrets using the upgrade command from step 5

5. **Restart Phoenix pod** to apply changes:

   ```bash
   kubectl rollout restart deployment/phoenix -n soludev
   ```

### 11. Best Practices

**Secret Management:**

- ✅ Store all secrets in OpenBao, never in Git
- ✅ Use strong, randomly generated secrets (32+ chars for main secrets)
- ✅ Rotate secrets periodically
- ✅ Use the temporary file method to avoid secrets in shell history
- ✅ Delete temporary secret files immediately after use

**Configuration:**

- ✅ Use short hostnames for same-namespace services
- ✅ Keep values.yaml in Git without any secret values
- ✅ Document the secret structure in comments
- ✅ Use `database.postgres.password: ""` as placeholder

**Operations:**

- ✅ Always verify secrets are synced before upgrading
- ✅ Check pod logs after deployment
- ✅ Monitor database connections
- ✅ Set up proper monitoring and alerting

**Security:**

- ✅ Enable authentication (`auth.enableAuth: true`)
- ✅ Use TLS for ingress in production
- ✅ Restrict network access using NetworkPolicies
- ✅ Regular security updates (upgrade Phoenix chart versions)

### 12. Alternative Installation Methods

#### Using a Shell Script

For easier management, create a deployment script:

```bash
#!/bin/bash
# deploy-phoenix.sh

set -e

NAMESPACE="soludev"
RELEASE="phoenix"
CHART_VERSION="4.0.6"

echo "Creating temporary values file with secrets..."
cat > /tmp/phoenix-secrets.yaml <<EOF
database:
  postgres:
    password: "$(kubectl get secret -n ${NAMESPACE} soludev-phoenix-secret -o jsonpath='{.data.PHOENIX_POSTGRES_PASSWORD}' | base64 -d)"
auth:
  secret:
    - key: "PHOENIX_SECRET"
      value: "$(kubectl get secret -n ${NAMESPACE} soludev-phoenix-secret -o jsonpath='{.data.PHOENIX_SECRET}' | base64 -d)"
    - key: "PHOENIX_ADMIN_SECRET"
      value: "$(kubectl get secret -n ${NAMESPACE} soludev-phoenix-secret -o jsonpath='{.data.PHOENIX_ADMIN_SECRET}' | base64 -d)"
    - key: "PHOENIX_POSTGRES_PASSWORD"
      value: "$(kubectl get secret -n ${NAMESPACE} soludev-phoenix-secret -o jsonpath='{.data.PHOENIX_POSTGRES_PASSWORD}' | base64 -d)"
    - key: "PHOENIX_SMTP_PASSWORD"
      value: "$(kubectl get secret -n ${NAMESPACE} soludev-phoenix-secret -o jsonpath='{.data.PHOENIX_SMTP_PASSWORD}' | base64 -d)"
    - key: "PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD"
      value: "$(kubectl get secret -n ${NAMESPACE} soludev-phoenix-secret -o jsonpath='{.data.PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD}' | base64 -d)"
EOF

echo "Upgrading Phoenix release..."
helm upgrade ${RELEASE} oci://registry-1.docker.io/arizephoenix/phoenix-helm \
  --version ${CHART_VERSION} \
  -n ${NAMESPACE} \
  --install \
  -f config/dev/phoenix/values.yaml \
  -f /tmp/phoenix-secrets.yaml

echo "Cleaning up temporary file..."
rm /tmp/phoenix-secrets.yaml

echo "Phoenix deployment complete!"
echo "Check status with: kubectl get pods -n ${NAMESPACE} -l app=phoenix"
```

Make it executable and use:

```bash
chmod +x deploy-phoenix.sh
./deploy-phoenix.sh
```

### 13. Future Improvements

**Watch for chart updates** that add native support for:

- External secret references via `additionalEnv`
- Support for `existingSecret` parameter
- Direct integration with External Secrets Operator

Once these features are available, you can simplify the deployment by updating values.yaml to reference the external secret directly, eliminating the need for temporary files during upgrades.

## OpenObserve Installation

OpenObserve is a cloud-native observability platform for logs, metrics, and traces. This section covers deploying OpenObserve with MinIO for object storage and PostgreSQL for metadata.

### Prerequisites

- MinIO instance running in the cluster
- PostgreSQL instance running in the cluster
- OpenBao/Vault configured and unsealed
- External Secrets Operator installed
- Helm 3.x installed
- NFS storage configured (for local cache)

### Architecture Overview

OpenObserve deployment uses:

- **MinIO**: For storing logs, metrics, and traces (object storage)
- **PostgreSQL**: For metadata storage
- **NFS**: For local cache/temporary data
- **External Secrets**: For secure credential management

### 1. Prepare PostgreSQL Database

Create a dedicated database for OpenObserve metadata.

#### Connect to PostgreSQL

```bash
# Find your PostgreSQL pod
kubectl get pods -n soludev | grep postgres

# Connect to PostgreSQL
kubectl exec -it -n soludev <postgres-pod-name> -- psql -U <postgres-user>
```

#### Create Database and User

```sql
-- Create the openobserve user
CREATE USER openobserve WITH PASSWORD 'your-secure-password';

-- Create the openobserve database
CREATE DATABASE openobserve OWNER openobserve;

-- Grant permissions
GRANT ALL PRIVILEGES ON DATABASE openobserve TO openobserve;

-- Connect to the database to grant schema permissions
\c openobserve
GRANT ALL ON SCHEMA public TO openobserve;

-- Verify
\l  -- List databases
\du -- List users
```

### 2. Prepare MinIO Bucket

Create a dedicated bucket in MinIO for OpenObserve data.

#### Using MinIO Console

```bash
# Port forward to MinIO console
kubectl port-forward -n soludev svc/minio 9001:9001

# Access console at http://localhost:9001
# Login with your MinIO credentials
# Navigate to "Buckets" and create a new bucket named "observability"
```

#### Using MinIO CLI

```bash
# Install MinIO CLI if not already installed
curl https://dl.min.io/client/mc/release/darwin-amd64/mc \
  -o /usr/local/bin/mc
chmod +x /usr/local/bin/mc

# Port forward to MinIO API
kubectl port-forward -n soludev svc/minio 9000:9000 &

# Configure MinIO alias
mc alias set minio http://localhost:9000 <MINIO_USER> <MINIO_PASSWORD>

# Create bucket
mc mb minio/observability

# Verify
mc ls minio
```

#### Create Access Keys for OpenObserve

```bash
# Using MinIO console:
# 1. Go to "Access Keys"
# 2. Click "Create Access Key"
# 3. Save the Access Key and Secret Key

# Or using CLI:
mc admin user svcacct add minio <MINIO_USER> \
  --access-key "openobserve-access" \
  --secret-key "your-secret-key"
```

### 3. Create Secrets in OpenBao

OpenObserve requires several secrets to be stored in OpenBao.

#### Required Secrets

1. `ZO_ROOT_USER_EMAIL`: Admin email for OpenObserve login
2. `ZO_ROOT_USER_PASSWORD`: Admin password for OpenObserve
3. `MINIO_ACCESS`: MinIO access key
4. `MINIO_SECRET`: MinIO secret key
5. `ZO_META_POSTGRES_DSN`: PostgreSQL connection string

#### Generate PostgreSQL DSN

The DSN format for PostgreSQL:

```
postgresql://username:password@host:port/database
```

Example:

```
postgresql://openobserve:your-password@postgres.soludev.svc.cluster.local:5432/openobserve
```

#### Store Secrets in OpenBao

Using the OpenBao CLI:

```bash
# Set your vault token
export VAULT_TOKEN=<your-root-token>

# Port forward to OpenBao (if needed)
kubectl port-forward -n soludev svc/openbao 8200:8200 &

# Store OpenObserve secrets
kubectl exec -n soludev openbao-0 -- env VAULT_TOKEN="$VAULT_TOKEN" \
  bao kv put soludev/openobserve \
  ZO_ROOT_USER_EMAIL="admin@yourdomain.com" \
  ZO_ROOT_USER_PASSWORD="your-secure-password" \
  MINIO_ACCESS="openobserve-access-key" \
  MINIO_SECRET="your-minio-secret-key" \
  ZO_META_POSTGRES_DSN="postgresql://openobserve:your-db-password@postgres.soludev.svc.cluster.local:5432/openobserve"
```

**Using the OpenBao UI:**

1. Port forward: `kubectl port-forward -n soludev svc/openbao 8200:8200`
2. Access UI at `http://localhost:8200`
3. Login with your root token
4. Navigate to **Secrets** → **soludev/**
5. Create a new secret named `openobserve`
6. Add all required keys listed above

### 4. Configure ExternalSecret

Create an ExternalSecret resource to sync secrets from OpenBao:

```yaml
# dev/soludev/openobserve/external-secret.yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: soludev-openobserve-external-secret
  namespace: soludev
spec:
  refreshInterval: 60s
  secretStoreRef:
    name: openbao-backend
    kind: ClusterSecretStore
  target:
    name: soludev-openobserve-secret
    creationPolicy: Owner
  dataFrom:
  - extract:
      key: soludev/openobserve
```

Apply the ExternalSecret:

```bash
kubectl apply -f dev/soludev/openobserve/external-secret.yaml
```

**Verify Secret Synchronization:**

```bash
# Check ExternalSecret status
kubectl get externalsecret -n soludev soludev-openobserve-external-secret

# Verify all keys are synced
kubectl get secret -n soludev soludev-openobserve-secret -o jsonpath='{.data}' | jq -r 'keys[]'

# Expected output:
# MINIO_ACCESS
# MINIO_SECRET
# ZO_META_POSTGRES_DSN
# ZO_ROOT_USER_EMAIL
# ZO_ROOT_USER_PASSWORD
```

### 5. Create NFS PersistentVolume

OpenObserve needs local storage for cache. Create an NFS-backed PersistentVolume:

```yaml
# dev/soludev/openobserve/persistent-volume.yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: nfs-soludev-openobserve
  namespace: soludev
spec:
  capacity:
    storage: 5Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: nfs-soludev-openobserve
  nfs:
    server: <NFS_SERVER_IP>  # Your NFS server IP
    path: /path/to/openobserve/storage
  mountOptions:
    - nfsvers=4.1
    - hard
    - timeo=600
    - retrans=2
```

**Create the NFS directory on your NFS server:**

```bash
# SSH to your NFS server
ssh user@nfs-server

# Create directory
sudo mkdir -p /path/to/openobserve/storage
sudo chmod 777 /path/to/openobserve/storage

# Update NFS exports if needed
sudo exportfs -ra
```

Apply the PersistentVolume:

```bash
kubectl apply -f dev/soludev/openobserve/persistent-volume.yaml

# Verify PV is available
kubectl get pv nfs-soludev-openobserve
```

### 6. Create OpenObserve Values Configuration

Create a values file that references external secrets and configures OpenObserve:

```yaml
# config/dev/openobserve/values.yml

# Empty auth section - credentials injected via extraEnv
auth:
  ZO_ROOT_USER_EMAIL: ""
  ZO_ROOT_USER_PASSWORD: ""
  ZO_S3_ACCESS_KEY: ""
  ZO_S3_SECRET_KEY: ""

# Inject credentials from external secret
extraEnv:
  - name: ZO_ROOT_USER_EMAIL
    valueFrom:
      secretKeyRef:
        name: soludev-openobserve-secret
        key: ZO_ROOT_USER_EMAIL
  - name: ZO_ROOT_USER_PASSWORD
    valueFrom:
      secretKeyRef:
        name: soludev-openobserve-secret
        key: ZO_ROOT_USER_PASSWORD
  - name: ZO_S3_ACCESS_KEY
    valueFrom:
      secretKeyRef:
        name: soludev-openobserve-secret
        key: MINIO_ACCESS
  - name: ZO_S3_SECRET_KEY
    valueFrom:
      secretKeyRef:
        name: soludev-openobserve-secret
        key: MINIO_SECRET
  - name: ZO_META_POSTGRES_DSN
    valueFrom:
      secretKeyRef:
        name: soludev-openobserve-secret
        key: ZO_META_POSTGRES_DSN

# OpenObserve configuration
config:
  # Data retention (10 days)
  ZO_COMPACT_DATA_RETENTION_DAYS: "10"
  ZO_COMPACT_ENABLED: "true"
  ZO_COMPACT_INTERVAL: "3600"

  # PostgreSQL for metadata
  ZO_META_STORE: "postgres"
  ZO_META_CONNECTION_POOL_MIN_SIZE: "2"
  ZO_META_CONNECTION_POOL_MAX_SIZE: "10"
  
  # Local mode with S3/MinIO storage
  ZO_LOCAL_MODE: "true"
  ZO_LOCAL_MODE_STORAGE: "s3"
  
  # MinIO configuration
  ZO_S3_PROVIDER: "minio"
  ZO_S3_SERVER_URL: "http://minio.soludev.svc.cluster.local:9000"
  ZO_S3_REGION_NAME: "us-east-1"
  ZO_S3_BUCKET_NAME: "observability"
  ZO_S3_BUCKET_PREFIX: ""
  ZO_S3_FEATURE_FORCE_HOSTED_STYLE: "false"
  ZO_S3_FEATURE_FORCE_PATH_STYLE: "true"
  ZO_S3_FEATURE_HTTP1_ONLY: "false"
  ZO_S3_FEATURE_HTTP2_ONLY: "false"

# Resource limits
resources:
  limits:
    cpu: 1500m
    memory: 2Gi
  requests:
    cpu: 1000m
    memory: 1Gi

# Local cache persistence
persistence:
  enabled: true
  size: 5Gi
  storageClass: "nfs-soludev-openobserve"
  accessModes:
    - ReadWriteMany

# Service configuration
service:
  type: ClusterIP
  http_port: 5080
  grpc_port: 5081

# Ingress disabled (configured separately)
ingress:
  enabled: false

# Disable built-in MinIO (using external MinIO)
minio:
  enabled: false
```

### 7. Install OpenObserve with Helm

#### Add OpenObserve Helm Repository

```bash
helm repo add openobserve https://charts.openobserve.ai
helm repo update
```

#### Install OpenObserve

```bash
helm install openobserve openobserve/openobserve-standalone \
  -n soludev \
  -f config/dev/openobserve/values.yml
```

#### Upgrade OpenObserve

When you need to update configuration:

```bash
helm upgrade openobserve openobserve/openobserve-standalone \
  -n soludev \
  -f config/dev/openobserve/values.yml
```

### 8. Verify OpenObserve Installation

```bash
# Check if OpenObserve pod is running
kubectl get pods -n soludev -l app.kubernetes.io/name=openobserve

# Expected output:
# NAME                                              READY   STATUS    RESTARTS   AGE
# openobserve-openobserve-standalone-0              1/1     Running   0          2m

# Check PVC is bound
kubectl get pvc -n soludev | grep openobserve

# Check logs
kubectl logs -n soludev -l app.kubernetes.io/name=openobserve --tail=50

# Look for successful startup messages:
# - "Starting OpenObserve"
# - PostgreSQL connection established
# - MinIO/S3 connection verified
```

### 9. Configure Ingress

Create an Ingress resource to expose OpenObserve:

```yaml
# dev/soludev/openobserve/ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: openobserve-ingress
  namespace: soludev
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web,websecure
    traefik.ingress.kubernetes.io/redirect-scheme: https
    cert-manager.io/cluster-issuer: letsencrypt-prod  # If using cert-manager
spec:
  rules:
    - host: openobserve.yourdomain.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: openobserve-openobserve-standalone
                port:
                  number: 5080
  tls:
    - hosts:
        - openobserve.yourdomain.com
      secretName: openobserve-tls
```

Apply the Ingress:

```bash
kubectl apply -f dev/soludev/openobserve/ingress.yaml

# Verify ingress
kubectl get ingress -n soludev openobserve-ingress
```

### 10. Access OpenObserve

#### Port Forward (Development)

```bash
kubectl port-forward -n soludev svc/openobserve-openobserve-standalone 5080:5080
```

Access OpenObserve at: `http://localhost:5080`

#### Get Login Credentials

```bash
# Get admin email
kubectl get secret -n soludev soludev-openobserve-secret \
  -o jsonpath='{.data.ZO_ROOT_USER_EMAIL}' | base64 -d
echo

# Get admin password
kubectl get secret -n soludev soludev-openobserve-secret \
  -o jsonpath='{.data.ZO_ROOT_USER_PASSWORD}' | base64 -d
echo
```

### 11. Configure Data Ingestion

#### Logs via HTTP

```bash
# Ingest logs using curl
curl -u "admin@yourdomain.com:your-password" \
  -X POST "http://openobserve.yourdomain.com/api/default/logs" \
  -H "Content-Type: application/json" \
  -d '[
    {
      "timestamp": "2024-01-01T12:00:00Z",
      "level": "info",
      "message": "Test log message",
      "service": "my-app"
    }
  ]'
```

#### Logs via Fluent Bit

```yaml
# fluent-bit-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: fluent-bit-config
  namespace: logging
data:
  fluent-bit.conf: |
    [OUTPUT]
        Name http
        Match *
        Host openobserve-openobserve-standalone.soludev.svc.cluster.local
        Port 5080
        URI /api/default/logs
        Format json
        HTTP_User admin@yourdomain.com
        HTTP_Passwd your-password
        tls Off
```

#### Metrics via Prometheus Remote Write

```yaml
# prometheus-config.yaml
remote_write:
  - url: http://openobserve-openobserve-standalone.soludev.svc.cluster.local:5080/api/default/prometheus/api/v1/write
    basic_auth:
      username: admin@yourdomain.com
      password: your-password
```

### 12. Troubleshooting OpenObserve

#### Common Issues

**1. PostgreSQL Connection Errors**

```
Error: failed to connect to PostgreSQL
```

**Solution:**

- Verify DSN format in secret: `kubectl get secret -n soludev soludev-openobserve-secret -o jsonpath='{.data.ZO_META_POSTGRES_DSN}' | base64 -d`
- Check PostgreSQL is accessible: `kubectl exec -it -n soludev <openobserve-pod> -- nc -zv postgres 5432`
- Verify database and user exist in PostgreSQL
- Check PostgreSQL logs for authentication errors

**2. MinIO/S3 Connection Errors**

```
Error: failed to connect to S3
```

**Solution:**

- Verify MinIO is running: `kubectl get pods -n soludev | grep minio`
- Check MinIO access keys in secret
- Verify bucket exists: `mc ls minio/observability`
- Test connectivity from OpenObserve pod:

  ```bash
  kubectl exec -it -n soludev <openobserve-pod> -- \
    curl http://minio.soludev.svc.cluster.local:9000/minio/health/live
  ```

**3. PVC Not Binding**

```bash
# Check PVC status
kubectl get pvc -n soludev | grep openobserve

# Check PV status
kubectl get pv nfs-soludev-openobserve

# Describe PVC for events
kubectl describe pvc -n soludev <pvc-name>
```

**Solution:**

- Verify NFS server is accessible
- Check NFS exports: `showmount -e <nfs-server-ip>`
- Verify storage class matches: `kubectl get storageclass`
- Check NFS path exists and has correct permissions

**4. Secret Not Syncing**

```bash
# Check ExternalSecret status
kubectl describe externalsecret -n soludev soludev-openobserve-external-secret

# Check for errors in External Secrets Operator
kubectl logs -n external-secrets-system -l app.kubernetes.io/name=external-secrets
```

**Solution:**

- Verify secrets exist in OpenBao
- Check ClusterSecretStore is configured correctly
- Verify service account has proper permissions
- Force sync by restarting External Secrets Operator pod

**5. Data Not Appearing in UI**

**Solution:**

- Check data is being sent to correct endpoint
- Verify authentication credentials
- Check OpenObserve logs for ingestion errors
- Verify MinIO bucket has data: `mc ls minio/observability`
- Check PostgreSQL for metadata entries

**6. High Memory Usage**

**Solution:**

- Reduce `ZO_META_CONNECTION_POOL_MAX_SIZE`
- Increase resource limits in values.yml
- Adjust `ZO_COMPACT_DATA_RETENTION_DAYS` to retain less data
- Monitor MinIO bucket size

### 13. Monitoring and Maintenance

#### Check OpenObserve Health

```bash
# Health check endpoint
curl http://openobserve.yourdomain.com/healthz

# Metrics endpoint
curl http://openobserve.yourdomain.com/metrics
```

#### Monitor Storage Usage

```bash
# Check MinIO bucket size
mc du minio/observability

# Check PVC usage
kubectl exec -it -n soludev <openobserve-pod> -- df -h /data

# Check PostgreSQL database size
kubectl exec -it -n soludev <postgres-pod> -- \
  psql -U openobserve -d openobserve -c \
  "SELECT pg_size_pretty(pg_database_size('openobserve'));"
```

#### Data Compaction

OpenObserve automatically compacts data based on configuration:

```yaml
config:
  ZO_COMPACT_DATA_RETENTION_DAYS: "10"  # Keep data for 10 days
  ZO_COMPACT_ENABLED: "true"
  ZO_COMPACT_INTERVAL: "3600"  # Run compaction every hour
```

#### Backup Considerations

**PostgreSQL Metadata:**

```bash
# Backup PostgreSQL database
kubectl exec -n soludev <postgres-pod> -- \
  pg_dump -U openobserve openobserve > openobserve-metadata-backup.sql
```

**MinIO Data:**

```bash
# Backup MinIO bucket
mc mirror minio/observability /path/to/backup/
```

### 14. Scaling OpenObserve

For production workloads, consider:

**Horizontal Scaling:**

```yaml
replicaCount: 3  # Run multiple replicas
```

**Resource Scaling:**

```yaml
resources:
  limits:
    cpu: 4000m
    memory: 8Gi
  requests:
    cpu: 2000m
    memory: 4Gi
```

**PostgreSQL Connection Pool:**

```yaml
config:
  ZO_META_CONNECTION_POOL_MAX_SIZE: "20"
```

### 15. Best Practices

**Security:**

- ✅ Use strong passwords for admin account
- ✅ Enable TLS/HTTPS via ingress
- ✅ Store all credentials in OpenBao
- ✅ Use network policies to restrict access
- ✅ Regularly rotate credentials

**Performance:**

- ✅ Adjust retention policies based on your needs
- ✅ Monitor resource usage and scale accordingly
- ✅ Use appropriate PostgreSQL connection pool sizes
- ✅ Enable data compaction

**Reliability:**

- ✅ Use persistent storage for local cache
- ✅ Backup PostgreSQL metadata regularly
- ✅ Monitor MinIO bucket size
- ✅ Set up proper monitoring and alerting

**Cost Optimization:**

- ✅ Adjust data retention to balance storage costs
- ✅ Use MinIO lifecycle policies for old data
- ✅ Right-size resource requests and limits

### 16. Integration Examples

#### Kubernetes Application Logs

```yaml
# Example: Configure your app to send logs to OpenObserve
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
spec:
  template:
    spec:
      containers:
        - name: app
          image: my-app:latest
          env:
            - name: LOG_ENDPOINT
              value: "http://openobserve-openobserve-standalone.soludev.svc.cluster.local:5080/api/default/logs"
            - name: LOG_USER
              valueFrom:
                secretKeyRef:
                  name: soludev-openobserve-secret
                  key: ZO_ROOT_USER_EMAIL
            - name: LOG_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: soludev-openobserve-secret
                  key: ZO_ROOT_USER_PASSWORD
```

#### OpenTelemetry Integration

```yaml
# otel-collector-config.yaml
exporters:
  otlphttp:
    endpoint: http://openobserve-openobserve-standalone.soludev.svc.cluster.local:5080/api/default
    headers:
      Authorization: Basic <base64(email:password)>
```

## PickPro Application Setup

This section covers the deployment of the PickPro application stack, including OAuth2 Proxy for authentication, MinIO for storage, and Traefik middleware integration.

### 1. OAuth2 Proxy Installation

OAuth2 Proxy is used to protect the application with OIDC authentication (e.g., Logto).

#### Prerequisites

- **OpenBao/Vault** configured with the secret `pickpro/oauth2-proxy` containing:
  - `client-id`
  - `client-secret`
  - `cookie-secret`

#### Deployment Steps

1. **Add Helm Repository:**

   ```bash
   helm repo add oauth2-proxy https://oauth2-proxy.github.io/manifests
   helm repo update
   ```

2. **Deploy with Helm:**

   ```bash
   helm upgrade --install oauth2-proxy oauth2-proxy/oauth2-proxy \
     --namespace pickpro \
     --create-namespace \
     -f config/dev/oauth2-proxy/values.yaml
   ```

3. **Apply External Secrets and ConfigMap:**
   Ensure the `oauth2-proxy-secret` and `oauth2-proxy-config` are created:

   ```bash
   kubectl apply -f dev/pickpro/oauth2-proxy/
   ```

### 2. Traefik Forward Auth Middleware

To protect your Ingress resources, configure a Traefik Middleware that delegates authentication to OAuth2 Proxy.

#### Configuration

File: `dev/pickpro/traefik/middleware.yaml`

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: traefik-forward-auth
  namespace: pickpro
spec:
  forwardAuth:
    address: "http://oauth2-proxy.pickpro.svc.cluster.local:4180/oauth2/auth"
    authResponseHeaders:
      - "X-Auth-Request-User"
      - "X-Auth-Request-Email"
      - "Authorization"
    trustForwardHeader: true
```

#### Apply Middleware

```bash
kubectl apply -f dev/pickpro/traefik/middleware.yaml
```

### 3. MinIO for PickPro

PickPro uses a dedicated MinIO instance for storing CVs and other documents.

#### Deployment

```bash
helm upgrade --install minio-pickpro minio/minio \
  --namespace pickpro \
  -f config/dev/minio/pickpro/values.yaml
```

This configuration:

- Creates a bucket named `cvs`
- Uses NFS storage class `nfs-pickpro-minio`
- Sets up a standalone MinIO instance

### 4. Application Ingress Protection

To protect an Ingress resource (e.g., `pickpro-front`), add the middleware annotation:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: pickpro-front
  namespace: pickpro
  annotations:
    traefik.ingress.kubernetes.io/router.middlewares: pickpro-traefik-forward-auth@kubernetescrd
spec:
  # ... ingress rules ...
```

## Troubleshooting

### Common Issues

1. **cgroups v2 Error**: Follow the cgroups v2 setup steps in the Control Plane Setup section
2. **Network Issues**: Ensure firewall allows traffic on port 6443
3. **Token Issues**: Verify the token is copied correctly without extra spaces or characters

### Useful Commands

```bash
# Check cluster status
kubectl get nodes

# Check all pods
kubectl get pods -A

# Check K3s service status
sudo systemctl status k3s

# Check K3s agent status (on worker nodes)
sudo systemctl status k3s-agent

# View K3s logs
sudo journalctl -u k3s -f
```

## Architecture

This setup creates:

- A K3s cluster with control plane and worker nodes
- Flux for GitOps deployment management
- Vault for secrets management
- Traefik as the default ingress controller
- CoreDNS for cluster DNS
- Local path provisioner for storage

## Next Steps

After completing this setup, you can:

1. Configure Flux to watch your Git repository
2. Set up Vault policies and authentication
3. Deploy applications using GitOps workflows
4. Configure ingress for external access to services
