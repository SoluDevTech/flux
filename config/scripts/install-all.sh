#!/bin/bash
#
# Complete Cluster Installation Script
# Orchestrates the installation of all components:
# - K3s cluster
# - Flux CD
# - OpenBao (secrets management)
# - OpenObserve (observability platform)
# - OpenObserve Collector (metrics, logs, traces)
# - Phoenix (AI observability platform)
#
# Usage: ./install-all.sh [OPTIONS] [STEPS...]
#

set -e

# =============================================================================
# CONFIGURATION
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default values
INTERACTIVE=true
SKIP_CONFIRMATION=false
VERBOSE=false
DRY_RUN=false

# K3s configuration
K3S_CONTROL_PLANE=""
K3S_WORKERS=()
K3S_CP_IP=""

# OpenObserve Collector configuration
OPENOBSERVE_AUTH=""

# OpenBao configuration
OPENBAO_VALUES_FILE="./config/dev/openbao/values.yaml"
OPENBAO_MANIFESTS_DIR="./dev/soludev/openbao"

# Steps to run (empty = all)
STEPS_TO_RUN=()

# Available steps in order
ALL_STEPS=("k3s" "flux" "openbao" "openobserve" "collector" "phoenix")

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
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

log_step() {
    echo ""
    echo -e "${CYAN}${BOLD}============================================${NC}"
    echo -e "${CYAN}${BOLD}  STEP: $1${NC}"
    echo -e "${CYAN}${BOLD}============================================${NC}"
    echo ""
}

log_verbose() {
    if [[ "$VERBOSE" == true ]]; then
        echo -e "${BLUE}[VERBOSE]${NC} $1"
    fi
}

show_help() {
    cat << EOF
Complete Cluster Installation Script

Orchestrates the installation of:
  1. K3s cluster (control plane + workers)
  2. Flux CD (GitOps)
  3. OpenBao (secrets management)
  4. OpenObserve (observability platform)
  5. OpenObserve Collector (metrics, logs, traces)
  6. Phoenix (AI observability platform)

Usage: $0 [OPTIONS] [STEPS...]

STEPS:
  k3s           Install K3s cluster
  flux          Install Flux CD
  openbao       Install OpenBao
  openobserve   Install OpenObserve
  collector     Install OpenObserve Collector
  phoenix       Install Phoenix AI Observability

  If no steps are specified, all steps are executed in order.

OPTIONS:
  K3s Options:
    -c, --control-plane USER:PASS@IP    K3s control plane SSH credentials
    -w, --worker USER:PASS@IP           K3s worker node (can be repeated)
    --cp-ip IP                          Control plane IP for cluster (Tailscale/Headscale)

  OpenBao Options:
    --openbao-values FILE               OpenBao Helm values file
    --openbao-manifests DIR             OpenBao manifests directory

  OpenObserve Collector Options:
    --openobserve-auth TOKEN            OpenObserve Basic auth token (required for collector)

  General Options:
    -y, --yes                           Skip confirmation prompts
    --dry-run                           Show what would be done without executing
    -v, --verbose                       Enable verbose output
    -h, --help                          Show this help message

EXAMPLES:
  # Install everything (interactive mode)
  $0

  # Install everything with K3s remote setup
  $0 -c pi:password@192.168.1.10 -w pi:password@192.168.1.11 --openobserve-auth 'Basic xxx'

  # Install only specific steps
  $0 flux openbao

  # Install collector with auth token
  $0 collector --openobserve-auth 'Basic eW91ci10b2tlbi1oZXJl'

  # Install everything non-interactively
  $0 -y --openobserve-auth 'Basic xxx'

  # Dry run to see what would happen
  $0 --dry-run

NOTES:
  - Steps are executed in dependency order regardless of argument order
  - K3s step is skipped if cluster is already accessible
  - OpenObserve Collector requires --openobserve-auth token

EOF
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        return 1
    fi
    return 0
}

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    local missing=()
    
    # Always needed
    check_command "kubectl" || missing+=("kubectl")
    check_command "helm" || missing+=("helm")
    
    # For Flux
    if should_run_step "flux"; then
        check_command "flux" || missing+=("flux")
    fi
    
    # For OpenBao
    if should_run_step "openbao"; then
        check_command "jq" || missing+=("jq")
    fi
    
    # For K3s remote installation
    if should_run_step "k3s" && [[ -n "$K3S_CONTROL_PLANE" ]]; then
        check_command "sshpass" || missing+=("sshpass")
    fi
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        log_info "Please install them before continuing."
        exit 1
    fi
    
    log_success "All prerequisites met"
}

