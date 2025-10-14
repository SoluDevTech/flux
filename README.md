# K3s Cluster Setup Documentation

This documentation covers the complete setup of a K3s cluster with Flux for GitOps and Vault for secrets management.

## Table of Contents
- 
- [K3s Installation](#k3s-installation)
- [Control Plane Setup](#control-plane-setup)
- [Worker Node Setup](#worker-node-setup)
- [Mac Worker via Multipass](#mac-worker-via-multipass)
- [Flux Installation](#flux-installation)
- [Helm Installation](#helm-installation)
- [Vault Installation](#vault-installation)
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
helm install openbao openbao/openbao --namespace kaiohz -f values.yaml
```

Note: Make sure you have a `values.yaml` file configured for your Vault setup.

### 3. Initialize and Unseal Vault

#### Initialize Vault
```bash
kubectl exec -n kaiohz openbao-0 -- vault operator init
```

This command will output unseal keys and a root token. **Save these securely!**

#### Unseal Vault
Use any 3 of the 5 unseal keys provided during initialization:

```bash
kubectl exec -n kaiohz openbao-0 -- vault operator unseal '<key1>'
kubectl exec -n kaiohz openbao-0 -- vault operator unseal '<key2>'
kubectl exec -n kaiohz openbao-0 -- vault operator unseal '<key3>'
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
kubectl exec -n kaiohz openbao-0 -- env VAULT_TOKEN="$VAULT_TOKEN" \ 
  bao auth enable kubernetes
```

#### Create Service Account for Vault Authentication
```bash
# Create service account
kubectl create serviceaccount openbao-auth -n kaiohz

# Create cluster role binding
kubectl create clusterrolebinding openbao-auth \
  --clusterrole=system:auth-delegator \
  --serviceaccount=kaiohz:openbao-auth

kubectl create serviceaccount external-secrets-sa -n kaiohz

# Generate token for the service account
kubectl create token openbao-auth -n kaiohz 
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
kubectl exec -n kaiohz openbao-0 -- env VAULT_TOKEN="$VAULT_TOKEN" \
  bao write auth/kubernetes/config \
  token_reviewer_jwt="$SA_TOKEN" \
  kubernetes_host="$K8S_HOST" \
  kubernetes_ca_cert="$K8S_CA_CERT" \
  disable_iss_validation=true
```

#### Create a Role for External Secrets
```bash
kubectl exec -n kaiohz openbao-0 -- env VAULT_TOKEN="$VAULT_TOKEN" \
  bao write auth/kubernetes/role/external-secrets-role \
  bound_service_account_names=external-secrets-sa \
  bound_service_account_namespaces=kaiohz \
  policies=external-secrets-policy \
  ttl=24h
```

#### Create Policy for External Secrets
```bash
kubectl exec -n kaiohz openbao-0 -- bao policy write external-secrets-policy - <<EOF
path "secret/data/*" {
  capabilities = ["read", "list"]
}
path "secret/metadata/*" {
  capabilities = ["read", "list"]
}
EOF
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

## Synchronisation des secrets Vault vers K3s

Cette section explique comment synchroniser automatiquement les secrets stockés dans Vault vers les secrets Kubernetes en utilisant External Secrets Operator (ESO).

### 1. Installation d'External Secrets Operator

#### Via Helm (recommandé)

```bash
# Ajouter le repo
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

# Installer ESO
helm install external-secrets external-secrets/external-secrets \
    -n external-secrets-system \
    --create-namespace

# Vérifier l'installation
kubectl get pods -n external-secrets-system
```

#### Via manifests YAML (alternative)

```bash
kubectl apply -f https://raw.githubusercontent.com/external-secrets/external-secrets/main/deploy/crds/bundle.yaml
kubectl apply -f https://raw.githubusercontent.com/external-secrets/external-secrets/main/deploy/charts/external-secrets/templates/deployment.yaml
```

### 2. Configuration du SecretStore

#### Créer le SecretStore

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
      path: "secret"          # Chemin de votre KV engine
      version: "v2"           # Version du KV engine (v1 ou v2)
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "external-secrets-role"
          serviceAccountRef:
            name: "external-secrets-sa"
```

```bash
# Appliquer la configuration
kubectl apply -f vault-secret-store.yaml

# Vérifier le SecretStore
kubectl get secretstore vault-backend -n kaiohz
kubectl describe secretstore vault-backend -n kaiohz
```

### 3. Créer des secrets dans Vault (exemples)

#### Via l'UI Vault
- Secrets > secret/ (ou votre engine)
- Create secret

Exemples de structure :
```
# Secrets pour une application
Path: myapp/database
- username: mydbuser
- password: supersecret123
- host: db.example.com
- port: 5432

# Secrets pour l'API
Path: myapp/api
- key: abc123xyz
- secret: def456uvw
- endpoint: https://api.example.com

# Secrets pour les certificats
Path: myapp/tls
- cert: -----BEGIN CERTIFICATE-----...
- key: -----BEGIN PRIVATE KEY-----...
```

#### Via CLI Vault

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

### 4. Créer des ExternalSecrets

#### ExternalSecret basique - Secrets individuels

```yaml
# myapp-database-secret.yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: myapp-database
  namespace: kaiohz
spec:
  refreshInterval: 60s  # Synchronisation toutes les minutes
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: myapp-db-secret    # Nom du secret K8s qui sera créé
    creationPolicy: Owner    # ESO gère le secret
    type: Opaque            # Type de secret K8s
  data:
  - secretKey: DB_USERNAME        # Clé dans le secret K8s
    remoteRef:
      key: myapp/database        # Chemin dans Vault
      property: username         # Propriété spécifique
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

#### ExternalSecret - Synchronisation complète d'un secret

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
      key: myapp/api  # Récupère TOUTES les clés de ce secret Vault
```

#### ExternalSecret - Secret TLS

```yaml
# myapp-tls-secret.yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: myapp-tls
  namespace: kaiohz
spec:
  refreshInterval: 300s  # 5 minutes pour les certificats
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: myapp-tls-secret
    creationPolicy: Owner
    type: kubernetes.io/tls  # Type spécial pour TLS
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

### 5. Appliquer les ExternalSecrets

```bash
# Appliquer tous les ExternalSecrets
kubectl apply -f myapp-database-secret.yaml
kubectl apply -f myapp-api-secret.yaml
kubectl apply -f myapp-tls-secret.yaml

# Vérifier le statut
kubectl get externalsecrets -n kaiohz

# Voir les détails (important pour débugger)
kubectl describe externalsecret myapp-database -n kaiohz
```

### 6. Vérifier que les secrets K8s sont créés

```bash
# Lister les secrets créés
kubectl get secrets -n kaiohz | grep myapp

# Voir le contenu d'un secret (base64)
kubectl get secret myapp-db-secret -n kaiohz -o yaml

# Décoder un secret pour vérifier
kubectl get secret myapp-db-secret -n kaiohz -o jsonpath='{.data.DB_USERNAME}' | base64 -d
```

### 7. Utiliser les secrets dans vos applications

#### Dans un Deployment

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
        # Variables d'environnement depuis les secrets
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
        # Volume pour les certificats TLS
        volumeMounts:
        - name: tls-certs
          mountPath: /etc/ssl/certs/app
          readOnly: true
      volumes:
      - name: tls-certs
        secret:
          secretName: myapp-tls-secret
```

#### Variables d'environnement depuis un secret entier

```yaml
        envFrom:
        - secretRef:
            name: myapp-api-secret  # Toutes les clés deviennent des variables d'env
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