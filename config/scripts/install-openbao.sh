#!/bin/bash
#
# OpenBao Standalone Installation Script for K3s
# Installs all prerequisites, NFS storage, and configures OpenBao
#
# Usage: ./install-openbao.sh [OPTIONS]
#

set -e

# =============================================================================
# DEFAULT CONFIGURATION
# =============================================================================

NAMESPACE="soludev"
RELEASE_NAME="openbao"
VALUES_FILE=""
OUTPUT_FILE="./config/openbao-credentials.json"
SKIP_INIT=false
SKIP_EXTERNAL_SECRETS=false
SKIP_INGRESS=false
VERBOSE=false
UNINSTALL=false
PURGE=true

# Manifests directory (use existing CRD files instead of inline templates)
MANIFESTS_DIR="./dev/soludev/openbao"

# NFS Configuration (used only if MANIFESTS_DIR is not set)
NFS_SERVER="100.64.0.4"
NFS_BASE_PATH="/home/lima.linux/k3s-storage"
STORAGE_SIZE="5Gi"
STORAGE_CLASS_NAME="nfs-soludev-openbao"

# Ingress Configuration (used only if MANIFESTS_DIR is not set)
INGRESS_HOST="bao.soludev.tech"

# Script directory (to find manifest files)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_verbose() {
    if [[ "$VERBOSE" == true ]]; then
        echo -e "${BLUE}[VERBOSE]${NC} $1"
    fi
}

show_help() {
    cat << EOF
OpenBao Standalone Installation Script for K3s

Usage: ./install-openbao.sh [OPTIONS]

Options:
  -n, --namespace NAME        Namespace for installation (default: soludev)
  -r, --release NAME          Helm release name (default: openbao)
  -f, --values FILE           Custom values.yaml file path
  -o, --output FILE           Output file for credentials (default: openbao-credentials.json)
  -m, --manifests-dir DIR     Directory containing CRD manifest files (uses files instead of inline templates)
      --nfs-server IP         NFS server IP (default: 100.64.0.4) - ignored if --manifests-dir is set
      --nfs-path PATH         NFS base path (default: /home/lima.linux/k3s-storage) - ignored if --manifests-dir is set
      --storage-size SIZE     Storage size (default: 5Gi) - ignored if --manifests-dir is set
      --ingress-host HOST     Ingress hostname (default: bao.soludev.tech) - ignored if --manifests-dir is set
      --skip-init             Skip initialization and unseal (useful if already done)
      --skip-external-secrets Skip External Secrets configuration
      --skip-ingress          Skip Ingress creation
      --uninstall             Uninstall OpenBao and related resources
      --purge                 With --uninstall: also delete namespace, PV/PVC, and credentials file
  -v, --verbose               Enable verbose output
  -h, --help                  Show this help message

Examples:
  # Use existing manifest files (recommended)
  ./install-openbao.sh -m dev/soludev/openbao -f config/dev/openbao/values.yaml

  # Use inline templates (legacy mode)
  ./install-openbao.sh
  ./install-openbao.sh -n vault-ns -r my-vault
  ./install-openbao.sh -f config/dev/openbao/values.yaml
  ./install-openbao.sh --nfs-server 192.168.1.100 --nfs-path /mnt/nfs
  ./install-openbao.sh --skip-init --skip-external-secrets
  ./install-openbao.sh --uninstall
  ./install-openbao.sh --uninstall --purge

EOF
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        log_error "$1 is not installed or not in PATH"
        exit 1
    fi
    log_verbose "$1 is available"
}

wait_for_pod() {
    local pod_name=$1
    local namespace=$2
    local timeout=${3:-300}
    local interval=5
    local elapsed=0

    log_info "Waiting for pod $pod_name to be Running (timeout: ${timeout}s)..."

    while [[ $elapsed -lt $timeout ]]; do
        local status=$(kubectl get pod "$pod_name" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
        
        if [[ "$status" == "Running" ]]; then
            log_success "Pod $pod_name is Running"
            return 0
        fi

        log_verbose "Pod status: $status, waiting..."
        sleep $interval
        elapsed=$((elapsed + interval))
    done

    log_error "Timeout waiting for pod $pod_name"
    return 1
}

# =============================================================================
# PARSE ARGUMENTS
# =============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -n|--namespace)
                NAMESPACE="$2"
                shift 2
                ;;
            -r|--release)
                RELEASE_NAME="$2"
                shift 2
                ;;
            -f|--values)
                VALUES_FILE="$2"
                shift 2
                ;;
            -o|--output)
                OUTPUT_FILE="$2"
                shift 2
                ;;
            --nfs-server)
                NFS_SERVER="$2"
                shift 2
                ;;
            --nfs-path)
                NFS_BASE_PATH="$2"
                shift 2
                ;;
            --storage-size)
                STORAGE_SIZE="$2"
                shift 2
                ;;
            --ingress-host)
                INGRESS_HOST="$2"
                shift 2
                ;;
            -m|--manifests-dir)
                MANIFESTS_DIR="$2"
                shift 2
                ;;
            --skip-init)
                SKIP_INIT=true
                shift
                ;;
            --skip-external-secrets)
                SKIP_EXTERNAL_SECRETS=true
                shift
                ;;
            --skip-ingress)
                SKIP_INGRESS=true
                shift
                ;;
            --uninstall)
                UNINSTALL=true
                shift
                ;;
            --purge)
                PURGE=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# =============================================================================