cluster_accessible() {
    kubectl cluster-info &> /dev/null
}

should_run_step() {
    local step=$1
    
    # If no specific steps requested, run all
    if [[ ${#STEPS_TO_RUN[@]} -eq 0 ]]; then
        return 0
    fi
    
    # Check if step is in the list
    for s in "${STEPS_TO_RUN[@]}"; do
        if [[ "$s" == "$step" ]]; then
            return 0
        fi
    done
    
    return 1
}

confirm_step() {
    local step_name=$1
    
    if [[ "$SKIP_CONFIRMATION" == true ]]; then
        return 0
    fi
    
    echo ""
    read -p "$(echo -e "${YELLOW}Run step '$step_name'? (Y/n):${NC} ")" -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        return 1
    fi
    
    return 0
}

run_script() {
    local script=$1
    shift
    local args=("$@")
    
    local script_path="$SCRIPT_DIR/$script"
    
    if [[ ! -f "$script_path" ]]; then
        log_error "Script not found: $script_path"
        exit 1
    fi
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would run: $script_path ${args[*]}"
        return 0
    fi
    
    log_verbose "Running: $script_path ${args[*]}"
    bash "$script_path" "${args[@]}"
}

# =============================================================================
# STEP FUNCTIONS
# =============================================================================

step_k3s() {
    log_step "K3s Cluster Installation"
    
    # Check if cluster is already accessible
    if cluster_accessible; then
        log_warning "Kubernetes cluster is already accessible"
        log_info "Skipping K3s installation"
        
        # Show cluster info
        kubectl cluster-info
        echo ""
        kubectl get nodes
        return 0
    fi
    
    # Check if we have connection info
    if [[ -z "$K3S_CONTROL_PLANE" ]]; then
        if [[ "$INTERACTIVE" == true ]]; then
            echo ""
            log_info "No K3s control plane specified."
            log_info "For remote installation, provide: -c USER:PASS@IP"
            echo ""
            read -p "Install K3s locally? (y/N): " -n 1 -r
            echo
            
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log_warning "Skipping K3s installation"
                return 0
            fi
            
            # Local installation
            run_script "setup-k3s.sh" init
        else
            log_error "No K3s control plane specified and cluster not accessible"
            log_info "Use -c USER:PASS@IP to specify control plane"
            exit 1
        fi
    else
        # Remote installation
        local k3s_args=("-c" "$K3S_CONTROL_PLANE")
        
        if [[ -n "$K3S_CP_IP" ]]; then
            k3s_args+=("--cp-ip" "$K3S_CP_IP")
        fi
        
        for worker in "${K3S_WORKERS[@]}"; do
            k3s_args+=("-w" "$worker")
        done
        
        # Init control plane
        run_script "setup-k3s.sh" "${k3s_args[@]}" init
        
        # Join workers if any
        if [[ ${#K3S_WORKERS[@]} -gt 0 ]]; then
            run_script "setup-k3s.sh" "${k3s_args[@]}" join
        fi
    fi
    
    # Verify cluster is now accessible
    sleep 5
    if ! cluster_accessible; then
        log_error "Cluster is not accessible after K3s installation"
        exit 1
    fi
    
    log_success "K3s installation completed"
}

step_flux() {
    log_step "Flux CD Installation"
    
    # Verify cluster is accessible
    if ! cluster_accessible; then
        log_error "Kubernetes cluster is not accessible"
        log_info "Please install K3s first or configure kubeconfig"
        exit 1
    fi
    
    run_script "install-flux.sh" install
    
    log_success "Flux CD installation completed"
}

step_openbao() {
    log_step "OpenBao Installation"
    
    # Verify cluster is accessible
    if ! cluster_accessible; then
        log_error "Kubernetes cluster is not accessible"
        exit 1
    fi
    
    local openbao_args=()
    
    if [[ -n "$OPENBAO_MANIFESTS_DIR" ]]; then
        openbao_args+=("-m" "$OPENBAO_MANIFESTS_DIR")
    fi
    
    if [[ -n "$OPENBAO_VALUES_FILE" && -f "$OPENBAO_VALUES_FILE" ]]; then
        openbao_args+=("-f" "$OPENBAO_VALUES_FILE")
    fi
    
    if [[ "$VERBOSE" == true ]]; then
        openbao_args+=("-v")
    fi
    
    run_script "install-openbao.sh" "${openbao_args[@]}"
    
    log_success "OpenBao installation completed"
}

step_openobserve() {
    log_step "OpenObserve Installation"
    
    # Verify cluster is accessible
    if ! cluster_accessible; then
        log_error "Kubernetes cluster is not accessible"
        exit 1
    fi
    
    run_script "install-openobserve.sh" install
    
    log_success "OpenObserve installation completed"
}

step_collector() {
    log_step "OpenObserve Collector Installation"
    
    # Verify cluster is accessible
    if ! cluster_accessible; then
        log_error "Kubernetes cluster is not accessible"
        exit 1
    fi
    
    # Check for auth token
    if [[ -z "$OPENOBSERVE_AUTH" ]]; then
        if [[ "$INTERACTIVE" == true ]]; then
            echo ""
            log_warning "OpenObserve Collector requires an authentication token"
            echo ""
            read -p "Enter OpenObserve Basic auth token: " -r OPENOBSERVE_AUTH
            echo ""
            
            if [[ -z "$OPENOBSERVE_AUTH" ]]; then
                log_error "Auth token is required for collector installation"
                exit 1
            fi
        else
            log_error "OpenObserve auth token is required (--openobserve-auth)"
            exit 1
        fi
    fi
    
    run_script "install-openobserve-collector.sh" install "$OPENOBSERVE_AUTH"
    
    log_success "OpenObserve Collector installation completed"
}

step_phoenix() {
    log_step "Phoenix AI Observability Installation"
    
    # Verify cluster is accessible
    if ! cluster_accessible; then
        log_error "Kubernetes cluster is not accessible"
        exit 1
    fi
    
    # Check if OpenBao is installed (required for secrets)
    if ! kubectl get pods -n soludev -l app.kubernetes.io/name=openbao --no-headers 2>/dev/null | grep -q Running; then
        log_warning "OpenBao doesn't appear to be running"
        log_info "Phoenix requires secrets to be configured in OpenBao"
        
        if [[ "$INTERACTIVE" == true ]]; then
            read -p "Continue anyway? (y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log_warning "Skipping Phoenix installation"
                return 0
            fi
        fi
    fi
    
    local phoenix_args=("install")
    
    if [[ "$VERBOSE" == true ]]; then
        phoenix_args+=("-v")
    fi
    
    run_script "install-phoenix.sh" "${phoenix_args[@]}"
    
    log_success "Phoenix installation completed"
}

# =============================================================================
# PARSE ARGUMENTS
# =============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            # K3s options
            -c|--control-plane)
                K3S_CONTROL_PLANE="$2"
                shift 2
                ;;
            -w|--worker)
                K3S_WORKERS+=("$2")
                shift 2
                ;;
            --cp-ip)
                K3S_CP_IP="$2"
                shift 2
                ;;
            
            # OpenBao options
            --openbao-values)
                OPENBAO_VALUES_FILE="$2"
                shift 2
                ;;
            --openbao-manifests)
                OPENBAO_MANIFESTS_DIR="$2"
                shift 2
                ;;
            
            # Collector options
            --openobserve-auth)
                OPENOBSERVE_AUTH="$2"
                shift 2
                ;;
            
            # General options
            -y|--yes)
                SKIP_CONFIRMATION=true
                INTERACTIVE=false
                shift
                ;;
            --dry-run)
                DRY_RUN=true
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
            
            # Steps
            k3s|flux|openbao|openobserve|collector|phoenix)
                STEPS_TO_RUN+=("$1")
                shift
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
# MAIN
# =============================================================================

