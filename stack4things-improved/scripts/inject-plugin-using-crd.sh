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
echo "  INJECTING PLUGIN USING CRD"
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

# Get plugin UUID from Crossplane Plugin status
PLUGIN_UUID=$(kubectl get plugin "$PLUGIN_NAME" -n default -o jsonpath='{.spec.forProvider.uuid}' 2>/dev/null || echo "")

# If not in spec, try to get from database using the plugin name from Crossplane
if [ -z "$PLUGIN_UUID" ] || [ "$PLUGIN_UUID" == "null" ]; then
    # Get plugin name from Crossplane
    PLUGIN_NAME_DB=$(kubectl get plugin "$PLUGIN_NAME" -n default -o jsonpath='{.spec.forProvider.name}' 2>/dev/null || echo "")
    if [ -z "$PLUGIN_NAME_DB" ]; then
        PLUGIN_NAME_DB="$PLUGIN_NAME"
    fi
    
    # Try to get from database
    DB_POD=$(kubectl get pod -n default -l io.kompose.service=iotronic-db -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$DB_POD" ] && [ -n "$PLUGIN_NAME_DB" ]; then
        PLUGIN_UUID=$(kubectl exec -n default "$DB_POD" -- mysql -uroot -ps4t iotronic -Nse "SELECT uuid FROM plugins WHERE name='$PLUGIN_NAME_DB' LIMIT 1;" 2>/dev/null || echo "")
    fi
fi

if [ -z "$PLUGIN_UUID" ] || [ "$PLUGIN_UUID" == "null" ]; then
    echo -e "${RED}ERROR: Plugin '$PLUGIN_NAME' not found or UUID not available${NC}"
    echo ""
    echo "Available plugins:"
    kubectl get plugin -n default 2>/dev/null || echo "  (none found)"
    echo ""
    echo "Plugin details:"
    kubectl get plugin "$PLUGIN_NAME" -n default -o yaml 2>/dev/null | grep -A 5 "spec:" || true
    exit 1
fi

echo "Plugin UUID: $PLUGIN_UUID"
echo ""

# Create BoardPluginInjection CRD
INJECTION_NAME="injection-${BOARD_CODE}-${PLUGIN_NAME}"
INJECTION_NAME=$(echo "$INJECTION_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-\|-$//g')

echo "Creating BoardPluginInjection CRD: $INJECTION_NAME"
cat <<EOF | kubectl apply -f -
apiVersion: iot.s4t.crossplane.io/v1alpha1
kind: BoardPluginInjection
metadata:
  name: ${INJECTION_NAME}
  namespace: default
spec:
  forProvider:
    boardUuid: "${BOARD_UUID}"
    pluginUuid: "${PLUGIN_UUID}"
  providerConfigRef:
    name: s4t-provider-domain
  deletionPolicy: Delete
EOF

echo ""
echo "Waiting for injection to be ready..."
sleep 5

kubectl get boardplugininjection "$INJECTION_NAME" -n default 2>/dev/null || echo -e "${YELLOW}Injection resource may still be creating${NC}"

echo ""
echo "=========================================="
echo -e "${GREEN}Injection created!${NC}"
echo "=========================================="
echo ""
echo "To verify injection:"
echo "  kubectl get boardplugininjection $INJECTION_NAME -n default"
echo "  kubectl describe boardplugininjection $INJECTION_NAME -n default"
echo ""
echo "To check in database:"
echo "  DB_POD=\$(kubectl get pod -n default -l io.kompose.service=iotronic-db -o jsonpath='{.items[0].metadata.name}')"
echo "  kubectl exec -n default \$DB_POD -- mysql -uroot -ps4t iotronic -e \"SELECT * FROM injected_plugins WHERE board='$BOARD_UUID' AND plugin='$PLUGIN_UUID';\""