# UNINSTALL FUNCTION
# =============================================================================

uninstall_openbao() {
    echo ""
    echo "============================================"
    echo "    OpenBao Uninstallation                  "
    echo "============================================"
    echo ""

    log_info "Starting OpenBao uninstallation..."

    # Confirmation prompt
    echo -e "${YELLOW}This will remove:${NC}"
    echo "  - Helm release: $RELEASE_NAME"
    echo "  - Ingress: openbao-ingress"
    echo "  - ClusterSecretStore: openbao-backend"
    echo "  - ClusterRoleBinding: openbao-auth-delegator"
    echo "  - ClusterRoleBinding: openbao-auth"
    echo "  - ClusterRoleBinding: openbao-tokenreview"
    echo "  - ServiceAccount: openbao (in $NAMESPACE)"
    echo "  - ServiceAccount: openbao-auth (in $NAMESPACE)"
    echo "  - ServiceAccount: external-secrets-sa (in $NAMESPACE)"
    if [[ "$PURGE" == true ]]; then
        echo "  - PersistentVolumeClaim: data-${RELEASE_NAME}-0 (in $NAMESPACE)"
        echo "  - PersistentVolume: nfs-${NAMESPACE}-openbao"
        echo "  - Namespace: $NAMESPACE (--purge)"
        echo "  - Credentials file: $OUTPUT_FILE (--purge)"
    fi
    echo ""

    read -p "Are you sure you want to continue? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Uninstallation cancelled"
        exit 0
    fi

    # 1. Delete Ingress
    if kubectl get ingress openbao-ingress -n "$NAMESPACE" &> /dev/null; then
        log_info "Deleting Ingress: openbao-ingress..."
        kubectl delete ingress openbao-ingress -n "$NAMESPACE"
        log_success "Ingress openbao-ingress deleted"
    else
        log_verbose "Ingress openbao-ingress not found"
    fi

    # 2. Delete ClusterSecretStore
    if kubectl get clustersecretstore openbao-backend &> /dev/null; then
        log_info "Deleting ClusterSecretStore: openbao-backend..."
        kubectl delete clustersecretstore openbao-backend
        log_success "ClusterSecretStore openbao-backend deleted"
    else
        log_verbose "ClusterSecretStore openbao-backend not found"
    fi

    # 3. Uninstall Helm release
    if helm status "$RELEASE_NAME" -n "$NAMESPACE" &> /dev/null; then
        log_info "Uninstalling Helm release: $RELEASE_NAME..."
        helm uninstall "$RELEASE_NAME" -n "$NAMESPACE"
        log_success "Helm release uninstalled"
    else
        log_verbose "Helm release $RELEASE_NAME not found"
    fi

    # 4. Delete ClusterRoleBindings
    if kubectl get clusterrolebinding openbao-auth-delegator &> /dev/null; then
        log_info "Deleting ClusterRoleBinding: openbao-auth-delegator..."
        kubectl delete clusterrolebinding openbao-auth-delegator
        log_success "ClusterRoleBinding openbao-auth-delegator deleted"
    else
        log_verbose "ClusterRoleBinding openbao-auth-delegator not found"
    fi

    if kubectl get clusterrolebinding openbao-auth &> /dev/null; then
        log_info "Deleting ClusterRoleBinding: openbao-auth..."
        kubectl delete clusterrolebinding openbao-auth
        log_success "ClusterRoleBinding openbao-auth deleted"
    else
        log_verbose "ClusterRoleBinding openbao-auth not found"
    fi

    if kubectl get clusterrolebinding openbao-tokenreview &> /dev/null; then
        log_info "Deleting ClusterRoleBinding: openbao-tokenreview..."
        kubectl delete clusterrolebinding openbao-tokenreview
        log_success "ClusterRoleBinding openbao-tokenreview deleted"
    else
        log_verbose "ClusterRoleBinding openbao-tokenreview not found"
    fi

    # 5. Delete ServiceAccounts (if not purging namespace)
    if [[ "$PURGE" == false ]]; then
        for sa in openbao openbao-auth external-secrets-sa; do
            if kubectl get serviceaccount "$sa" -n "$NAMESPACE" &> /dev/null; then
                log_info "Deleting ServiceAccount: $sa..."
                kubectl delete serviceaccount "$sa" -n "$NAMESPACE"
                log_success "ServiceAccount $sa deleted"
            else
                log_verbose "ServiceAccount $sa not found"
            fi
        done
    fi

    # Delete PVCs and PVs (data cleanup)
    if [[ "$PURGE" == true ]]; then
        # Delete Helm-created PVCs
        local pvcs
        pvcs=$(kubectl get pvc -n "$NAMESPACE" -l "app.kubernetes.io/instance=$RELEASE_NAME" -o name 2>/dev/null || true)
        if [[ -n "$pvcs" ]]; then
            log_info "Deleting Helm-managed PVCs..."
            kubectl delete pvc -n "$NAMESPACE" -l "app.kubernetes.io/instance=$RELEASE_NAME"
            log_success "Helm PVCs deleted"
        fi

        # Delete PV
        if kubectl get pv "nfs-${NAMESPACE}-openbao" &> /dev/null; then
            log_info "Deleting PersistentVolume: nfs-${NAMESPACE}-openbao..."
            kubectl delete pv "nfs-${NAMESPACE}-openbao"
            log_success "PV nfs-${NAMESPACE}-openbao deleted"
        else
            log_verbose "PV nfs-${NAMESPACE}-openbao not found"
        fi

        # Clean NFS data
        local nfs_path="${NFS_BASE_PATH}/${NAMESPACE}/openbao"
        log_info "Cleaning NFS data at ${NFS_SERVER}:${nfs_path}..."
        if ssh "${NFS_SERVER}" "rm -rf ${nfs_path}/*" 2>/dev/null; then
            log_success "NFS data cleaned"
        else
            log_warning "Could not clean NFS data (SSH failed or path doesn't exist)"
            log_info "You may need to manually run: ssh ${NFS_SERVER} 'rm -rf ${nfs_path}/*'"
        fi
    else
        log_info "PVCs and PVs retained. Use --purge to delete storage."
    fi

    # 7. Purge: Delete namespace and credentials
    if [[ "$PURGE" == true ]]; then
        # Delete namespace
        if kubectl get namespace "$NAMESPACE" &> /dev/null; then
            log_info "Deleting namespace: $NAMESPACE..."
            kubectl delete namespace "$NAMESPACE"
            log_success "Namespace $NAMESPACE deleted"
        else
            log_verbose "Namespace $NAMESPACE not found"
        fi

        # Delete credentials file
        if [[ -f "$OUTPUT_FILE" ]]; then
            log_info "Deleting credentials file: $OUTPUT_FILE..."
            rm -f "$OUTPUT_FILE"
            log_success "Credentials file deleted"
        else
            log_verbose "Credentials file $OUTPUT_FILE not found"
        fi
    fi

    echo ""
    echo "============================================"
    echo -e "${GREEN}OpenBao Uninstallation Complete${NC}"
    echo "============================================"
    echo ""

    if [[ "$PURGE" == false ]]; then
        log_info "Note: Namespace '$NAMESPACE' was preserved."
        log_info "Use --purge to also delete the namespace and credentials file."
    fi

    log_success "OpenBao uninstallation completed successfully!"
}