print_banner() {
    echo ""
    echo -e "${CYAN}${BOLD}"
    echo "  ╔═══════════════════════════════════════════════════════════╗"
    echo "  ║                                                           ║"
    echo "  ║           Complete Cluster Installation                   ║"
    echo "  ║                                                           ║"
    echo "  ║   K3s → Flux → OpenBao → OpenObserve → Collector → Phoenix║"
    echo "  ║                                                           ║"
    echo "  ╚═══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
}

print_plan() {
    echo -e "${BOLD}Installation Plan:${NC}"
    echo ""
    
    local step_num=1
    for step in "${ALL_STEPS[@]}"; do
        local status=""
        if should_run_step "$step"; then
            status="${GREEN}✓ Will install${NC}"
        else
            status="${YELLOW}○ Skipped${NC}"
        fi
        
        local description=""
        case $step in
            k3s)        description="Kubernetes cluster (K3s)" ;;
            flux)       description="Flux CD (GitOps)" ;;
            openbao)    description="OpenBao (Secrets management)" ;;
            openobserve) description="OpenObserve (Observability platform)" ;;
            collector)  description="OpenObserve Collector (Metrics/Logs/Traces)" ;;
            phoenix)    description="Phoenix (AI Observability platform)" ;;
        esac
        
        echo -e "  ${step_num}. ${BOLD}${step}${NC} - $description"
        echo -e "     $status"
        echo ""
        step_num=$((step_num + 1))
    done
    
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}${BOLD}DRY-RUN MODE: No changes will be made${NC}"
        echo ""
    fi
}

