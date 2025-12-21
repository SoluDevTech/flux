#!/bin/bash
#
# Flux Installation Script for K3s
# Installs Flux CD and applies kube-flannel, GitRepository, and Kustomization resources
#
# Usage: ./install-flux.sh <COMMAND> [OPTIONS]
#

set -e

# =============================================================================
# DEFAULT CONFIGURATION
# =============================================================================

FLUX_NAMESPACE="flux-system"
GIT_REPO_URL="https://github.com/Kaiohz/flux.git"
GIT_BRANCH="main"
CONFIG_DIR="config/dev"
NAMESPACES="soludev,prospectio,pickpro"
SKIP_FLANNEL=false
SKIP_GITREPO=false
SKIP_KUSTOMIZATION=false
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
Flux Installation Script for K3s

Usage: ./install-flux.sh <COMMAND> [OPTIONS]

Commands:
  install                     Install Flux and related resources
  uninstall                   Uninstall Flux and related resources

Options (install):
  -u, --git-url URL           Git repository URL (default: https://github.com/Kaiohz/flux.git)
  -b, --branch NAME           Git branch (default: main)
  -c, --config-dir DIR        Config directory path (default: config/dev)
  -n, --namespaces LIST       Comma-separated list of namespaces to create (default: soludev,prospectio,pickpro)
      --skip-flannel          Skip kube-flannel installation
      --skip-gitrepo          Skip GitRepository creation
      --skip-kustomization    Skip Kustomization creation

Options (uninstall):
      --purge                 Also delete Flux system and kube-flannel

Common Options:
  -v, --verbose               Enable verbose output
  -h, --help                  Show this help message

Examples:
  ./install-flux.sh install
  ./install-flux.sh install -n soludev,prospectio,pickpro
  ./install-flux.sh install -n myapp,staging
  ./install-flux.sh install -u https://github.com/myorg/myrepo.git -b develop
  ./install-flux.sh install --skip-flannel
  ./install-flux.sh uninstall
  ./install-flux.sh uninstall --purge

EOF
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        log_error "$1 is not installed or not in PATH"
        exit 1
    fi
    log_verbose "$1 is available"
}

wait_for_flux() {
    local timeout=${1:-300}
    local interval=10
    local elapsed=0

    log_info "Waiting for Flux controllers to be ready..."

    while [[ $elapsed -lt $timeout ]]; do
        local ready_count
        ready_count=$(kubectl get deployments -n "$FLUX_NAMESPACE" -o jsonpath='{.items[*].status.readyReplicas}' 2>/dev/null | wc -w || echo "0")
        local total_count
        total_count=$(kubectl get deployments -n "$FLUX_NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w || echo "0")

        if [[ "$ready_count" -ge 4 && "$total_count" -ge 4 ]]; then
            log_success "Flux controllers are ready ($ready_count/$total_count)"
            return 0
        fi

        log_verbose "Flux controllers: $ready_count/$total_count ready, waiting..."
        sleep $interval
        elapsed=$((elapsed + interval))
    done

    log_warning "Timeout waiting for all Flux controllers, continuing anyway..."
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
            -u|--git-url)
                GIT_REPO_URL="$2"
                shift 2
                ;;
            -b|--branch)
                GIT_BRANCH="$2"
                shift 2
                ;;
            -c|--config-dir)
                CONFIG_DIR="$2"
                shift 2
                ;;
            -n|--namespaces)
                NAMESPACES="$2"
                shift 2
                ;;
            --skip-flannel)
                SKIP_FLANNEL=true
                shift
                ;;
            --skip-gitrepo)
                SKIP_GITREPO=true
                shift
                ;;
            --skip-kustomization)
                SKIP_KUSTOMIZATION=true
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

