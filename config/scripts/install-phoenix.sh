#!/bin/bash
#
# Phoenix Installation Script for K3s
# Installs Phoenix AI Observability Platform with external PostgreSQL and OpenBao secrets
#
# Usage: ./install-phoenix.sh <COMMAND> [OPTIONS]
#

set -e

# =============================================================================
# DEFAULT CONFIGURATION
# =============================================================================

NAMESPACE="soludev"
PHOENIX_VERSION="4.0.6"
VALUES_FILE="config/dev/phoenix/values.yaml"
EXTERNAL_SECRET_FILE="dev/soludev/phoenix/external-secret.yaml"
SECRET_NAME="soludev-phoenix-secret"
RELEASE_NAME="phoenix"
SKIP_EXTERNAL_SECRET=false
VERBOSE=false
PURGE=false
COMMAND=""

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
Phoenix Installation Script for K3s

Usage: ./install-phoenix.sh <COMMAND> [OPTIONS]

Commands:
  install                     Install Phoenix AI Observability Platform
  uninstall                   Uninstall Phoenix

Options (install):
  -n, --namespace NAME        Target namespace (default: soludev)
  -V, --version VERSION       Phoenix Helm chart version (default: 4.0.6)
  -f, --values-file FILE      Custom values file (default: config/dev/phoenix/values.yaml)
      --skip-external-secret  Skip ExternalSecret creation

Options (uninstall):
      --purge                 Also delete ExternalSecret and secrets

Common Options:
  -v, --verbose               Enable verbose output
  -h, --help                  Show this help message

Prerequisites:
  - PostgreSQL database 'phoenix' created with user 'phoenix'
  - Secrets stored in OpenBao at 'soludev/phoenix':
    - PHOENIX_SECRET (32+ chars)
    - PHOENIX_ADMIN_SECRET (32+ chars)
    - PHOENIX_POSTGRES_PASSWORD
    - PHOENIX_SMTP_PASSWORD
    - PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD

Examples:
  ./install-phoenix.sh install
  ./install-phoenix.sh install -n soludev -V 4.0.6
  ./install-phoenix.sh install --skip-external-secret
  ./install-phoenix.sh uninstall
  ./install-phoenix.sh uninstall --purge

EOF
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        log_error "$1 is not installed or not in PATH"
        exit 1
    fi
    log_verbose "$1 is available"
}

wait_for_secret() {
    local secret_name=$1
    local namespace=$2
    local timeout=${3:-60}
    local interval=5
    local elapsed=0

    log_info "Waiting for secret $secret_name to be ready..."

    while [[ $elapsed -lt $timeout ]]; do
        if kubectl get secret "$secret_name" -n "$namespace" &> /dev/null; then
            # Check if the secret has all required keys
            local keys
            keys=$(kubectl get secret "$secret_name" -n "$namespace" -o jsonpath='{.data}' 2>/dev/null | grep -o '"[^"]*":' | wc -l || echo "0")
            
            if [[ "$keys" -ge 5 ]]; then
                log_success "Secret $secret_name is ready with $keys keys"
                return 0
            fi
            log_verbose "Secret exists but only has $keys keys, waiting..."
        fi

        sleep $interval
        elapsed=$((elapsed + interval))
        log_verbose "Waiting for secret... ($elapsed/$timeout seconds)"
    done

    log_error "Timeout waiting for secret $secret_name"
    return 1
}