confirm_installation() {
    if [[ "$SKIP_CONFIRMATION" == true ]]; then
        return 0
    fi
    
    echo ""
    read -p "$(echo -e "${YELLOW}${BOLD}Proceed with installation? (Y/n):${NC} ")" -n 1 -r
    echo ""
    
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        log_info "Installation cancelled"
        exit 0
    fi
}

print_summary() {
    echo ""
    echo -e "${GREEN}${BOLD}"
    echo "  ╔═══════════════════════════════════════════════════════════╗"
    echo "  ║                                                           ║"
    echo "  ║           Installation Complete!                          ║"
    echo "  ║                                                           ║"
    echo "  ╚═══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
    
    echo -e "${BOLD}Installed Components:${NC}"
    echo ""
    
    for step in "${ALL_STEPS[@]}"; do
        if should_run_step "$step"; then
            echo -e "  ${GREEN}✓${NC} $step"
        fi
    done
    
    echo ""
    echo -e "${BOLD}Useful Commands:${NC}"
    echo ""
    echo "  # Check cluster status"
    echo "  kubectl get nodes"
    echo "  kubectl get pods -A"
    echo ""
    echo "  # Check Flux status"
    echo "  flux get all"
    echo ""
    echo "  # Check OpenBao status"
    echo "  kubectl exec -n soludev openbao-0 -- bao status"
    echo ""
    echo "  # Check OpenObserve status"
    echo "  kubectl get pods -n soludev -l app.kubernetes.io/name=openobserve"
    echo ""
    echo "  # Check Collector status"
    echo "  kubectl get pods -n openobserve-collector"
    echo ""
    echo "  # Check Phoenix status"
    echo "  kubectl get pods -n soludev -l app.kubernetes.io/name=phoenix"
    echo ""
    echo "  # Individual script status commands"
    echo "  $SCRIPT_DIR/setup-k3s.sh status"
    echo "  $SCRIPT_DIR/install-flux.sh status  # (if available)"
    echo "  $SCRIPT_DIR/install-openbao.sh status  # (if available)"
    echo "  $SCRIPT_DIR/install-openobserve.sh status"
    echo "  $SCRIPT_DIR/install-openobserve-collector.sh status"
    echo ""
}

main() {
    parse_args "$@"
    
    print_banner
    
    # Check prerequisites
    check_prerequisites
    
    # Show plan
    print_plan
    
    # Confirm
    confirm_installation
    
    # Execute steps in order
    for step in "${ALL_STEPS[@]}"; do
        if should_run_step "$step"; then
            if confirm_step "$step"; then
                case $step in
                    k3s)        step_k3s ;;
                    flux)       step_flux ;;
                    openbao)    step_openbao ;;
                    openobserve) step_openobserve ;;
                    collector)  step_collector ;;
                    phoenix)    step_phoenix ;;
                esac
            else
                log_info "Skipping step: $step"
            fi
        fi
    done
    
    # Summary
    if [[ "$DRY_RUN" != true ]]; then
        print_summary
    fi
    
    log_success "All done!"
}

main "$@"