uninstall_flux() {
    echo ""
    echo "============================================"
    echo "    Flux Uninstallation                     "
    echo "============================================"
    echo ""

    log_info "Starting Flux uninstallation..."

    # Confirmation prompt
    echo -e "${YELLOW}This will remove:${NC}"
    echo "  - Flux Kustomizations (soludev, prospectio, pickpro)"
    echo "  - GitRepository: kaiohz-repo"
    if [[ "$PURGE" == true ]]; then
        echo "  - Flux system (flux-system namespace)"
        echo "  - kube-flannel namespace and resources"
    fi
    echo ""

    read -p "Are you sure you want to continue? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Uninstallation cancelled"
        exit 0
    fi

    # 1. Delete Kustomizations
    for ks in soludev-kustomization prospectio-kustomization pickpro-kustomization; do
        if kubectl get kustomization "$ks" -n "$FLUX_NAMESPACE" &> /dev/null; then
            log_info "Deleting Kustomization: $ks..."
            kubectl delete kustomization "$ks" -n "$FLUX_NAMESPACE"
            log_success "Kustomization $ks deleted"
        else
            log_verbose "Kustomization $ks not found"
        fi
    done

    # 2. Delete GitRepository
    if kubectl get gitrepository kaiohz-repo -n "$FLUX_NAMESPACE" &> /dev/null; then
        log_info "Deleting GitRepository: kaiohz-repo..."
        kubectl delete gitrepository kaiohz-repo -n "$FLUX_NAMESPACE"
        log_success "GitRepository kaiohz-repo deleted"
    else
        log_verbose "GitRepository kaiohz-repo not found"
    fi

    # 3. Purge: Uninstall Flux and flannel
    if [[ "$PURGE" == true ]]; then
        # Uninstall Flux
        if kubectl get namespace "$FLUX_NAMESPACE" &> /dev/null; then
            log_info "Uninstalling Flux..."
            flux uninstall --silent 2>/dev/null || {
                log_warning "flux uninstall failed, deleting namespace directly..."
                kubectl delete namespace "$FLUX_NAMESPACE" --timeout=60s 2>/dev/null || true
            }
            log_success "Flux uninstalled"
        else
            log_verbose "Flux namespace not found"
        fi

        # Delete kube-flannel
        if kubectl get namespace kube-flannel &> /dev/null; then
            log_info "Deleting kube-flannel..."
            kubectl delete namespace kube-flannel --timeout=60s 2>/dev/null || true
            log_success "kube-flannel deleted"
        else
            log_verbose "kube-flannel namespace not found"
        fi

        # Delete flannel ClusterRole and ClusterRoleBinding
        kubectl delete clusterrolebinding flannel 2>/dev/null || true
        kubectl delete clusterrole flannel 2>/dev/null || true
        log_verbose "Flannel cluster resources cleaned up"
    fi

    echo ""
    echo "============================================"
    echo -e "${GREEN}Flux Uninstallation Complete${NC}"
    echo "============================================"
    echo ""

    if [[ "$PURGE" == false ]]; then
        log_info "Note: Flux system was preserved."
        log_info "Use --purge to also delete Flux and kube-flannel."
    fi

    log_success "Flux uninstallation completed successfully!"
}

# =============================================================================
# PHASE 1: PREREQUISITES CHECK
# =============================================================================

check_prerequisites() {
    log_info "Checking prerequisites..."

    check_command "kubectl"
    check_command "flux"

    # Check kubectl connection
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster. Check your kubeconfig."
        exit 1
    fi
    log_success "Connected to Kubernetes cluster"

    # Check Flux CLI version
    local flux_version
    flux_version=$(flux version --client 2>/dev/null | head -1 || echo "unknown")
    log_verbose "Flux CLI version: $flux_version"

    # Check config directory
    if [[ ! -d "$CONFIG_DIR" ]]; then
        log_error "Config directory not found: $CONFIG_DIR"
        exit 1
    fi
    log_verbose "Config directory: $CONFIG_DIR"

    log_success "Prerequisites check passed"
}

# =============================================================================
# PHASE 2: INSTALL FLUX
# =============================================================================

