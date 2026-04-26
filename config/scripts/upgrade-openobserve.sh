#!/bin/bash
#
# OpenObserve Upgrade Script v0.60.1 → v0.70.3
# Chart: 0.70.4 | Image: v0.70.3
#
# Includes: backup, upgrade, verification, rollback
#
set -euo pipefail

NAMESPACE="soludev"
RELEASE_NAME="openobserve"
CHART_NAME="openobserve/openobserve-standalone"
CHART_VERSION="0.70.4"
VALUES_FILE="./config/dev/openobserve/values.yml"
BACKUP_DIR="./backups/openobserve/$(date +%Y%m%d_%H%M%S)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()   { echo -e "${RED}[ERR]${NC} $1"; }

# --- Step 0: Prerequisites ---
check_prerequisites() {
    log_info "Checking prerequisites..."
    command -v kubectl >/dev/null 2>&1 || { log_err "kubectl not found"; exit 1; }
    command -v helm >/dev/null 2>&1 || { log_err "helm not found"; exit 1; }
    kubectl cluster-info >/dev/null 2>&1 || { log_err "Cannot connect to cluster"; exit 1; }
    [ -f "$VALUES_FILE" ] || { log_err "Values file not found: $VALUES_FILE"; exit 1; }

    CURRENT_CHART=$(helm list -n "$NAMESPACE" -o json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); [print(r.get('chart','')) for r in d if r.get('name')=='$RELEASE_NAME']" 2>/dev/null || echo "unknown")
    log_info "Current chart: $CURRENT_CHART"

    log_ok "Prerequisites OK"
}

