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