install_flux() {
    log_info "Installing Flux CD..."

    # Check if Flux is already installed
    if kubectl get namespace "$FLUX_NAMESPACE" &> /dev/null; then
        local flux_ready
        flux_ready=$(kubectl get deployments -n "$FLUX_NAMESPACE" -o jsonpath='{.items[*].status.readyReplicas}' 2>/dev/null | wc -w || echo "0")
        
        if [[ "$flux_ready" -ge 4 ]]; then
            log_warning "Flux is already installed and running"
            return 0
        fi
    fi

    # Install Flux
    log_info "Running flux install..."
    flux install --namespace="$FLUX_NAMESPACE"

    # Wait for Flux to be ready
    wait_for_flux 300

    log_success "Flux CD installed successfully"
}

# =============================================================================
# PHASE 3: INSTALL KUBE-FLANNEL
# =============================================================================

install_flannel() {
    if [[ "$SKIP_FLANNEL" == true ]]; then
        log_info "Skipping kube-flannel installation (--skip-flannel)"
        return 0
    fi

    local flannel_file="$CONFIG_DIR/kube-flannel.yml"

    if [[ ! -f "$flannel_file" ]]; then
        log_warning "kube-flannel.yml not found at $flannel_file, skipping..."
        return 0
    fi

    log_info "Installing kube-flannel..."

    # Check if flannel is already installed
    if kubectl get namespace kube-flannel &> /dev/null; then
        log_warning "kube-flannel namespace already exists, applying updates..."
    fi

    # Apply flannel configuration
    kubectl apply -f "$flannel_file"

    # Wait for flannel daemonset
    log_info "Waiting for kube-flannel daemonset..."
    sleep 5
    
    if kubectl rollout status daemonset/kube-flannel-ds -n kube-flannel --timeout=120s 2>/dev/null; then
        log_success "kube-flannel installed successfully"
    else
        log_warning "kube-flannel may still be starting up"
    fi
}

# =============================================================================
# PHASE 4: CREATE GITREPOSITORY
# =============================================================================

