#!/bin/bash
#
# OpenObserve Dashboard & RUM Backup Script
# Backs up all dashboards, alerts, pipelines, and RUM configuration
# via the OpenObserve API before a migration/upgrade.
#
set -euo pipefail

NAMESPACE="soludev"
BACKUP_DIR="./backups/openobserve/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

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

# --- Get credentials from k8s secret ---
ZO_EMAIL=$(kubectl get secret -n "$NAMESPACE" soludev-openobserve-secret \
  -o jsonpath='{.data.ZO_ROOT_USER_EMAIL}' | base64 -d)
ZO_PASS=$(kubectl get secret -n "$NAMESPACE" soludev-openobserve-secret \
  -o jsonpath='{.data.ZO_ROOT_USER_PASSWORD}' | base64 -d)
ZO_URL="http://openobserve-openobserve-standalone.$NAMESPACE.svc.cluster.local:5080"

# --- Port-forward in background ---
log_info "Starting port-forward to OpenObserve..."
PF_PID=""
cleanup() {
  if [ -n "$PF_PID" ]; then
    kill "$PF_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

kubectl port-forward -n "$NAMESPACE" svc/openobserve-openobserve-standalone 15080:5080 >/dev/null 2>&1 &
PF_PID=$!
sleep 3

LOCAL_URL="http://localhost:15080"

# --- Auth ---
log_info "Authenticating..."
AUTH_TOKEN=$(curl -s -X POST "$LOCAL_URL/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$ZO_EMAIL\",\"password\":\"$ZO_PASS\"}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('auth',''))" 2>/dev/null)

if [ -z "$AUTH_TOKEN" ]; then
  log_err "Authentication failed. Check credentials."
  exit 1
fi
log_ok "Authenticated successfully"

# --- List organizations ---
log_info "Fetching organizations..."
ORGS=$(curl -s "$LOCAL_URL/api/default/orgs" \
  -H "Authorization: Bearer $AUTH_TOKEN")

echo "$ORGS" | python3 -c "import sys,json; [print(o['identifier']) for o in json.load(sys.stdin).get('data',[])]" 2>/dev/null > "$BACKUP_DIR/orgs.txt"
ORG_COUNT=$(wc -l < "$BACKUP_DIR/orgs.txt" | tr -d ' ')
log_ok "Found $ORG_COUNT organization(s)"

# --- Fetch stream names ---
log_info "Fetching stream names..."
STREAMS=$(curl -s "$LOCAL_URL/api/default/default/streams" \
  -H "Authorization: Bearer $AUTH_TOKEN")
echo "$STREAMS" | python3 -m json.tool > "$BACKUP_DIR/streams.json" 2>/dev/null || true

# --- Backup dashboards ---
log_info "Backing up dashboards..."
while IFS= read -r ORG; do
  ORG_DIR="$BACKUP_DIR/orgs/$ORG"
  mkdir -p "$ORG_DIR/dashboards" "$ORG_DIR/alerts" "$ORG_DIR/pipelines" "$ORG_DIR/functions"

  DASHBOARDS=$(curl -s "$LOCAL_URL/api/default/$ORG/dashboards" \
    -H "Authorization: Bearer $AUTH_TOKEN" 2>/dev/null)

  DASH_IDS=$(echo "$DASHBOARDS" | python3 -c "
import sys,json
try:
  data = json.load(sys.stdin)
  for d in data.get('data', data.get('dashboards', data.get('list', []))):
    did = d.get('dashboard_id', d.get('dashBoardId', d.get('_id', d.get('id',''))))
    if did: print(did)
except: pass
" 2>/dev/null || true)

  DASH_COUNT=$(echo "$DASH_IDS" | grep -c . 2>/dev/null || echo 0)
  log_info "  [$ORG] Found $DASH_COUNT dashboard(s)"

  while IFS= read -r DASH_ID; do
    [ -z "$DASH_ID" ] && continue
    DASH_DATA=$(curl -s "$LOCAL_URL/api/default/$ORG/dashboards/$DASH_ID" \
      -H "Authorization: Bearer $AUTH_TOKEN" 2>/dev/null)
    echo "$DASH_DATA" | python3 -m json.tool > "$ORG_DIR/dashboards/${DASH_ID}.json" 2>/dev/null || true
  done <<< "$DASH_IDS"

  # --- Backup alerts ---
  log_info "  [$ORG] Backing up alerts..."
  ALERTS=$(curl -s "$LOCAL_URL/api/default/$ORG/alerts" \
    -H "Authorization: Bearer $AUTH_TOKEN" 2>/dev/null)
  echo "$ALERTS" | python3 -m json.tool > "$ORG_DIR/alerts/all_alerts.json" 2>/dev/null || true

  for stream_type in logs metrics traces; do
    STREAMS_OF_TYPE=$(echo "$STREAMS" | python3 -c "
import sys,json
try:
  data = json.load(sys.stdin)
  for s in data.get('data',[]).get('list',data.get('data',[])):
    if s.get('stream_type','') == '$stream_type':
      print(s.get('name',''))
except: pass
" 2>/dev/null || true)

    while IFS= read -r STREAM; do
      [ -z "$STREAM" ] && continue
      STREAM_ALERTS=$(curl -s "$LOCAL_URL/api/default/$ORG/$stream_type/$STREAM/alerts" \
        -H "Authorization: Bearer $AUTH_TOKEN" 2>/dev/null || true)
      if [ -n "$STREAM_ALERTS" ] && echo "$STREAM_ALERTS" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
        mkdir -p "$ORG_DIR/alerts/$stream_type"
        echo "$STREAM_ALERTS" | python3 -m json.tool > "$ORG_DIR/alerts/$stream_type/${STREAM}.json" 2>/dev/null || true
      fi
    done <<< "$STREAMS_OF_TYPE"
  done

  # --- Backup pipelines ---
  log_info "  [$ORG] Backing up pipelines..."
  PIPELINES=$(curl -s "$LOCAL_URL/api/default/$ORG/pipelines" \
    -H "Authorization: Bearer $AUTH_TOKEN" 2>/dev/null || true)
  echo "$PIPELINES" | python3 -m json.tool > "$ORG_DIR/pipelines/all_pipelines.json" 2>/dev/null || true

  # --- Backup functions ---
  log_info "  [$ORG] Backing up functions..."
  FUNCTIONS=$(curl -s "$LOCAL_URL/api/default/$ORG/functions" \
    -H "Authorization: Bearer $AUTH_TOKEN" 2>/dev/null || true)
  echo "$FUNCTIONS" | python3 -m json.tool > "$ORG_DIR/functions/all_functions.json" 2>/dev/null || true

  # --- Backup RUM config ---
  log_info "  [$ORG] Backing up RUM configuration..."
  RUM_CONFIG=$(curl -s "$LOCAL_URL/api/default/$ORG/rum/config" \
    -H "Authorization: Bearer $AUTH_TOKEN" 2>/dev/null || true)
  echo "$RUM_CONFIG" | python3 -m json.tool > "$ORG_DIR/rum_config.json" 2>/dev/null || true

  # --- Backup saved searches ---
  log_info "  [$ORG] Backing up saved searches..."
  SEARCHES=$(curl -s "$LOCAL_URL/api/default/$ORG/search/saved" \
    -H "Authorization: Bearer $AUTH_TOKEN" 2>/dev/null || true)
  echo "$SEARCHES" | python3 -m json.tool > "$ORG_DIR/saved_searches.json" 2>/dev/null || true

  # --- Backup settings/folders ---
  log_info "  [$ORG] Backing up folders..."
  FOLDERS=$(curl -s "$LOCAL_URL/api/default/$ORG/folders" \
    -H "Authorization: Bearer $AUTH_TOKEN" 2>/dev/null || true)
  echo "$FOLDERS" | python3 -m json.tool > "$ORG_DIR/folders.json" 2>/dev/null || true

done < "$BACKUP_DIR/orgs.txt"

# --- Summary ---
echo ""
log_ok "============================================="
log_ok "  Backup complete!"
log_ok "============================================="
echo ""
log_info "Backup location: $BACKUP_DIR"
echo ""

TOTAL_DASHBOARDS=$(find "$BACKUP_DIR" -name "*.json" -path "*/dashboards/*" | wc -l | tr -d ' ')
TOTAL_ALERTS=$(find "$BACKUP_DIR" -name "*.json" -path "*/alerts/*" | wc -l | tr -d ' ')
TOTAL_PIPELINES=$(find "$BACKUP_DIR" -name "all_pipelines.json" | wc -l | tr -d ' ')

log_info "Dashboards: $TOTAL_DASHBOARDS"
log_info "Alert files: $TOTAL_ALERTS"
log_info "Pipelines:  $TOTAL_PIPELINES"
echo ""
log_info "To restore dashboards after upgrade:"
log_info "  Use: ./config/scripts/restore-openobserve-dashboards.sh $BACKUP_DIR"
echo ""
log_warn "IMPORTANT: Data in MinIO (logs/metrics/traces) and PostgreSQL (metadata)"
log_warn "is preserved during upgrade. Dashboards stored in PostgreSQL will be"
log_warn "migrated automatically by OpenObserve's internal migration system."
log_warn "This backup is a safety net in case rollback is needed."