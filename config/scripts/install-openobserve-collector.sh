#!/bin/bash
#
# OpenObserve Collector Installation Script
# This script installs the OpenObserve Collector with all required dependencies:
# - cert-manager
# - Prometheus operator CRDs
# - OpenTelemetry operator
#

set -e

# Configuration
NAMESPACE="openobserve-collector"
CLUSTER_NAME="cluster1"
OPENOBSERVE_ENDPOINT="https://openobserve.soludev.tech/api/default"

# Versions
CERT_MANAGER_VERSION="v1.19.0"

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

install_cert_manager() {
    log_info "Installing cert-manager ${CERT_MANAGER_VERSION}..."
    
    # Check if cert-manager is already installed
    if kubectl get namespace cert-manager &> /dev/null; then
        log_info "cert-manager namespace exists, checking if ready..."
        if kubectl get deployment -n cert-manager cert-manager-webhook &> /dev/null; then
            log_success "cert-manager already installed"
            return 0
        fi
    fi
    
    kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
    
    log_info "Waiting for cert-manager webhook to be ready (this may take up to 2 minutes)..."
    kubectl wait --for=condition=Available deployment/cert-manager-webhook \
        -n cert-manager \
        --timeout=180s || {
        log_warning "Webhook not ready yet, waiting additional time..."
        sleep 60
    }
    
    # Additional wait to ensure webhook is fully ready
    log_info "Waiting additional 30 seconds for webhook to stabilize..."
    sleep 30
    
    log_success "cert-manager installed successfully"
}

setup_helm_repo() {
    log_info "Setting up Helm repositories..."
    
    if helm repo list 2>/dev/null | grep -q "openobserve"; then
        log_info "OpenObserve Helm repository already exists"
    else
        log_info "Adding OpenObserve Helm repository..."
        helm repo add openobserve https://charts.openobserve.ai
    fi
    
    helm repo update
    
    log_success "Helm repositories ready"
}

install_prometheus_crds() {
    log_info "Installing Prometheus operator CRDs..."
    
    PROMETHEUS_CRD_BASE="https://raw.githubusercontent.com/prometheus-operator/prometheus-operator"
    
    # ServiceMonitors
    if kubectl get crd servicemonitors.monitoring.coreos.com &> /dev/null; then
        log_info "ServiceMonitor CRD already exists"
    else
        log_info "Creating ServiceMonitor CRD..."
        kubectl create -f "${PROMETHEUS_CRD_BASE}/main/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml" || true
    fi
    
    # PodMonitors
    if kubectl get crd podmonitors.monitoring.coreos.com &> /dev/null; then
        log_info "PodMonitor CRD already exists"
    else
        log_info "Creating PodMonitor CRD..."
        kubectl create -f "${PROMETHEUS_CRD_BASE}/main/example/prometheus-operator-crd/monitoring.coreos.com_podmonitors.yaml" || true
    fi
    
    # ScrapeConfigs
    if kubectl get crd scrapeconfigs.monitoring.coreos.com &> /dev/null; then
        log_info "ScrapeConfig CRD already exists"
    else
        log_info "Creating ScrapeConfig CRD..."
        kubectl create -f "${PROMETHEUS_CRD_BASE}/refs/heads/main/example/prometheus-operator-crd/monitoring.coreos.com_scrapeconfigs.yaml" || true
    fi
    
    # Probes
    if kubectl get crd probes.monitoring.coreos.com &> /dev/null; then
        log_info "Probe CRD already exists"
    else
        log_info "Creating Probe CRD..."
        kubectl create -f "${PROMETHEUS_CRD_BASE}/refs/heads/main/example/prometheus-operator-crd/monitoring.coreos.com_probes.yaml" || true
    fi
    
    log_success "Prometheus CRDs installed"
}

install_opentelemetry_operator() {
    log_info "Installing OpenTelemetry operator..."
    
    # Check if operator already exists
    if kubectl get deployment -n opentelemetry-operator-system opentelemetry-operator-controller-manager &> /dev/null; then
        log_info "OpenTelemetry operator already installed"
        return 0
    fi
    
    kubectl apply -f https://raw.githubusercontent.com/openobserve/openobserve-helm-chart/refs/heads/main/opentelemetry-operator.yaml
    
    log_info "Waiting for OpenTelemetry operator to be ready..."
    sleep 10
    kubectl wait --for=condition=Available deployment/opentelemetry-operator-controller-manager \
        -n opentelemetry-operator-system \
        --timeout=120s || {
        log_warning "Operator may still be starting..."
    }
    
    log_success "OpenTelemetry operator installed"
}

create_namespace() {
    log_info "Creating namespace ${NAMESPACE}..."
    
    if kubectl get namespace "$NAMESPACE" &> /dev/null; then
        log_info "Namespace ${NAMESPACE} already exists"
    else
        kubectl create ns "$NAMESPACE"
        log_success "Namespace created"
    fi
}

install_collector() {
    local auth_token="$1"
    
    log_info "Installing OpenObserve Collector..."
    
    helm --namespace "$NAMESPACE" \
        upgrade --install o2c openobserve/openobserve-collector \
        --set k8sCluster="$CLUSTER_NAME" \
        --set exporters.'otlphttp/openobserve'.endpoint="$OPENOBSERVE_ENDPOINT" \
        --set exporters.'otlphttp/openobserve'.headers.Authorization="$auth_token" \
        --set exporters.'otlphttp/openobserve_k8s_events'.endpoint="$OPENOBSERVE_ENDPOINT" \
        --set exporters.'otlphttp/openobserve_k8s_events'.headers.Authorization="$auth_token" \
        --set agent.service.pipelines.logs.exporters='{otlphttp/openobserve}' \
        --set agent.service.pipelines.metrics.exporters='{otlphttp/openobserve}' \
        --set gateway.service.pipelines.logs/k8s_events.exporters='{otlphttp/openobserve_k8s_events}' \
        --set gateway.service.pipelines.logs/k8s_pods.exporters='{otlphttp/openobserve}' \
        --set gateway.service.pipelines.metrics.exporters='{otlphttp/openobserve}' \
        --set gateway.service.pipelines.traces.exporters='{servicegraph,otlphttp/openobserve}' \
        --wait \
        --timeout 5m
    
    log_success "OpenObserve Collector installed"
}