wait_for_phoenix() {
    local timeout=${1:-300}
    local interval=10
    local elapsed=0

    log_info "Waiting for Phoenix deployment to be ready..."

    while [[ $elapsed -lt $timeout ]]; do
        local ready
        ready=$(kubectl get deployment "$RELEASE_NAME" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        local desired
        desired=$(kubectl get deployment "$RELEASE_NAME" -n "$NAMESPACE" -o jsonpath='{.status.replicas}' 2>/dev/null || echo "1")

        if [[ "$ready" -ge "$desired" && "$ready" -gt 0 ]]; then
            log_success "Phoenix deployment is ready ($ready/$desired replicas)"
            return 0
        fi

        log_verbose "Phoenix deployment: $ready/$desired ready, waiting..."
        sleep $interval
        elapsed=$((elapsed + interval))
    done

    log_warning "Timeout waiting for Phoenix deployment, it may still be starting..."
    return 0
}

# =============================================================================
# PARSE ARGUMENTS
# =============================================================================

parse_args() {
    # First argument should be the command
    if [[ $# -eq 0 ]]; then
        log_error "No command specified"
        show_help
        exit 1
    fi

    # Parse command
    case $1 in
        install)
            COMMAND="install"
            shift
            ;;
        uninstall)
            COMMAND="uninstall"
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            log_error "Unknown command: $1"
            show_help
            exit 1
            ;;
    esac

    # Parse options
    while [[ $# -gt 0 ]]; do
        case $1 in
            -n|--namespace)
                NAMESPACE="$2"
                shift 2
                ;;
            -V|--version)
                PHOENIX_VERSION="$2"
                shift 2
                ;;
            -f|--values-file)
                VALUES_FILE="$2"
                shift 2
                ;;
            --skip-external-secret)
                SKIP_EXTERNAL_SECRET=true
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
# PREREQUISITES CHECK
# =============================================================================

check_prerequisites() {
    log_info "Checking prerequisites..."

    check_command "kubectl"
    check_command "helm"

    # Check kubectl connection
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster. Check your kubeconfig."
        exit 1
    fi
    log_success "Connected to Kubernetes cluster"

    # Check if namespace exists
    if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
        log_info "Creating namespace $NAMESPACE..."
        kubectl create namespace "$NAMESPACE"
        log_success "Namespace $NAMESPACE created"
    else
        log_verbose "Namespace $NAMESPACE already exists"
    fi

    # Check External Secrets Operator
    if ! kubectl get crd externalsecrets.external-secrets.io &> /dev/null; then
        log_warning "External Secrets Operator CRD not found. ExternalSecret creation may fail."
    else
        log_verbose "External Secrets Operator is available"
    fi

    # Check values file
    if [[ ! -f "$VALUES_FILE" ]]; then
        log_error "Values file not found: $VALUES_FILE"
        exit 1
    fi
    log_verbose "Values file: $VALUES_FILE"

    log_success "Prerequisites check passed"
}

# =============================================================================
# EXTERNAL SECRET SETUP
# =============================================================================

setup_external_secret() {
    if [[ "$SKIP_EXTERNAL_SECRET" == true ]]; then
        log_info "Skipping ExternalSecret creation (--skip-external-secret)"
        return 0
    fi

    log_info "Setting up ExternalSecret for Phoenix..."

    if [[ -f "$EXTERNAL_SECRET_FILE" ]]; then
        kubectl apply -f "$EXTERNAL_SECRET_FILE"
        log_success "ExternalSecret applied from $EXTERNAL_SECRET_FILE"
    else
        log_warning "ExternalSecret file not found: $EXTERNAL_SECRET_FILE"
        log_info "Creating ExternalSecret inline..."
        
        cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: soludev-phoenix-external-secret
  namespace: $NAMESPACE
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: openbao-backend
    kind: ClusterSecretStore
  target:
    name: $SECRET_NAME
    creationPolicy: Owner
  dataFrom:
  - extract:
      key: soludev/phoenix
EOF
        log_success "ExternalSecret created inline"
    fi

    # Wait for secret to be synced
    wait_for_secret "$SECRET_NAME" "$NAMESPACE" 60
}

# =============================================================================
# CREATE SECRETS VALUES FILE
# =============================================================================

