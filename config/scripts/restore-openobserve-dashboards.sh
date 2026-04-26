#!/bin/bash
#
# OpenObserve Dashboard Restore Script
# Restores dashboards from a backup directory to a running OpenObserve instance.
#
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <backup_dir>"
  echo "Example: $0 ./backups/openobserve/20260425_140000"
  exit 1
fi

BACKUP_DIR="$1"
NAMESPACE="soludev"

if [ ! -d "$BACKUP_DIR" ]; then
  echo "ERROR: Backup directory not found: $BACKUP_DIR"
  exit 1
fi

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

# --- Get credentials ---
ZO_EMAIL=$(kubectl get secret -n "$NAMESPACE" soludev-openobserve-secret \
  -o jsonpath='{.data.ZO_ROOT_USER_EMAIL}' | base64 -d)
ZO_PASS=$(kubectl get secret -n "$NAMESPACE" soludev-openobserve-secret \
  -o jsonpath='{.data.ZO_ROOT_USER_PASSWORD}' | base64 -d)

# --- Port-forward ---
log_info "Starting port-forward..."
kubectl port-forward -n "$NAMESPACE" svc/openobserve-openobserve-standalone 15080:5080 >/dev/null 2>&1 &
PF_PID=$!
cleanup() { kill "$PF_PID" 2>/dev/null || true; }
trap cleanup EXIT
sleep 3

LOCAL_URL="http://localhost:15080"

# --- Auth ---
AUTH_TOKEN=$(curl -s -X POST "$LOCAL_URL/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$ZO_EMAIL\",\"password\":\"$ZO_PASS\"}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('auth',''))" 2>/dev/null)

if [ -z "$AUTH_TOKEN" ]; then
  log_err "Authentication failed."
  exit 1
fi
log_ok "Authenticated"

# --- Restore dashboards per org ---
RESTORED=0
FAILED=0

for ORG_DIR in "$BACKUP_DIR/orgs/"*/; do
  ORG=$(basename "$ORG_DIR")
  log_info "Restoring dashboards for org: $ORG"

  if [ ! -d "$ORG_DIR/dashboards" ]; then
    log_warn "  No dashboards directory for $ORG"
    continue
  fi

  for DASH_FILE in "$ORG_DIR/dashboards/"*.json; do
    [ -f "$DASH_FILE" ] || continue
    DASH_ID=$(basename "$DASH_FILE" .json)

    # Extract dashboard v2 payload
    PAYLOAD=$(python3 -c "
import json, sys
with open('$DASH_FILE') as f:
    data = json.load(f)
# Handle both direct dashboard data and wrapped responses
if 'data' in data:
    dash = data['data']
elif 'dashboard' in data:
    dash = {**data}
else:
    dash = data
# Remove fields that prevent re-creation
for key in ['_id', 'dashboard_id', 'dashBoardId', 'created_at', 'updated_at']:
    dash.pop(key, None)
print(json.dumps(dash))
" 2>/dev/null)

    if [ -z "$PAYLOAD" ]; then
      log_warn "  Failed to parse dashboard: $DASH_ID"
      FAILED=$((FAILED + 1))
      continue
    fi

    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
      -X POST "$LOCAL_URL/api/default/$ORG/dashboards" \
      -H "Authorization: Bearer $AUTH_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$PAYLOAD" 2>/dev/null || echo "000")

    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
      log_ok "  Restored dashboard: $DASH_ID"
      RESTORED=$((RESTORED + 1))
    else
      log_warn "  Failed to restore $DASH_ID (HTTP $HTTP_CODE). May already exist."
      FAILED=$((FAILED + 1))
    fi
  done
done

echo ""
log_ok "============================================="
log_ok "  Restore complete!"
log_ok "============================================="
log_info "Restored: $RESTORED dashboard(s)"
log_info "Failed:   $FAILED dashboard(s)"
log_info "Note: If a dashboard already exists after migration, it won't be duplicated."