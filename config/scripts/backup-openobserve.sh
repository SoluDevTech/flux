#!/bin/bash
#
# OpenObserve Dashboard & RUM Backup Script
# Backs up dashboards, folders, alerts, pipelines, functions, saved views
# and RUM tokens via the OpenObserve API before a migration/upgrade.
#
# API map verified against v1.0.x (from /api-doc/openapi.json):
#   orgs      : GET /api/organizations
#   streams   : GET /api/{org}/streams
#   folders   : GET /api/v2/{org}/folders/dashboards
#   dashboards: GET /api/{org}/dashboards?folder={folderId}  (folder-less: no param)
#   detail    : GET /api/{org}/dashboards/{dashboardId}      (versioned v1..v8 wrapper)
#   alerts    : GET /api/v2/{org}/alerts
#   pipelines : GET /api/{org}/pipelines
#   functions : GET /api/{org}/functions
#   savedviews: GET /api/{org}/savedviews
#   rum token : GET /api/{org}/rumtoken
# Auth: HTTP Basic (the /auth/login token flow stopped working on v1.0.x).
#
set -euo pipefail

# Always write backups under the flux repo root, regardless of the caller's CWD
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../.."

NAMESPACE="soludev"
# Allow callers (e.g. upgrade-openobserve.sh) to funnel all backup artifacts
# into a single directory instead of a fresh timestamped one per run.
BACKUP_DIR="${O2_BACKUP_DIR:-./backups/openobserve/$(date +%Y%m%d_%H%M%S)}"
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

# --- Auth (HTTP Basic) ---
log_info "Verifying API access (HTTP Basic)..."
API_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -u "$ZO_EMAIL:$ZO_PASS" "$LOCAL_URL/api/organizations")
if [ "$API_STATUS" != "200" ]; then
  log_err "API authentication failed (HTTP $API_STATUS). Check credentials."
  exit 1
fi
log_ok "API access verified"

# --- List organizations ---
log_info "Fetching organizations..."
curl -s -m 30 -u "$ZO_EMAIL:$ZO_PASS" "$LOCAL_URL/api/organizations" \
  | python3 -c "import sys,json; [print(o['identifier']) for o in json.load(sys.stdin).get('data',[])]" \
  > "$BACKUP_DIR/orgs.txt" 2>/dev/null
ORG_COUNT=$(grep -c . "$BACKUP_DIR/orgs.txt" || true)
if [ "$ORG_COUNT" = "0" ]; then
  log_err "No organizations found — refusing to produce an empty backup."
  exit 1
fi
log_ok "Found $ORG_COUNT organization(s)"

