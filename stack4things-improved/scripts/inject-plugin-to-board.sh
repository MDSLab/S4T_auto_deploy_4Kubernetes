#!/bin/bash

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

BOARD_CODE="${1:-}"
PLUGIN_NAME="${2:-}"

if [ -z "$BOARD_CODE" ] || [ -z "$PLUGIN_NAME" ]; then
    echo -e "${RED}Usage: $0 <board-code> <plugin-name>${NC}"
    echo ""
    echo "Example:"
    echo "  $0 TEST-BOARD-1234567890-1 simple-environmental-logger"
    exit 1
fi

# Configurazione kubeconfig
if [ -f /etc/rancher/k3s/k3s.yaml ]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
elif [ -f /etc/rancher/k3s/k3s.yaml_backup ]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml_backup
else
    echo -e "${RED}ERROR: kubeconfig not found${NC}"
    exit 1
fi

echo ""
echo "=========================================="
echo "  INJECTING PLUGIN INTO BOARD"
echo "=========================================="
echo ""
echo "Board Code: $BOARD_CODE"
echo "Plugin Name: $PLUGIN_NAME"
echo ""

# Get board UUID from Device or database
BOARD_UUID=""
DEVICE_NAME=$(kubectl get device -n default -o json | jq -r ".items[] | select(.spec.forProvider.code == \"$BOARD_CODE\") | .metadata.name" 2>/dev/null || echo "")

if [ -n "$DEVICE_NAME" ]; then
    BOARD_UUID=$(kubectl get device -n default "$DEVICE_NAME" -o jsonpath='{.status.atProvider.uuid}' 2>/dev/null || echo "")
fi

if [ -z "$BOARD_UUID" ]; then
    # Try to get from database
    DB_POD=$(kubectl get pod -n default -l io.kompose.service=iotronic-db -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$DB_POD" ]; then
        BOARD_UUID=$(kubectl exec -n default "$DB_POD" -- mysql -uroot -ps4t iotronic -Nse "SELECT uuid FROM boards WHERE code='$BOARD_CODE' LIMIT 1;" 2>/dev/null || echo "")
    fi
fi

if [ -z "$BOARD_UUID" ]; then
    echo -e "${RED}ERROR: Board with code '$BOARD_CODE' not found${NC}"
    echo ""
    echo "Available boards:"
    kubectl get device -n default -o json | jq -r '.items[] | "  - \(.spec.forProvider.code) (\(.metadata.name))"' 2>/dev/null || echo "  (none found)"
    exit 1
fi

echo "Board UUID: $BOARD_UUID"

# Get plugin UUID - first try spec.forProvider.uuid, then database
PLUGIN_UUID=$(kubectl get plugin -n default "$PLUGIN_NAME" -o jsonpath='{.spec.forProvider.uuid}' 2>/dev/null || echo "")

if [ -z "$PLUGIN_UUID" ] || [ "$PLUGIN_UUID" == "null" ]; then
    # Try to get plugin name from Crossplane spec
    PLUGIN_NAME_DB=$(kubectl get plugin -n default "$PLUGIN_NAME" -o jsonpath='{.spec.forProvider.name}' 2>/dev/null || echo "$PLUGIN_NAME")
    
    # Try to get from database
    DB_POD=$(kubectl get pod -n default -l io.kompose.service=iotronic-db -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$DB_POD" ]; then
        PLUGIN_UUID=$(kubectl exec -n default "$DB_POD" -- mysql -h127.0.0.1 -uiotronic -punime iotronic -Nse "SELECT uuid FROM plugins WHERE name='$PLUGIN_NAME_DB' LIMIT 1;" 2>/dev/null || echo "")
    fi
fi

if [ -z "$PLUGIN_UUID" ]; then
    echo -e "${RED}ERROR: Plugin '$PLUGIN_NAME' not found or not ready${NC}"
    echo ""
    echo "Available plugins:"
    kubectl get plugin -n default 2>/dev/null || echo "  (none found)"
    exit 1
fi

echo "Plugin UUID: $PLUGIN_UUID"
echo ""

# Inject plugin using IoTronic API
CONDUCTOR_POD=$(kubectl get pod -n default -l io.kompose.service=iotronic-conductor -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$CONDUCTOR_POD" ]; then
    echo -e "${RED}ERROR: IoTronic Conductor pod not found${NC}"
    exit 1
fi

echo "Injecting plugin via IoTronic API (PUT method)..."
TOKEN=$(kubectl exec -n default "$CONDUCTOR_POD" -- python3 -c "
import os
from keystoneauth1.identity import v3
from keystoneauth1 import session
auth = v3.Password(auth_url='http://keystone.default.svc.cluster.local:5000/v3',
                   username='admin',
                   password='s4t',
                   project_name='admin',
                   user_domain_name='default',
                   project_domain_name='default')
sess = session.Session(auth=auth)
print(sess.get_token())
" 2>/dev/null || echo "")

if [ -z "$TOKEN" ]; then
    echo -e "${RED}ERROR: Failed to get authentication token${NC}"
    exit 1
fi

INJECTION_RESULT=$(kubectl exec -n default "$CONDUCTOR_POD" -- curl -s -w "\nHTTP_STATUS:%{http_code}" -X PUT \
    -H "Content-Type: application/json" \
    -H "X-Auth-Token: $TOKEN" \
    -d "{\"plugin\": \"$PLUGIN_UUID\"}" \
    "http://iotronic-conductor.default.svc.cluster.local:8812/v1/boards/${BOARD_UUID}/plugins/" \
    2>/dev/null || echo "")

HTTP_STATUS=$(echo "$INJECTION_RESULT" | grep "HTTP_STATUS" | cut -d: -f2)
INJECT_BODY=$(echo "$INJECTION_RESULT" | sed '/HTTP_STATUS/d')

if [ "$HTTP_STATUS" == "201" ] || [ "$HTTP_STATUS" == "200" ]; then
    echo -e "${GREEN}Plugin injected successfully! (Status: $HTTP_STATUS)${NC}"
    echo ""
    echo "$INJECT_BODY" | jq '.' 2>/dev/null || echo "$INJECT_BODY"
else
    echo -e "${RED}Injection failed (Status: $HTTP_STATUS)${NC}"
    echo ""
    echo "Response: $INJECT_BODY"
    echo ""
    echo "Common issues:"
    echo "  - Board must be online (Lightning Rod connected)"
    echo "  - Plugin must exist in database"
    echo "  - Check board status: kubectl get device -n default"
fi

echo ""
echo "To start the plugin on the board, use the IoTronic API or dashboard:"
echo "  POST /v1/boards/${BOARD_UUID}/plugins/${PLUGIN_UUID}/start"