verify_installation() {
    log_info "Verifying installation..."
    
    echo ""
    echo "=== cert-manager ==="
    kubectl get pods -n cert-manager
    
    echo ""
    echo "=== OpenTelemetry Operator ==="
    kubectl get pods -n opentelemetry-operator-system 2>/dev/null || echo "Namespace not found"
    
    echo ""
    echo "=== OpenObserve Collector ==="
    kubectl get pods -n "$NAMESPACE"
    
    echo ""
    log_info "=========================================="
    log_info "OpenObserve Collector Installation Complete!"
    log_info "=========================================="
    echo ""
    log_info "Configuration:"
    echo "  Cluster Name: $CLUSTER_NAME"
    echo "  Namespace: $NAMESPACE"
    echo "  OpenObserve Endpoint: $OPENOBSERVE_ENDPOINT"
    echo ""
    log_info "The collector is now sending:"
    echo "  - Logs from all pods"
    echo "  - Kubernetes events"
    echo "  - Metrics from nodes and pods"
    echo "  - Traces (if instrumented)"
    echo ""
}

show_status() {
    log_info "OpenObserve Collector Status:"
    echo ""
    
    echo "=== cert-manager ==="
    kubectl get pods -n cert-manager 2>/dev/null || echo "Not installed"
    echo ""
    
    echo "=== Prometheus CRDs ==="
    kubectl get crd | grep monitoring.coreos.com || echo "Not installed"
    echo ""
    
    echo "=== OpenTelemetry Operator ==="
    kubectl get pods -n opentelemetry-operator-system 2>/dev/null || echo "Not installed"
    echo ""
    
    echo "=== OpenObserve Collector ==="
    kubectl get pods -n "$NAMESPACE" 2>/dev/null || echo "Not installed"
    echo ""
    
    echo "=== Collector DaemonSet/Deployment ==="
    kubectl get daemonset,deployment -n "$NAMESPACE" 2>/dev/null || true
    echo ""
}

show_logs() {
    log_info "OpenObserve Collector Logs:"
    kubectl logs -n "$NAMESPACE" -l app.kubernetes.io/name=openobserve-collector --tail=100 -f 2>/dev/null || \
    kubectl logs -n "$NAMESPACE" -l app=o2c-agent --tail=100 -f
}

uninstall() {
    log_warning "This will uninstall the OpenObserve Collector and all dependencies."
    read -p "Are you sure? (y/N) " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "Uninstalling OpenObserve Collector..."
        helm uninstall o2c -n "$NAMESPACE" 2>/dev/null || true
        
        log_info "Deleting namespace..."
        kubectl delete ns "$NAMESPACE" 2>/dev/null || true
        
        read -p "Also uninstall OpenTelemetry operator? (y/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            kubectl delete -f https://raw.githubusercontent.com/openobserve/openobserve-helm-chart/refs/heads/main/opentelemetry-operator.yaml 2>/dev/null || true
        fi
        
        read -p "Also uninstall cert-manager? (y/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            kubectl delete -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml" 2>/dev/null || true
        fi
        
        log_success "Uninstall complete"
    else
        log_info "Uninstall cancelled"
    fi
}

show_help() {
    echo "OpenObserve Collector Installation Script"
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  install <auth_token>   Install everything (requires auth token)"
    echo "  upgrade <auth_token>   Upgrade the collector (requires auth token)"
    echo "  uninstall              Uninstall the collector and optionally dependencies"
    echo "  status                 Show status of all components"
    echo "  logs                   Show collector logs"
    echo "  help                   Show this help message"
    echo ""
    echo "Arguments:"
    echo "  auth_token    OpenObserve Basic auth token (e.g., 'Basic xxxx...')"
    echo ""
    echo "Examples:"
    echo "  $0 install 'Basic eW91ci10b2tlbi1oZXJl'"
    echo "  $0 status"
    echo "  $0 logs"
    echo ""
    echo "Components installed:"
    echo "  1. cert-manager ${CERT_MANAGER_VERSION}"
    echo "  2. Prometheus operator CRDs"
    echo "  3. OpenTelemetry operator"
    echo "  4. OpenObserve Collector"
    echo ""
}

# Main
COMMAND="${1:-help}"

case "$COMMAND" in
    install)
        if [ -z "$2" ]; then
            log_error "Missing required argument: auth_token"
            echo ""
            echo "Usage: $0 install <auth_token>"
            echo "Example: $0 install 'Basic eW91ci10b2tlbi1oZXJl'"
            exit 1
        fi
        check_prerequisites
        install_cert_manager
        setup_helm_repo
        install_prometheus_crds
        install_opentelemetry_operator
        create_namespace
        install_collector "$2"
        verify_installation
        ;;
    upgrade)
        if [ -z "$2" ]; then
            log_error "Missing required argument: auth_token"
            echo ""
            echo "Usage: $0 upgrade <auth_token>"
            exit 1
        fi
        check_prerequisites
        setup_helm_repo
        install_collector "$2"
        verify_installation
        ;;
    uninstall)
        uninstall
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
        log_error "Unknown command: $COMMAND"
        show_help
        exit 1
        ;;
esac
