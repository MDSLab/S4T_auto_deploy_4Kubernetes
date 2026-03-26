#!/bin/bash

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

PLUGIN_NAME="${1:-}"
PLUGIN_FILE="${2:-}"

if [ -z "$PLUGIN_NAME" ]; then
    echo -e "${RED}Usage: $0 <plugin-name> [plugin-yaml-file]${NC}"
    echo ""
    echo "Examples:"
    echo "  $0 simple-environmental-logger examples/plugin-simple-example.yaml"
    echo "  $0 environmental-monitor examples/plugin-environmental-monitor.yaml"
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLES_DIR="$SCRIPT_DIR/../examples"

if [ -n "$PLUGIN_FILE" ]; then
    PLUGIN_YAML="$PLUGIN_FILE"
    if [ ! -f "$PLUGIN_YAML" ]; then
        # Try relative to examples directory
        PLUGIN_YAML="$EXAMPLES_DIR/$PLUGIN_FILE"
    fi
    if [ ! -f "$PLUGIN_YAML" ]; then
        # Try relative to script directory
        PLUGIN_YAML="$SCRIPT_DIR/$PLUGIN_FILE"
    fi
else
    # Try to find plugin file automatically
    PLUGIN_YAML="$EXAMPLES_DIR/plugin-${PLUGIN_NAME}.yaml"
    if [ ! -f "$PLUGIN_YAML" ]; then
        PLUGIN_YAML="$EXAMPLES_DIR/${PLUGIN_NAME}.yaml"
    fi
fi

if [ ! -f "$PLUGIN_YAML" ]; then
    echo -e "${YELLOW}Plugin YAML file not found: $PLUGIN_YAML${NC}"
    echo -e "${YELLOW}Creating a simple plugin from template...${NC}"
    
    # Create a simple plugin from template
    PLUGIN_YAML="/tmp/plugin-${PLUGIN_NAME}.yaml"
    cat > "$PLUGIN_YAML" <<EOF
apiVersion: iot.s4t.crossplane.io/v1alpha1
kind: Plugin
metadata:
  name: ${PLUGIN_NAME}
  namespace: default
spec:
  forProvider:
    name: "${PLUGIN_NAME}"
    code: |
      from iotronic_lightningrod.modules.plugins import Plugin
      from oslo_log import log as logging
      import time
      
      LOG = logging.getLogger(__name__)
      
      class Worker(Plugin.Plugin):
          def __init__(self, uuid, name, q_result=None, params=None):
              super(Worker, self).__init__(uuid, name, q_result, params)
              
          def run(self):
              LOG.info(f"Plugin {self.name} started")
              LOG.info(f"Input parameters: {self.params}")
              LOG.info("Plugin process completed!")
              if self.q_result:
                  self.q_result.put("SUCCESS")
    parameters: {}
  providerConfigRef:
    name: s4t-provider-domain
  deletionPolicy: Delete
EOF
    echo -e "${GREEN}Created plugin template at: $PLUGIN_YAML${NC}"
fi

echo ""
echo "=========================================="
echo "  CREATING PLUGIN: $PLUGIN_NAME"
echo "=========================================="
echo ""

echo "Applying plugin YAML..."
kubectl apply -f "$PLUGIN_YAML"

echo ""
echo "Waiting for plugin to be ready..."
kubectl wait --for=condition=Ready plugin/${PLUGIN_NAME} -n default --timeout=120s || {
    echo -e "${YELLOW}Plugin may still be creating. Check status with:${NC}"
    echo "  kubectl get plugin ${PLUGIN_NAME} -n default"
    echo "  kubectl describe plugin ${PLUGIN_NAME} -n default"
    exit 1
}

echo ""
echo "=========================================="
echo -e "${GREEN}Plugin created successfully!${NC}"
echo "=========================================="
echo ""

echo "Plugin status:"
kubectl get plugin ${PLUGIN_NAME} -n default

echo ""
echo "To view plugin details:"
echo "  kubectl describe plugin ${PLUGIN_NAME} -n default"
echo ""
echo "To inject plugin into a board, use:"
echo "  ./scripts/inject-plugin-to-board.sh <board-code> ${PLUGIN_NAME}"