create_secrets_values_file() {
    log_info "Creating temporary secrets values file..."

    # Check if secret exists
    if ! kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &> /dev/null; then
        log_error "Secret $SECRET_NAME not found in namespace $NAMESPACE"
        log_error "Please ensure ExternalSecret is configured and OpenBao secrets are set up"
        exit 1
    fi

    # Extract secrets from Kubernetes secret
    local phoenix_secret
    local phoenix_admin_secret
    local phoenix_postgres_password
    local phoenix_smtp_password
    local phoenix_admin_password

    phoenix_secret=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.PHOENIX_SECRET}' | base64 -d 2>/dev/null || echo "")
    phoenix_admin_secret=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.PHOENIX_ADMIN_SECRET}' | base64 -d 2>/dev/null || echo "")
    phoenix_postgres_password=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.PHOENIX_POSTGRES_PASSWORD}' | base64 -d 2>/dev/null || echo "")
    phoenix_smtp_password=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.PHOENIX_SMTP_PASSWORD}' | base64 -d 2>/dev/null || echo "")
    phoenix_admin_password=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD}' | base64 -d 2>/dev/null || echo "")

    # Validate required secrets
    if [[ -z "$phoenix_secret" ]]; then
        log_error "PHOENIX_SECRET is empty or not found"
        exit 1
    fi
    if [[ ${#phoenix_secret} -lt 32 ]]; then
        log_warning "PHOENIX_SECRET should be at least 32 characters (current: ${#phoenix_secret})"
    fi
    if [[ -z "$phoenix_admin_secret" ]]; then
        log_error "PHOENIX_ADMIN_SECRET is empty or not found"
        exit 1
    fi
    if [[ ${#phoenix_admin_secret} -lt 32 ]]; then
        log_warning "PHOENIX_ADMIN_SECRET should be at least 32 characters (current: ${#phoenix_admin_secret})"
    fi
    if [[ -z "$phoenix_postgres_password" ]]; then
        log_error "PHOENIX_POSTGRES_PASSWORD is empty or not found"
        exit 1
    fi

    log_verbose "All required secrets found"

    # Create temporary values file
    cat > /tmp/phoenix-secrets.yaml <<EOF
database:
  postgres:
    password: "${phoenix_postgres_password}"

auth:
  secret:
    - key: "PHOENIX_SECRET"
      value: "${phoenix_secret}"
    - key: "PHOENIX_ADMIN_SECRET"
      value: "${phoenix_admin_secret}"
    - key: "PHOENIX_POSTGRES_PASSWORD"
      value: "${phoenix_postgres_password}"
    - key: "PHOENIX_SMTP_PASSWORD"
      value: "${phoenix_smtp_password}"
    - key: "PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD"
      value: "${phoenix_admin_password}"
EOF

    log_success "Temporary secrets values file created"
}

# =============================================================================
# INSTALL PHOENIX
# =============================================================================

install_phoenix() {
    log_info "Installing Phoenix AI Observability Platform..."

    # Create temporary values file with secrets
    create_secrets_values_file

    # Check if Phoenix is already installed
    local install_action="install"
    if helm status "$RELEASE_NAME" -n "$NAMESPACE" &> /dev/null; then
        log_info "Phoenix is already installed, upgrading..."
        install_action="upgrade"
    fi

    # Install/upgrade Phoenix via Helm
    log_info "Running helm $install_action..."
    
    helm upgrade --install "$RELEASE_NAME" \
        oci://registry-1.docker.io/arizephoenix/phoenix-helm \
        --version "$PHOENIX_VERSION" \
        -n "$NAMESPACE" \
        -f "$VALUES_FILE" \
        -f /tmp/phoenix-secrets.yaml \
        --wait \
        --timeout 5m

    # Cleanup temporary file
    rm -f /tmp/phoenix-secrets.yaml
    log_verbose "Temporary secrets file cleaned up"

    # Wait for deployment
    wait_for_phoenix 300

    log_success "Phoenix installed successfully"
}

# =============================================================================
# UNINSTALL PHOENIX
# =============================================================================

uninstall_phoenix() {
    echo ""
    echo "============================================"
    echo "    Phoenix Uninstallation                  "
    echo "============================================"
    echo ""

    log_info "Starting Phoenix uninstallation..."

    # Confirmation prompt
    echo -e "${YELLOW}This will remove:${NC}"
    echo "  - Phoenix Helm release"
    if [[ "$PURGE" == true ]]; then
        echo "  - ExternalSecret: soludev-phoenix-external-secret"
        echo "  - Secret: $SECRET_NAME"
    fi
    echo ""

    read -p "Are you sure you want to continue? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Uninstallation cancelled"
        exit 0
    fi

    # Uninstall Helm release
    if helm status "$RELEASE_NAME" -n "$NAMESPACE" &> /dev/null; then
        log_info "Uninstalling Phoenix Helm release..."
        helm uninstall "$RELEASE_NAME" -n "$NAMESPACE"
        log_success "Phoenix Helm release uninstalled"
    else
        log_verbose "Phoenix Helm release not found"
    fi

    # Purge: Delete ExternalSecret and secrets
    if [[ "$PURGE" == true ]]; then
        log_info "Purging ExternalSecret and secrets..."
        
        # Delete ExternalSecret
        if kubectl get externalsecret soludev-phoenix-external-secret -n "$NAMESPACE" &> /dev/null; then
            kubectl delete externalsecret soludev-phoenix-external-secret -n "$NAMESPACE"
            log_success "ExternalSecret deleted"
        else
            log_verbose "ExternalSecret not found"
        fi

        # Delete secret
        if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &> /dev/null; then
            kubectl delete secret "$SECRET_NAME" -n "$NAMESPACE"
            log_success "Secret $SECRET_NAME deleted"
        else
            log_verbose "Secret $SECRET_NAME not found"
        fi
    fi

    echo ""
    echo "============================================"
    echo -e "${GREEN}Phoenix Uninstallation Complete${NC}"
    echo "============================================"
    echo ""

    if [[ "$PURGE" == false ]]; then
        log_info "Note: ExternalSecret and secrets were preserved."
        log_info "Use --purge to also delete ExternalSecret and secrets."
    fi

    log_success "Phoenix uninstallation completed successfully!"
}

# =============================================================================
# SUMMARY
# =============================================================================

print_summary() {
    echo ""
    echo "============================================"
    echo -e "${GREEN}Phoenix Installation Summary${NC}"
    echo "============================================"
    echo ""
    echo "Namespace:         $NAMESPACE"
    echo "Release Name:      $RELEASE_NAME"
    echo "Chart Version:     $PHOENIX_VERSION"
    echo "Values File:       $VALUES_FILE"
    echo ""

    # Get Phoenix service info
    local phoenix_port
    phoenix_port=$(kubectl get svc "$RELEASE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "6006")

    echo "Phoenix Service:"
    echo "  - Name: $RELEASE_NAME"
    echo "  - Port: $phoenix_port"
    echo ""

    echo "Useful commands:"
    echo "  # Check Phoenix status"
    echo "  kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=phoenix"
    echo ""
    echo "  # View Phoenix logs"
    echo "  kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=phoenix -f"
    echo ""
    echo "  # Port-forward to access Phoenix UI"
    echo "  kubectl port-forward -n $NAMESPACE svc/$RELEASE_NAME $phoenix_port:$phoenix_port"
    echo "  # Then open: http://localhost:$phoenix_port"
    echo ""
    echo "  # Check Helm release status"
    echo "  helm status $RELEASE_NAME -n $NAMESPACE"
    echo ""
    echo "  # Upgrade Phoenix"
    echo "  ./config/scripts/install-phoenix.sh install -V <new-version>"
    echo ""
    echo "============================================"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    parse_args "$@"

    case $COMMAND in
        install)
            echo ""
            echo "============================================"
            echo "    Phoenix Installation Script for K3s    "
            echo "============================================"
            echo ""

            check_prerequisites
            setup_external_secret
            install_phoenix
            print_summary

            log_success "Phoenix installation completed successfully!"
            ;;
        uninstall)
            uninstall_phoenix
            ;;
        *)
            log_error "Invalid command: $COMMAND"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
