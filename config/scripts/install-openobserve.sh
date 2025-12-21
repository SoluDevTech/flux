#!/bin/bash
#
# OpenObserve Installation Script
# This script installs OpenObserve with PostgreSQL metadata storage and MinIO object storage
#

set -e

# Configuration
NAMESPACE="soludev"
RELEASE_NAME="openobserve"
CHART_REPO="openobserve"
CHART_REPO_URL="https://charts.openobserve.ai"
CHART_NAME="openobserve/openobserve-standalone"
VALUES_FILE="./config/dev/openobserve/values.yml"

# MinIO Configuration
MINIO_RELEASE_NAME="minio"
MINIO_CHART_REPO="minio"
MINIO_CHART_REPO_URL="https://charts.min.io/"
MINIO_VALUES_FILE="./config/dev/minio/soludev/values.yaml"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Functions
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

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl is not installed"
        exit 1
    fi
    
    # Check helm
    if ! command -v helm &> /dev/null; then
        log_error "helm is not installed"
        exit 1
    fi
    
    # Check cluster connectivity
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi
    
    log_success "All prerequisites met"
}

deploy_minio() {
    log_info "Deploying MinIO..."
    
    # Add MinIO Helm repo
    if helm repo list 2>/dev/null | grep -q "$MINIO_CHART_REPO"; then
        log_info "MinIO Helm repository already exists"
    else
        log_info "Adding MinIO Helm repository..."
        helm repo add "$MINIO_CHART_REPO" "$MINIO_CHART_REPO_URL"
    fi
    helm repo update
    
    # Apply MinIO PersistentVolume
    log_info "Applying MinIO PersistentVolume..."
    kubectl apply -f dev/soludev/minio/persistent-volume.yaml
    
    # Apply MinIO PersistentVolumeClaim
    log_info "Applying MinIO PersistentVolumeClaim..."
    kubectl apply -f dev/soludev/minio/volume-claim.yaml
    
    # Check if values file exists
    if [ ! -f "$MINIO_VALUES_FILE" ]; then
        log_error "MinIO values file not found: $MINIO_VALUES_FILE"
        exit 1
    fi
    
    # Install MinIO
    log_info "Installing MinIO with Helm..."
    helm upgrade --install "$MINIO_RELEASE_NAME" minio/minio \
        --namespace "$NAMESPACE" \
        -f "$MINIO_VALUES_FILE" \
        --wait \
        --timeout 5m
    
    log_success "MinIO deployed successfully"
    
    # Wait for MinIO to be ready
    log_info "Waiting for MinIO pod to be ready..."
    kubectl wait --for=condition=ready pod \
        -l app=minio \
        -n "$NAMESPACE" \
        --timeout=120s || {
        log_error "MinIO pod did not become ready in time"
        kubectl get pods -n "$NAMESPACE" -l app=minio
        exit 1
    }
    
    log_success "MinIO is running"
}