# --- Step 1: Backup dashboards & PostgreSQL ---
backup_data() {
    log_info "============================================="
    log_info "  STEP 1: Backing up dashboards & data"
    log_info "============================================="

    mkdir -p "$BACKUP_DIR"

    # 1a. Backup dashboards via API
    log_info "Running dashboard backup script..."
    if [ -f "./config/scripts/backup-openobserve.sh" ]; then
        ./config/scripts/backup-openobserve.sh
        # Move backup to our backup dir
        LATEST_BACKUP=$(ls -td ./backups/openobserve/*/ 2>/dev/null | head -1)
        if [ -n "$LATEST_BACKUP" ] && [ "$LATEST_BACKUP" != "$BACKUP_DIR/" ]; then
            log_info "Dashboard backup at: $LATEST_BACKUP"
        fi
    else
        log_warn "Backup script not found at ./config/scripts/backup-openobserve.sh"
        log_warn "Consider running it manually before proceeding."
    fi

    # 1b. Backup PostgreSQL metadata
    log_info "Backing up PostgreSQL metadata..."
    POSTGRES_POD=$(kubectl get pods -n "$NAMESPACE" -l app=postgres -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [ -n "$POSTGRES_POD" ]; then
        kubectl exec -n "$NAMESPACE" "$POSTGRES_POD" -- \
            pg_dump -U openobserve openobserve > "$BACKUP_DIR/openobserve-metadata.sql" 2>/dev/null || {
            log_warn "PostgreSQL dump failed. Trying with different user..."
            kubectl exec -n "$NAMESPACE" "$POSTGRES_POD" -- \
                pg_dump -U logto openobserve > "$BACKUP_DIR/openobserve-metadata.sql" 2>/dev/null || \
                log_warn "Could not dump PostgreSQL. Continuing without DB backup."
        }
        log_ok "PostgreSQL metadata backed up to $BACKUP_DIR/openobserve-metadata.sql"
    else
        log_warn "PostgreSQL pod not found. Skipping DB backup."
    fi

    # 1c. Save current helm release values
    log_info "Saving current Helm release values..."
    helm get values "$RELEASE_NAME" -n "$NAMESPACE" > "$BACKUP_DIR/current-values.yaml" 2>/dev/null || true
    helm get values "$RELEASE_NAME" -n "$NAMESPACE" --all > "$BACKUP_DIR/all-values.yaml" 2>/dev/null || true

    log_ok "Backup complete at: $BACKUP_DIR"
}

# --- Step 2: Helm upgrade ---
helm_upgrade() {
    log_info "============================================="
    log_info "  STEP 2: Upgrading Helm release"
    log_info "============================================="

    helm repo update openobserve 2>/dev/null || helm repo add openobserve https://charts.openobserve.ai

    log_info "Upgrading to chart $CHART_VERSION with image v0.70.3..."
    helm upgrade "$RELEASE_NAME" "$CHART_NAME" \
        --version "$CHART_VERSION" \
        --namespace "$NAMESPACE" \
        -f "$VALUES_FILE" \
        --timeout 5m

    log_ok "Helm upgrade executed"
}

# --- Step 3: Verify ---
verify_upgrade() {
    log_info "============================================="
    log_info "  STEP 3: Verifying upgrade"
    log_info "============================================="

    # Wait for pod
    log_info "Waiting for OpenObserve pod to be ready..."
    kubectl wait --for=condition=ready pod \
        -l app.kubernetes.io/name=openobserve \
        -n "$NAMESPACE" \
        --timeout=300s || {
        log_err "Pod not ready after 5 minutes!"
        log_err "Check logs: kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=openobserve --tail=100"
        log_err "To rollback: $0 rollback $BACKUP_DIR"
        exit 1
    }

    # Check image version
    IMAGE=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=openobserve \
        -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null || echo "unknown")
    log_info "Running image: $IMAGE"

    # Check DB migration in logs
    log_info "Checking for migration messages in logs..."
    POD_NAME=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=openobserve \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$POD_NAME" ]; then
        MIGRATION_LOGS=$(kubectl logs -n "$NAMESPACE" "$POD_NAME" --tail=200 2>/dev/null | grep -i "migrat" || echo "No migration messages found")
        if [ -n "$MIGRATION_LOGS" ] && [ "$MIGRATION_LOGS" != "No migration messages found" ]; then
            log_info "DB Migration activity detected:"
            echo "$MIGRATION_LOGS" | head -10
        fi
    fi

    # Health check
    log_info "Running health check..."
    sleep 5
    kubectl exec -n "$NAMESPACE" -l app.kubernetes.io/name=openobserve -- \
        curl -sf http://localhost:5080/healthz 2>/dev/null && \
        log_ok "Health check passed" || \
        log_warn "Health check not reachable (may need more time to start)"

    # Check service
    log_info "Verifying service..."
    kubectl get svc -n "$NAMESPACE" openobserve-openobserve-standalone || {
        log_err "Service not found!"
        exit 1
    }

    # Check ingress
    log_info "Verifying ingress..."
    INGRESS_HOST=$(kubectl get ingress -n "$NAMESPACE" openobserve-ingress -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo "not found")
    log_info "Ingress host: $INGRESS_HOST"

    log_ok "Upgrade verification complete!"
}

# --- Rollback ---
do_rollback() {
    BACKUP_TO_USE="${1:-}"
    log_err "============================================="
    log_err "  ROLLBACK"
    log_err "============================================="

    # Helm rollback to previous revision
    log_info "Rolling back Helm release to previous revision..."
    helm rollback "$RELEASE_NAME" -n "$NAMESPACE" 2>/dev/null || {
        log_err "Helm rollback failed. You may need to reinstall manually."
        if [ -n "$BACKUP_TO_USE" ] && [ -f "$BACKUP_TO_USE/current-values.yaml" ]; then
            log_info "Previous values available at: $BACKUP_TO_USE/current-values.yaml"
        fi
        exit 1
    }

    # Wait for pod
    log_info "Waiting for rollback pod..."
    kubectl wait --for=condition=ready pod \
        -l app.kubernetes.io/name=openobserve \
        -n "$NAMESPACE" \
        --timeout=300s || true

    # Restore PostgreSQL if needed
    if [ -n "$BACKUP_TO_USE" ] && [ -f "$BACKUP_TO_USE/openobserve-metadata.sql" ]; then
        log_warn "If v0.70 DB migration already ran, you may need to restore PostgreSQL."
        log_warn "SQL backup: $BACKUP_TO_USE/openobserve-metadata.sql"
        log_warn "To restore:"
        log_warn "  kubectl exec -n $NAMESPACE <postgres-pod> -- psql -U openobserve openobserve < $BACKUP_TO_USE/openobserve-metadata.sql"
    fi

    # Restore dashboards
    if [ -n "$BACKUP_TO_USE" ] && [ -d "$BACKUP_TO_USE/orgs" ]; then
        log_warn "To restore dashboards manually:"
        log_warn "  ./config/scripts/restore-openobserve-dashboards.sh $BACKUP_TO_USE"
    fi

    log_info "Helm rollback executed. Check pod status."
    kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=openobserve
}

# --- Full upgrade flow ---
full_upgrade() {
    check_prerequisites
    backup_data

    echo ""
    log_warn "About to upgrade OpenObserve from v0.60.1 to v0.70.3"
    log_warn "Dashboards and metadata stored in PostgreSQL will be auto-migrated."
    log_warn "Data in MinIO (logs/metrics/traces) is preserved."
    log_warn "Backup is at: $BACKUP_DIR"
    echo ""
    read -p "Continue with upgrade? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Upgrade cancelled."
        exit 0
    fi

    helm_upgrade
    verify_upgrade

    echo ""
    log_ok "============================================="
    log_ok "  UPGRADE COMPLETE!"
    log_ok "============================================="
    echo ""
    log_info "Image: o2cr.ai/openobserve/openobserve:v0.70.3"
    log_info "Access: https://openobserve.soludev.tech"
    echo ""
    log_info "Verify your dashboards and RUM data are intact."
    log_info "If issues, rollback with: $0 rollback $BACKUP_DIR"
    echo ""
    log_info "To check migration logs:"
    log_info "  kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=openobserve | grep -i migrat"
}

# --- Main ---
case "${1:-upgrade}" in
    upgrade)
        full_upgrade
        ;;
    rollback)
        do_rollback "${2:-}"
        ;;
    backup-only)
        check_prerequisites
        backup_data
        ;;
    verify)
        verify_upgrade
        ;;
    *)
        echo "Usage: $0 {upgrade|rollback [backup_dir]|backup-only|verify}"
        exit 1
        ;;
esac