# --- Backup per org ---
while IFS= read -r ORG; do
  [ -z "$ORG" ] && continue
  ORG_DIR="$BACKUP_DIR/orgs/$ORG"
  mkdir -p "$ORG_DIR/dashboards" "$ORG_DIR/alerts"

  # --- Streams ---
  log_info "  [$ORG] Fetching streams..."
  curl -s -m 30 -u "$ZO_EMAIL:$ZO_PASS" "$LOCAL_URL/api/$ORG/streams" \
    | python3 -m json.tool > "$ORG_DIR/streams.json" 2>/dev/null || true

  # --- Folders (v2) ---
  log_info "  [$ORG] Fetching dashboard folders..."
  curl -s -m 30 -u "$ZO_EMAIL:$ZO_PASS" "$LOCAL_URL/api/v2/$ORG/folders/dashboards" \
    | python3 -m json.tool > "$ORG_DIR/folders.json" 2>/dev/null || true

  # --- Dashboards: folder-less list + one list per folder ---
  log_info "  [$ORG] Backing up dashboards..."
  DASH_IDS_FILE="$ORG_DIR/dashboard_ids.txt"
  : > "$DASH_IDS_FILE"

  extract_ids() {
    # Reads a dashboards list JSON on stdin, prints one dashboardId per line.
    python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for d in data.get('dashboards', []):
        did = ''
        for vkey in ['v1','v2','v3','v4','v5','v6','v7','v8']:
            v = d.get(vkey)
            if isinstance(v, dict) and v.get('dashboardId'):
                did = v['dashboardId']
                break
        if not did:
            did = d.get('dashboard_id', d.get('dashBoardId', d.get('_id', d.get('id',''))))
        if did:
            print(did)
except Exception:
    pass
" 2>/dev/null || true
  }

  # Folder-less dashboards
  curl -s -m 30 -u "$ZO_EMAIL:$ZO_PASS" "$LOCAL_URL/api/$ORG/dashboards" | extract_ids >> "$DASH_IDS_FILE"

  # Dashboards inside each folder
  curl -s -m 30 -u "$ZO_EMAIL:$ZO_PASS" "$LOCAL_URL/api/v2/$ORG/folders/dashboards" \
    | python3 -c "import sys,json; [print(f['folderId']) for f in json.load(sys.stdin).get('list',[])]" 2>/dev/null \
    | while IFS= read -r FID; do
        [ -z "$FID" ] && continue
        curl -s -m 30 -u "$ZO_EMAIL:$ZO_PASS" "$LOCAL_URL/api/$ORG/dashboards?folder=$FID" \
          | extract_ids >> "$DASH_IDS_FILE"
      done

  DASH_COUNT=$(sort -u "$DASH_IDS_FILE" | grep -c . || true)
  log_info "  [$ORG] Found $DASH_COUNT dashboard(s)"

  sort -u "$DASH_IDS_FILE" | while IFS= read -r DASH_ID; do
    [ -z "$DASH_ID" ] && continue
    curl -s -m 30 -u "$ZO_EMAIL:$ZO_PASS" "$LOCAL_URL/api/$ORG/dashboards/$DASH_ID" \
      | python3 -m json.tool > "$ORG_DIR/dashboards/${DASH_ID}.json" 2>/dev/null || true
  done

  # --- Alerts (v2 org-wide list) ---
  log_info "  [$ORG] Backing up alerts..."
  curl -s -m 30 -u "$ZO_EMAIL:$ZO_PASS" "$LOCAL_URL/api/v2/$ORG/alerts" \
    | python3 -m json.tool > "$ORG_DIR/alerts/all_alerts.json" 2>/dev/null || true

  # --- Alert destinations & templates ---
  curl -s -m 30 -u "$ZO_EMAIL:$ZO_PASS" "$LOCAL_URL/api/$ORG/alerts/destinations" \
    | python3 -m json.tool > "$ORG_DIR/alerts/destinations.json" 2>/dev/null || true
  curl -s -m 30 -u "$ZO_EMAIL:$ZO_PASS" "$LOCAL_URL/api/$ORG/alerts/templates" \
    | python3 -m json.tool > "$ORG_DIR/alerts/templates.json" 2>/dev/null || true

  # --- Pipelines ---
  log_info "  [$ORG] Backing up pipelines..."
  curl -s -m 30 -u "$ZO_EMAIL:$ZO_PASS" "$LOCAL_URL/api/$ORG/pipelines" \
    | python3 -m json.tool > "$ORG_DIR/pipelines.json" 2>/dev/null || true

  # --- Functions ---
  log_info "  [$ORG] Backing up functions..."
  curl -s -m 30 -u "$ZO_EMAIL:$ZO_PASS" "$LOCAL_URL/api/$ORG/functions" \
    | python3 -m json.tool > "$ORG_DIR/functions.json" 2>/dev/null || true

  # --- Saved views ---
  log_info "  [$ORG] Backing up saved views..."
  curl -s -m 30 -u "$ZO_EMAIL:$ZO_PASS" "$LOCAL_URL/api/$ORG/savedviews" \
    | python3 -m json.tool > "$ORG_DIR/saved_views.json" 2>/dev/null || true

  # --- RUM token ---
  log_info "  [$ORG] Backing up RUM token..."
  curl -s -m 30 -u "$ZO_EMAIL:$ZO_PASS" "$LOCAL_URL/api/$ORG/rumtoken" \
    | python3 -m json.tool > "$ORG_DIR/rum_token.json" 2>/dev/null || true

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

log_info "Dashboards: $TOTAL_DASHBOARDS"
echo ""
log_info "To restore dashboards after upgrade:"
log_info "  Use: ./config/scripts/restore-openobserve-dashboards.sh $BACKUP_DIR"
echo ""
log_warn "IMPORTANT: Data in RustFS (logs/metrics/traces) and PostgreSQL (metadata)"
log_warn "is preserved during upgrade. Dashboards stored in PostgreSQL will be"
log_warn "migrated automatically by OpenObserve's internal migration system."
log_warn "This backup is a safety net in case rollback is needed."