# =============================================================================
# PHASE 1: PREREQUISITES CHECK
# =============================================================================

check_prerequisites() {
    log_info "Checking prerequisites..."

    check_command "kubectl"
    check_command "helm"
    check_command "jq"

    # Check kubectl connection
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster. Check your kubeconfig."
        exit 1
    fi
    log_success "Connected to Kubernetes cluster"

    # Check if values file exists (if specified)
    if [[ -n "$VALUES_FILE" && ! -f "$VALUES_FILE" ]]; then
        log_error "Values file not found: $VALUES_FILE"
        exit 1
    fi

    # Check if manifests directory exists (if specified)
    if [[ -n "$MANIFESTS_DIR" ]]; then
        if [[ ! -d "$MANIFESTS_DIR" ]]; then
            log_error "Manifests directory not found: $MANIFESTS_DIR"
            exit 1
        fi
        log_success "Using manifest files from: $MANIFESTS_DIR"
        log_verbose "Available manifests:"
        for f in "$MANIFESTS_DIR"/*.yaml; do
            [[ -f "$f" ]] && log_verbose "  - $(basename "$f")"
        done
    fi

    log_success "Prerequisites check passed"
}

# ============================================================================
# PHASE 2: NAMESPACE AND SERVICE ACCOUNTS
# =============================================================================

setup_namespace() {
    log_info "Setting up namespace and service accounts..."

    # Create namespace if it doesn't exist
    if kubectl get namespace "$NAMESPACE" &> /dev/null; then
        log_verbose "Namespace $NAMESPACE already exists"
    else
        kubectl create namespace "$NAMESPACE"
        log_success "Created namespace: $NAMESPACE"
    fi

    # Use manifest files if MANIFESTS_DIR is set
    if [[ -n "$MANIFESTS_DIR" ]]; then
        local sa_file="$MANIFESTS_DIR/service-account.yaml"
        if [[ -f "$sa_file" ]]; then
            log_info "Applying ServiceAccount from $sa_file..."
            kubectl apply -f "$sa_file"
            log_success "ServiceAccount applied from manifest"
        else
            log_error "ServiceAccount manifest not found: $sa_file"
            exit 1
        fi
    else
        # Create openbao service account (inline mode)
        if kubectl get serviceaccount openbao -n "$NAMESPACE" &> /dev/null; then
            log_verbose "ServiceAccount openbao already exists"
        else
            kubectl create serviceaccount openbao -n "$NAMESPACE"
            log_success "Created ServiceAccount: openbao"
        fi

        # Create ClusterRoleBinding for openbao (only in inline mode, otherwise handled by apply_rbac_manifests)
        if kubectl get clusterrolebinding openbao-auth-delegator &> /dev/null; then
            log_verbose "ClusterRoleBinding openbao-auth-delegator already exists"
        else
            kubectl create clusterrolebinding openbao-auth-delegator \
                --clusterrole=system:auth-delegator \
                --serviceaccount="$NAMESPACE:openbao"
            log_success "Created ClusterRoleBinding: openbao-auth-delegator"
        fi
    fi

    log_success "Namespace and service accounts configured"
}

# =============================================================================
# PHASE 2.5: NFS STORAGE SETUP
# =============================================================================

apply_storage_manifests() {
    log_info "Setting up NFS storage for OpenBao..."

    # Use manifest files if MANIFESTS_DIR is set
    if [[ -n "$MANIFESTS_DIR" ]]; then
        local pv_file="$MANIFESTS_DIR/persistence-volume.yaml"
        if [[ -f "$pv_file" ]]; then
            log_info "Applying PersistentVolume from $pv_file..."
            kubectl apply -f "$pv_file"
            log_success "PersistentVolume applied from manifest"
        else
            log_error "PersistentVolume manifest not found: $pv_file"
            exit 1
        fi
    else
        # Inline mode: create PV dynamically
        log_info "Creating PersistentVolume (inline mode)..."
        cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: nfs-${NAMESPACE}-openbao
spec:
  capacity:
    storage: ${STORAGE_SIZE}
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ${STORAGE_CLASS_NAME}
  nfs:
    server: ${NFS_SERVER}
    path: ${NFS_BASE_PATH}/${NAMESPACE}/openbao
  mountOptions:
    - nfsvers=4.1
    - hard
    - timeo=600
    - retrans=2
EOF
    log_success "PersistentVolume created: nfs-${NAMESPACE}-openbao"
    fi

    log_info "PVC will be created by Helm (name: data-${RELEASE_NAME}-0)"
}

# =============================================================================
# PHASE 2.6: RBAC SETUP
# =============================================================================

apply_rbac_manifests() {
    log_info "Applying RBAC manifests..."

    # Use manifest files if MANIFESTS_DIR is set
    if [[ -n "$MANIFESTS_DIR" ]]; then
        local crb_file="$MANIFESTS_DIR/cluster-role-binding.yaml"
        local es_sa_file="$MANIFESTS_DIR/service-account-external-secret.yaml"

        # Apply ClusterRoleBinding
        if [[ -f "$crb_file" ]]; then
            log_info "Applying ClusterRoleBinding from $crb_file..."
            kubectl apply -f "$crb_file"
            log_success "ClusterRoleBinding applied from manifest"
        else
            log_error "ClusterRoleBinding manifest not found: $crb_file"
            exit 1
        fi

        # Apply External Secrets ServiceAccount
        if [[ -f "$es_sa_file" ]]; then
            log_info "Applying External Secrets ServiceAccount from $es_sa_file..."
            kubectl apply -f "$es_sa_file"
            log_success "External Secrets ServiceAccount applied from manifest"
        else
            log_error "External Secrets ServiceAccount manifest not found: $es_sa_file"
            exit 1
        fi
    else
        # Inline mode
        apply_rbac_inline_crb
        apply_rbac_inline_es_sa
    fi
}

apply_rbac_inline_crb() {
    log_info "Creating ClusterRoleBinding for token review (inline mode)..."
    cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: openbao-tokenreview
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
- kind: ServiceAccount
  name: openbao
  namespace: ${NAMESPACE}
EOF
    log_success "ClusterRoleBinding openbao-tokenreview created"
}

apply_rbac_inline_es_sa() {
    log_info "Creating ServiceAccount for External Secrets (inline mode)..."
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: external-secrets-sa
  namespace: ${NAMESPACE}
  annotations:
    vault.hashicorp.com/auth-path: "auth/kubernetes"
    vault.hashicorp.com/role: "external-secrets-role"
EOF
    log_success "ServiceAccount external-secrets-sa created"
}

# =============================================================================
# PHASE 3: HELM INSTALLATION
# =============================================================================

install_external_secrets_operator() {
    log_info "Installing External Secrets Operator..."

    # Add Helm repo
    if helm repo list | grep -q "external-secrets"; then
        log_verbose "External Secrets Helm repo already added"
    else
        helm repo add external-secrets https://charts.external-secrets.io
        log_success "Added External Secrets Helm repository"
    fi

    helm repo update

    # Check if already installed
    if helm status external-secrets -n external-secrets &> /dev/null; then
        log_verbose "External Secrets Operator already installed"
    else
        helm install external-secrets external-secrets/external-secrets \
            -n external-secrets --create-namespace --wait
        log_success "External Secrets Operator installed"
    fi
}

install_openbao() {
    log_info "Installing OpenBao via Helm..."

    # Add Helm repo
    if helm repo list | grep -q "openbao"; then
        log_verbose "OpenBao Helm repo already added"
    else
        helm repo add openbao https://openbao.github.io/openbao-helm
        log_success "Added OpenBao Helm repository"
    fi

    helm repo update
    log_verbose "Helm repositories updated"

    # Check if already installed
    if helm status "$RELEASE_NAME" -n "$NAMESPACE" &> /dev/null; then
        log_warning "OpenBao release '$RELEASE_NAME' already exists. Upgrading..."
        HELM_CMD="upgrade"
    else
        HELM_CMD="install"
    fi

    # Build Helm command
    local helm_args=("$HELM_CMD" "$RELEASE_NAME" "openbao/openbao" "--namespace" "$NAMESPACE")

    # Add values file if specified
    if [[ -n "$VALUES_FILE" ]]; then
        helm_args+=("-f" "$VALUES_FILE")
    fi

    # Always set these values for standalone NFS setup
    helm_args+=("--set" "server.serviceAccount.create=false")
    helm_args+=("--set" "server.serviceAccount.name=openbao")



    # Let Helm create the PVC via StatefulSet volumeClaimTemplate
    # The PVC will bind to our pre-created PV via the storageClassName
    helm_args+=("--set" "server.dataStorage.enabled=true")
    helm_args+=("--set" "server.dataStorage.storageClass=${STORAGE_CLASS_NAME}")
    helm_args+=("--set" "server.dataStorage.size=${STORAGE_SIZE}")
    helm_args+=("--set" "server.dataStorage.accessMode=ReadWriteMany")
    helm_args+=("--set" "server.standalone.enabled=true")
    helm_args+=("--set" "server.ha.enabled=false")

    log_verbose "Running: helm ${helm_args[*]}"
    helm "${helm_args[@]}"

    log_success "OpenBao Helm $HELM_CMD completed"
}

# =============================================================================
# PHASE 4: INITIALIZATION AND UNSEAL
# =============================================================================

initialize_openbao() {
    if [[ "$SKIP_INIT" == true ]]; then
        log_info "Skipping initialization (--skip-init)"
        return 0
    fi

    local pod_name="${RELEASE_NAME}-0"

    # Wait for pod to be running
    wait_for_pod "$pod_name" "$NAMESPACE" 300

    log_info "Initializing OpenBao..."

    # Initialize and capture output
    local init_output
    init_output=$(kubectl exec -n "$NAMESPACE" "$pod_name" -- bao operator init -format=json)

    if [[ -z "$init_output" ]]; then
        log_error "Failed to initialize OpenBao"
        exit 1
    fi

    # Parse credentials
    local root_token
    root_token=$(echo "$init_output" | jq -r '.root_token')

    local unseal_keys
    unseal_keys=$(echo "$init_output" | jq -r '.unseal_keys_b64[]')

    # Save credentials to file
    echo "$init_output" > "$OUTPUT_FILE"
    chmod 600 "$OUTPUT_FILE"
    log_success "Credentials saved to: $OUTPUT_FILE"
    log_warning "IMPORTANT: Secure this file immediately! It contains sensitive data."

    # Display root token
    echo ""
    log_info "============================================"
    log_info "ROOT TOKEN: $root_token"
    log_info "============================================"
    echo ""

    # Unseal with first 3 keys
    log_info "Unsealing OpenBao..."
    
    local key_count=0
    while IFS= read -r key; do
        if [[ $key_count -lt 3 ]]; then
            kubectl exec -n "$NAMESPACE" "$pod_name" -- bao operator unseal "$key" > /dev/null
            key_count=$((key_count + 1))
            log_verbose "Applied unseal key $key_count/3"
        fi
    done <<< "$unseal_keys"

    # Verify unseal
    local sealed_status
    sealed_status=$(kubectl exec -n "$NAMESPACE" "$pod_name" -- bao status -format=json | jq -r '.sealed')

    if [[ "$sealed_status" == "false" ]]; then
        log_success "OpenBao successfully unsealed"
    else
        log_error "Failed to unseal OpenBao"
        exit 1
    fi

    # Export root token for next steps
    export VAULT_TOKEN="$root_token"
    log_success "OpenBao initialization completed"
}

# =============================================================================
# PHASE 5: KUBERNETES AUTH CONFIGURATION
# =============================================================================

configure_kubernetes_auth() {
    if [[ "$SKIP_INIT" == true ]]; then
        log_info "Skipping Kubernetes auth configuration (--skip-init)"
        return 0
    fi

    local pod_name="${RELEASE_NAME}-0"

    # Check if VAULT_TOKEN is set
    if [[ -z "$VAULT_TOKEN" ]]; then
        # Try to read from credentials file
        if [[ -f "$OUTPUT_FILE" ]]; then
            VAULT_TOKEN=$(jq -r '.root_token' "$OUTPUT_FILE")
            export VAULT_TOKEN
        else
            log_error "VAULT_TOKEN not set and credentials file not found"
            log_info "Please set VAULT_TOKEN environment variable or run without --skip-init"
            exit 1
        fi
    fi

    log_info "Configuring Kubernetes authentication..."

    # Create openbao-auth service account
    if kubectl get serviceaccount openbao-auth -n "$NAMESPACE" &> /dev/null; then
        log_verbose "ServiceAccount openbao-auth already exists"
    else
        kubectl create serviceaccount openbao-auth -n "$NAMESPACE"
        log_success "Created ServiceAccount: openbao-auth"
    fi

    # Create ClusterRoleBinding for openbao-auth
    if kubectl get clusterrolebinding openbao-auth &> /dev/null; then
        log_verbose "ClusterRoleBinding openbao-auth already exists"
    else
        kubectl create clusterrolebinding openbao-auth \
            --clusterrole=system:auth-delegator \
            --serviceaccount="$NAMESPACE:openbao-auth"
        log_success "Created ClusterRoleBinding: openbao-auth"
    fi

    # Enable Kubernetes auth method
    local auth_enabled
    auth_enabled=$(kubectl exec -n "$NAMESPACE" "$pod_name" -- \
        env VAULT_TOKEN="$VAULT_TOKEN" bao auth list -format=json 2>/dev/null | jq -r 'has("kubernetes/")' || echo "false")

    if [[ "$auth_enabled" == "true" ]]; then
        log_verbose "Kubernetes auth method already enabled"
    else
        kubectl exec -n "$NAMESPACE" "$pod_name" -- \
            env VAULT_TOKEN="$VAULT_TOKEN" bao auth enable kubernetes
        log_success "Enabled Kubernetes auth method"
    fi

    # Configure Kubernetes auth
    kubectl exec -n "$NAMESPACE" "$pod_name" -- \
        env VAULT_TOKEN="$VAULT_TOKEN" bao write auth/kubernetes/config \
        kubernetes_host="https://kubernetes.default.svc" \
        kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
        disable_iss_validation=true

    log_success "Kubernetes auth method configured"
}

# =============================================================================
# PHASE 6: EXTERNAL SECRETS CONFIGURATION
# =============================================================================

configure_external_secrets() {
    if [[ "$SKIP_EXTERNAL_SECRETS" == true ]]; then
        log_info "Skipping External Secrets configuration (--skip-external-secrets)"
        return 0
    fi

    if [[ "$SKIP_INIT" == true ]]; then
        log_info "Skipping External Secrets configuration (--skip-init implies no token)"
        return 0
    fi

    local pod_name="${RELEASE_NAME}-0"

    log_info "Configuring External Secrets integration..."

    # Create external-secrets-sa service account
    if kubectl get serviceaccount external-secrets-sa -n "$NAMESPACE" &> /dev/null; then
        log_verbose "ServiceAccount external-secrets-sa already exists"
    else
        kubectl create serviceaccount external-secrets-sa -n "$NAMESPACE"
        log_success "Created ServiceAccount: external-secrets-sa"
    fi

    # Enable KV secrets engine (if not already enabled)
    local kv_enabled
    kv_enabled=$(kubectl exec -n "$NAMESPACE" "$pod_name" -- \
        env VAULT_TOKEN="$VAULT_TOKEN" bao secrets list -format=json 2>/dev/null | jq -r 'has("kv/")' || echo "false")

    if [[ "$kv_enabled" == "true" ]]; then
        log_verbose "KV secrets engine already enabled"
    else
        kubectl exec -n "$NAMESPACE" "$pod_name" -- \
            env VAULT_TOKEN="$VAULT_TOKEN" bao secrets enable -path=kv kv-v2
        log_success "Enabled KV v2 secrets engine at path 'kv/'"
    fi

    # Create policy for external secrets
    kubectl exec -n "$NAMESPACE" "$pod_name" -- sh -c "echo 'path \"kv/data/*\" {
  capabilities = [\"read\", \"list\"]
}
path \"kv/metadata/*\" {
  capabilities = [\"read\", \"list\"]
}' | env VAULT_TOKEN=\"$VAULT_TOKEN\" bao policy write external-secrets-policy -"

    log_success "Created policy: external-secrets-policy"

    # Create role for external secrets
    kubectl exec -n "$NAMESPACE" "$pod_name" -- \
        env VAULT_TOKEN="$VAULT_TOKEN" bao write auth/kubernetes/role/external-secrets-role \
        bound_service_account_names=external-secrets-sa \
        bound_service_account_namespaces="$NAMESPACE" \
        policies=external-secrets-policy \
        ttl=24h

    log_success "Created role: external-secrets-role"
    log_success "External Secrets integration configured"
}

# =============================================================================
# PHASE 7: INGRESS AND SECRET STORE
# =============================================================================

apply_ingress_and_secretstore() {












    # Apply Ingress
    if [[ -n "$MANIFESTS_DIR" ]]; then
        local ingress_file="$MANIFESTS_DIR/ingress.yaml"
        if [[ -f "$ingress_file" ]]; then
            log_info "Applying Ingress from $ingress_file..."
            kubectl apply -f "$ingress_file"
            log_success "Ingress applied from manifest"
        else

            log_error "Ingress manifest not found: $ingress_file"
            exit 1
        fi
    else

        apply_ingress_inline
    fi

    # Apply ClusterSecretStore
    if [[ -n "$MANIFESTS_DIR" ]]; then
        local secretstore_file="$MANIFESTS_DIR/secret-store.yaml"
        if [[ -f "$secretstore_file" ]]; then
            log_info "Applying ClusterSecretStore from $secretstore_file..."
            kubectl apply -f "$secretstore_file"
            log_success "ClusterSecretStore applied from manifest"
        else

            log_error "ClusterSecretStore manifest not found: $secretstore_file"
            exit 1
        fi
    else

        apply_secretstore_inline
    fi
}

apply_secretstore_inline() {
    log_info "Creating ClusterSecretStore (inline mode)..."
    cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: openbao-backend
spec:
  provider:
    vault:
      server: "http://${RELEASE_NAME}.${NAMESPACE}.svc.cluster.local:8200"
      path: "kv"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "external-secrets-role"
          serviceAccountRef:
            name: "external-secrets-sa"
            namespace: "${NAMESPACE}"
EOF
    log_success "ClusterSecretStore openbao-backend created"
}

apply_ingress_inline() {
    log_info "Creating Ingress (inline mode)..."
    cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: openbao-ingress
  namespace: ${NAMESPACE}
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web,websecure
    traefik.ingress.kubernetes.io/redirect-scheme: https
spec:
  rules:
    - host: ${INGRESS_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ${RELEASE_NAME}
                port:
                  number: 8200
EOF
    log_success "Ingress openbao-ingress created (host: ${INGRESS_HOST})"
}

# =============================================================================
# SUMMARY
# =============================================================================

print_summary() {
    echo ""
    echo "============================================"
    echo -e "${GREEN}OpenBao Installation Summary${NC}"
    echo "============================================"
    echo ""
    echo "Namespace:     $NAMESPACE"
    echo "Release Name:  $RELEASE_NAME"
    echo "Pod Name:      ${RELEASE_NAME}-0"
    echo ""

    if [[ -f "$OUTPUT_FILE" ]]; then
        echo "Credentials:   $OUTPUT_FILE"
        echo ""
        echo -e "${YELLOW}Root Token:${NC}"
        jq -r '.root_token' "$OUTPUT_FILE"
        echo ""
    fi

    echo "Useful commands:"
    echo "  # Check status"
    echo "  kubectl exec -n $NAMESPACE ${RELEASE_NAME}-0 -- bao status"
    echo ""
    echo "  # Port forward to UI"
    echo "  kubectl port-forward -n $NAMESPACE svc/${RELEASE_NAME} 8200:8200"
    echo ""
    echo "  # Access UI at http://localhost:8200"
    echo ""

    if [[ "$SKIP_EXTERNAL_SECRETS" == false && "$SKIP_INIT" == false ]]; then
        echo "External Secrets:"
        echo "  ServiceAccount: external-secrets-sa"
        echo "  Role:           external-secrets-role"
        echo "  Policy:         external-secrets-policy"
        echo "  SecretStore:    openbao-backend"
        echo ""
    fi

    if [[ "$SKIP_INGRESS" == false ]]; then
        echo "Ingress:"
        if [[ -n "$MANIFESTS_DIR" ]]; then
            echo "  Source: $MANIFESTS_DIR/ingress.yaml"
        else
            echo "  Host: ${INGRESS_HOST}"
            echo "  URL:  https://${INGRESS_HOST}"
        fi
        echo ""
    fi

    if [[ -n "$MANIFESTS_DIR" ]]; then
        echo "Manifests:"
        echo "  Directory:     $MANIFESTS_DIR"
        echo "  Mode:          CRD files"
    else
        echo "NFS Storage:"
        echo "  Server:        ${NFS_SERVER}"
        echo "  Path:          ${NFS_BASE_PATH}/${NAMESPACE}/openbao"
        echo "  StorageClass:  ${STORAGE_CLASS_NAME}"
        echo "  Size:          ${STORAGE_SIZE}"
    fi
    echo ""

    echo "============================================"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    parse_args "$@"

    # Handle uninstall mode
    if [[ "$UNINSTALL" == true ]]; then
        check_command "kubectl"
        check_command "helm"
        
        if ! kubectl cluster-info &> /dev/null; then
            log_error "Cannot connect to Kubernetes cluster. Check your kubeconfig."
            exit 1
        fi
        
        uninstall_openbao
        exit 0
    fi

    # Normal installation flow
    echo ""
    echo "============================================"
    echo "    OpenBao Standalone Installation         "
    echo "============================================"
    echo ""
    echo "Configuration:"
    echo "  Namespace:      $NAMESPACE"
    echo "  Release:        $RELEASE_NAME"
    if [[ -n "$MANIFESTS_DIR" ]]; then
        echo "  Manifests Dir:  $MANIFESTS_DIR (using CRD files)"
    else
        echo "  Mode:           Inline templates"
        echo "  NFS Server:     $NFS_SERVER"
        echo "  NFS Path:       $NFS_BASE_PATH/$NAMESPACE/openbao"
        echo "  Storage Size:   $STORAGE_SIZE"
        echo "  Ingress Host:   $INGRESS_HOST"
    fi
    echo ""

    check_prerequisites
    setup_namespace
    apply_storage_manifests
    apply_rbac_manifests
    install_external_secrets_operator
    install_openbao
    initialize_openbao
    configure_kubernetes_auth
    configure_external_secrets
    apply_ingress_and_secretstore

    print_summary

    log_success "OpenBao standalone installation completed successfully!"
}

main "$@"