check_dependencies() {
    log_info "Checking dependencies..."
    
    # Check if namespace exists
    if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
        log_warning "Namespace $NAMESPACE does not exist. Creating..."
        kubectl create namespace "$NAMESPACE"
    fi
    
    # Check PostgreSQL
    if ! kubectl get svc -n "$NAMESPACE" postgres &> /dev/null; then
        log_error "PostgreSQL service not found in namespace $NAMESPACE"
        log_error "Please ensure PostgreSQL is installed and the 'openobserve' database is created"
        exit 1
    fi
    log_success "PostgreSQL service found"
    
    # Check MinIO - deploy if not found
    if ! kubectl get svc -n "$NAMESPACE" minio &> /dev/null; then
        log_warning "MinIO service not found in namespace $NAMESPACE"
        deploy_minio
    else
        log_success "MinIO service found"
    fi
    
    # Check External Secret
    if ! kubectl get externalsecret -n "$NAMESPACE" soludev-openobserve-external-secret &> /dev/null; then
        log_warning "ExternalSecret not found. Applying..."
        kubectl apply -f dev/soludev/openobserve/external-secret.yaml
        log_info "Waiting for secret to sync (60s)..."
        sleep 10
    fi
    
    # Verify secret exists
    if ! kubectl get secret -n "$NAMESPACE" soludev-openobserve-secret &> /dev/null; then
        log_error "Secret 'soludev-openobserve-secret' not found"
        log_error "Please ensure OpenBao has the secret at 'soludev/openobserve' with keys:"
        log_error "  - ZO_ROOT_USER_EMAIL"
        log_error "  - ZO_ROOT_USER_PASSWORD"
        log_error "  - MINIO_ACCESS        (use: minioadmin or dedicated key)"
        log_error "  - MINIO_SECRET        (use: minioadmin or dedicated key)"
        log_error "  - ZO_META_POSTGRES_DSN (format: postgresql://user:pass@postgres:5432/openobserve)"
        exit 1
    fi
    log_success "OpenObserve secret found"
    
    # Verify secret keys
    log_info "Verifying secret keys..."
    REQUIRED_KEYS=("ZO_ROOT_USER_EMAIL" "ZO_ROOT_USER_PASSWORD" "MINIO_ACCESS" "MINIO_SECRET" "ZO_META_POSTGRES_DSN")
    for key in "${REQUIRED_KEYS[@]}"; do
        VALUE=$(kubectl get secret -n "$NAMESPACE" soludev-openobserve-secret -o jsonpath="{.data.$key}" 2>/dev/null)
        if [ -z "$VALUE" ]; then
            log_error "Missing key '$key' in secret"
            exit 1
        fi
    done
    log_success "All secret keys present"
}

setup_persistent_volume() {
    log_info "Setting up PersistentVolume for OpenObserve cache..."
    
    if kubectl get pv nfs-soludev-openobserve &> /dev/null; then
        log_info "PersistentVolume already exists"
    else
        kubectl apply -f dev/soludev/openobserve/persistent-volume.yaml
        log_success "PersistentVolume created"
    fi
}

add_helm_repo() {
    log_info "Adding OpenObserve Helm repository..."
    
    if helm repo list 2>/dev/null | grep -q "$CHART_REPO"; then
        log_info "Repository already exists, updating..."
    else
        helm repo add "$CHART_REPO" "$CHART_REPO_URL"
    fi
    helm repo update
    
    log_success "Helm repository ready"
}

install_openobserve() {
    log_info "Installing/Upgrading OpenObserve..."
    
    # Check if values file exists
    if [ ! -f "$VALUES_FILE" ]; then
        log_error "Values file not found: $VALUES_FILE"
        exit 1
    fi
    
    # Install or upgrade
    helm upgrade --install "$RELEASE_NAME" "$CHART_NAME" \
        --namespace "$NAMESPACE" \
        -f "$VALUES_FILE" \
        --wait \
        --timeout 5m
    
    log_success "OpenObserve installed successfully"
}

apply_ingress() {
    log_info "Applying Ingress configuration..."
    
    kubectl apply -f dev/soludev/openobserve/ingress.yaml
    
    log_success "Ingress configured"
}

verify_installation() {
    log_info "Verifying installation..."
    
    # Wait for pod to be ready
    log_info "Waiting for OpenObserve pod to be ready..."
    kubectl wait --for=condition=ready pod \
        -l app.kubernetes.io/name=openobserve \
        -n "$NAMESPACE" \
        --timeout=300s || {
        log_error "Pod did not become ready in time"
        log_info "Checking pod status..."
        kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=openobserve
        kubectl describe pod -n "$NAMESPACE" -l app.kubernetes.io/name=openobserve | tail -30
        exit 1
    }
    
    log_success "OpenObserve is running"
    
    # Display access information
    echo ""
    log_info "=========================================="
    log_info "OpenObserve Installation Complete!"
    log_info "=========================================="
    echo ""
    log_info "Access Information:"
    echo ""
    log_info "  Port Forward (development):"
    echo "    kubectl port-forward -n $NAMESPACE svc/openobserve-openobserve-standalone 5080:5080"
    echo "    Then access: http://localhost:5080"
    echo ""
    log_info "  Ingress (production):"
    INGRESS_HOST=$(kubectl get ingress -n "$NAMESPACE" openobserve-ingress -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo "Not configured")
    echo "    URL: https://$INGRESS_HOST"
    echo ""
    log_info "  Login Credentials:"
    echo "    Email: $(kubectl get secret -n $NAMESPACE soludev-openobserve-secret -o jsonpath='{.data.ZO_ROOT_USER_EMAIL}' | base64 -d)"
    echo "    Password: (run this command)"
    echo "    kubectl get secret -n $NAMESPACE soludev-openobserve-secret -o jsonpath='{.data.ZO_ROOT_USER_PASSWORD}' | base64 -d && echo"
    echo ""
    log_info "  MinIO Storage:"
    echo "    Endpoint: http://minio.$NAMESPACE.svc.cluster.local:9000"
    echo "    Bucket: observability"
    echo ""
}

