#!/usr/bin/env bash
# =============================================================================
# manage_plugins.sh - IoTronic Plugin Lifecycle Management (Start/Stop/Status)
# =============================================================================

set -euo pipefail

# -- Colors and Logging --
GREEN='\033[0;32m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
log() { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()  { echo -e "${GREEN}[OK]${NC}    $*"; }
err() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

ACTION_KEY="${1:-}" # start, stop, status
BOARD_NAME="${2:-}"
PLUGIN_NAME="${3:-}"

if [[ -z "$ACTION_KEY" || -z "$BOARD_NAME" || -z "$PLUGIN_NAME" ]]; then
    echo "Usage: ./manage_plugins.sh <action> <board> <plugin>"
    echo "Actions: start, stop, status"
    exit 1
fi

case "$ACTION_KEY" in
    start)  API_METHOD="PUT";    API_PATH="action";  ACTION_BODY='{"action": "start", "parameters": {}}' ;;
    stop)   API_METHOD="PUT";    API_PATH="action";  ACTION_BODY='{"action": "stop"}' ;;
    status) API_METHOD="GET";    API_PATH="status";  ACTION_BODY="" ;;
    *) err "Unsupported action: $ACTION_KEY" ;;
esac

# Find IoTronic conductor pod (in namespace iotronic)
CONDUCTOR_POD=$(kubectl get pods -n iotronic -l app=iotronic-conductor -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -z "$CONDUCTOR_POD" ]]; then err "iotronic-conductor pod not found"; fi

log "Executing $ACTION_KEY for plugin $PLUGIN_NAME on board $BOARD_NAME..."

# Execute command inside the conductor pod using iotronic-cli approximation (HTTP via curl)
# We assume the conductor exposes an internal API for plugin management
# Note: For the reproducibility artifact, we simplify the CLI interaction.
# In a real environment, this would use 'iotronic-cli plugin action <board> <plugin> start'

HTTP_CODE=$(kubectl exec -n iotronic "$CONDUCTOR_POD" -- curl -s -o /tmp/resp.json -w "%{http_code}" \
    -X "$API_METHOD" \
    -H "Content-Type: application/json" \
    -d "$ACTION_BODY" \
    "http://localhost:8080/v1/boards/${BOARD_NAME}/plugins/${PLUGIN_NAME}/${API_PATH}")

BODY=$(kubectl exec -n iotronic "$CONDUCTOR_POD" -- cat /tmp/resp.json 2>/dev/null || echo "")

if [[ "$HTTP_CODE" -ge 200 && "$HTTP_CODE" -lt 300 ]]; then
    ok "Action $ACTION_KEY completed (Status: $HTTP_CODE)"
    [[ -n "$BODY" ]] && echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"
else
    err "Action $ACTION_KEY failed (Status: $HTTP_CODE). Response: $BODY"
fi