create_gitrepository() {
    if [[ "$SKIP_GITREPO" == true ]]; then
        log_info "Skipping GitRepository creation (--skip-gitrepo)"
        return 0
    fi

    local gitrepo_file="$CONFIG_DIR/gitrepository.yaml"

    log_info "Creating GitRepository resource..."

    # Check if GitRepository already exists
    if kubectl get gitrepository kaiohz-repo -n "$FLUX_NAMESPACE" &> /dev/null; then
        log_warning "GitRepository kaiohz-repo already exists, updating..."
    fi

    if [[ -f "$gitrepo_file" ]]; then
        # Use existing file
        kubectl apply -f "$gitrepo_file"
        log_success "GitRepository applied from $gitrepo_file"
    else
        # Create inline
        log_info "Creating GitRepository inline (file not found: $gitrepo_file)..."
        cat <<EOF | kubectl apply -f -
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: kaiohz-repo
  namespace: $FLUX_NAMESPACE
spec:
  interval: 1m
  url: $GIT_REPO_URL
  ref:
    branch: $GIT_BRANCH
EOF
        log_success "GitRepository created inline"
    fi

    # Wait for GitRepository to be ready
    log_info "Waiting for GitRepository to sync..."
    sleep 5

    local retries=30
    while [[ $retries -gt 0 ]]; do
        local ready
        ready=$(kubectl get gitrepository kaiohz-repo -n "$FLUX_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
        
        if [[ "$ready" == "True" ]]; then
            log_success "GitRepository is ready and synced"
            return 0
        fi

        log_verbose "GitRepository not ready yet, waiting... ($retries retries left)"
        sleep 5
        retries=$((retries - 1))
    done

    log_warning "GitRepository may still be syncing"
}

# =============================================================================
# PHASE 5: CREATE KUSTOMIZATIONS
# =============================================================================

create_kustomizations() {
    if [[ "$SKIP_KUSTOMIZATION" == true ]]; then
        log_info "Skipping Kustomization creation (--skip-kustomization)"
        return 0
    fi

    local kustomization_file="$CONFIG_DIR/kustomization.yaml"

    log_info "Creating Kustomization resources..."

    # Create target namespaces if they don't exist
    log_info "Creating namespaces: $NAMESPACES"
    IFS=',' read -ra NS_ARRAY <<< "$NAMESPACES"
    for ns in "${NS_ARRAY[@]}"; do
        # Trim whitespace
        ns=$(echo "$ns" | xargs)
        if [[ -z "$ns" ]]; then
            continue
        fi
        if ! kubectl get namespace "$ns" &> /dev/null; then
            kubectl create namespace "$ns"
            log_success "Created namespace: $ns"
        else
            log_verbose "Namespace $ns already exists"
        fi
    done

    if [[ -f "$kustomization_file" ]]; then
        # Use existing file
        kubectl apply -f "$kustomization_file"
        log_success "Kustomizations applied from $kustomization_file"
    else
        log_warning "Kustomization file not found: $kustomization_file"
        log_info "Creating default Kustomizations inline..."

        # Create soludev kustomization
        cat <<EOF | kubectl apply -f -
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: soludev-kustomization
  namespace: $FLUX_NAMESPACE
spec:
  interval: 2m
  timeout: 90s
  wait: true
  targetNamespace: soludev
  sourceRef:
    kind: GitRepository
    name: kaiohz-repo
  path: "dev/soludev"
  prune: true
EOF
        log_success "Created soludev-kustomization"
    fi

    # Wait for Kustomizations to reconcile
    log_info "Waiting for Kustomizations to reconcile..."
    sleep 10

    for ks in soludev-kustomization prospectio-kustomization pickpro-kustomization; do
        local ready
        ready=$(kubectl get kustomization "$ks" -n "$FLUX_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "NotFound")
        
        if [[ "$ready" == "True" ]]; then
            log_success "Kustomization $ks is ready"
        elif [[ "$ready" == "NotFound" ]]; then
            log_verbose "Kustomization $ks not found (may not be in config file)"
        else
            log_warning "Kustomization $ks is not ready yet (status: $ready)"
        fi
    done
}

# =============================================================================
# SUMMARY
# =============================================================================

print_summary() {
    echo ""
    echo "============================================"
    echo -e "${GREEN}Flux Installation Summary${NC}"
    echo "============================================"
    echo ""
    echo "Flux Namespace:    $FLUX_NAMESPACE"
    echo "Git Repository:    $GIT_REPO_URL"
    echo "Git Branch:        $GIT_BRANCH"
    echo "Config Directory:  $CONFIG_DIR"
    echo "Namespaces:        $NAMESPACES"
    echo ""

    echo "Installed Components:"
    if [[ "$SKIP_FLANNEL" == false ]]; then
        echo "  - kube-flannel (CNI)"
    fi
    echo "  - Flux CD controllers"
    if [[ "$SKIP_GITREPO" == false ]]; then
        echo "  - GitRepository: kaiohz-repo"
    fi
    if [[ "$SKIP_KUSTOMIZATION" == false ]]; then
        echo "  - Kustomizations: soludev, prospectio, pickpro"
    fi
    echo ""

    echo "Useful commands:"
    echo "  # Check Flux status"
    echo "  flux check"
    echo ""
    echo "  # View GitRepositories"
    echo "  flux get sources git"
    echo ""
    echo "  # View Kustomizations"
    echo "  flux get kustomizations"
    echo ""
    echo "  # Reconcile manually"
    echo "  flux reconcile source git kaiohz-repo"
    echo "  flux reconcile kustomization soludev-kustomization"
    echo ""
    echo "  # View Flux logs"
    echo "  flux logs --all-namespaces"
    echo ""
    echo "============================================"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    parse_args "$@"

    # Check basic prerequisites
    check_command "kubectl"
    check_command "flux"
    
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster. Check your kubeconfig."
        exit 1
    fi

    # Execute command
    case $COMMAND in
        install)
            echo ""
            echo "============================================"
            echo "    Flux Installation Script for K3s       "
            echo "============================================"
            echo ""

            check_prerequisites
            install_flannel
            install_flux
            create_gitrepository
            create_kustomizations

    print_summary

    log_success "Flux installation completed successfully!"
            ;;
        uninstall)
            uninstall_flux
            ;;
        *)
            log_error "Invalid command: $COMMAND"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