show_help() {
    echo "OpenObserve Installation Script"
    echo ""
    echo "Usage: $0 [OPTION]"
    echo ""
    echo "Options:"
    echo "  install     Install OpenObserve (default) - also deploys MinIO if not present"
    echo "  upgrade     Upgrade existing OpenObserve installation"
    echo "  uninstall   Uninstall OpenObserve"
    echo "  status      Show status of OpenObserve installation"
    echo "  logs        Show OpenObserve logs"
    echo "  help        Show this help message"
    echo ""
    echo "Prerequisites:"
    echo "  1. PostgreSQL running in $NAMESPACE with 'openobserve' database"
    echo "  2. OpenBao secret at 'soludev/openobserve' with:"
    echo "     - ZO_ROOT_USER_EMAIL"
    echo "     - ZO_ROOT_USER_PASSWORD"
    echo "     - MINIO_ACCESS (minioadmin or custom)"
    echo "     - MINIO_SECRET (minioadmin or custom)"
    echo "     - ZO_META_POSTGRES_DSN"
    echo ""
    echo "Note: MinIO will be automatically deployed if not present."
    echo ""
}

show_status() {
    log_info "OpenObserve Status:"
    echo ""
    
    echo "=== Pods ==="
    kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=openobserve -o wide
    echo ""
    
    echo "=== MinIO Pods ==="
    kubectl get pods -n "$NAMESPACE" -l app=minio -o wide 2>/dev/null || echo "MinIO not found"
    echo ""
    
    echo "=== Services ==="
    kubectl get svc -n "$NAMESPACE" | grep -E "openobserve|minio|postgres" || true
    echo ""
    
    echo "=== PVC ==="
    kubectl get pvc -n "$NAMESPACE" | grep -E "openobserve|minio" || true
    echo ""
    
    echo "=== Ingress ==="
    kubectl get ingress -n "$NAMESPACE" | grep openobserve || true
    echo ""
    
    echo "=== External Secrets ==="
    kubectl get externalsecret -n "$NAMESPACE" | grep openobserve || true
    echo ""
}

show_logs() {
    log_info "OpenObserve Logs (following):"
    kubectl logs -n "$NAMESPACE" -l app.kubernetes.io/name=openobserve --tail=100 -f
}

uninstall_openobserve() {
    log_warning "This will uninstall OpenObserve. Data in MinIO and PostgreSQL will be preserved."
    read -p "Are you sure? (y/N) " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "Uninstalling OpenObserve..."
        helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" 2>/dev/null || true
        
        log_info "Removing Ingress..."
        kubectl delete -f dev/soludev/openobserve/ingress.yaml 2>/dev/null || true
        
        log_success "OpenObserve uninstalled"
        log_info "Note: PersistentVolume, MinIO data, and PostgreSQL data were preserved"
        log_info "To also uninstall MinIO, run: helm uninstall minio -n $NAMESPACE"
    else
        log_info "Uninstall cancelled"
    fi
}

# Main
case "${1:-install}" in
    install)
        check_prerequisites
        check_dependencies
        setup_persistent_volume
        add_helm_repo
        install_openobserve
        apply_ingress
        verify_installation
        ;;
    upgrade)
        check_prerequisites
        check_dependencies
        add_helm_repo
        install_openobserve
        verify_installation
        ;;
    uninstall)
        uninstall_openobserve
        ;;
    status)
        show_status
        ;;
    logs)
        show_logs
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        log_error "Unknown option: $1"
        show_help
        exit 1
        ;;
esac
