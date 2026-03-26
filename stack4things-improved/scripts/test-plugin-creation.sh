#!/bin/bash

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

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
echo "  TEST CREAZIONE PLUGIN"
echo "=========================================="
echo ""

PLUGIN_NAME="test-plugin-$(date +%s)"

echo "1. Creazione plugin: $PLUGIN_NAME"
cat <<EOF | kubectl apply -f -
apiVersion: iot.s4t.crossplane.io/v1alpha1
kind: Plugin
metadata:
  name: ${PLUGIN_NAME}
  namespace: default
spec:
  forProvider:
    name: "Test Plugin"
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
              while self._is_running:
                  LOG.info("Plugin running...")
                  time.sleep(5)
              LOG.info("Plugin stopped")
              if self.q_result:
                  self.q_result.put("SUCCESS")
    parameters:
      test: true
  providerConfigRef:
    name: s4t-provider-domain
  deletionPolicy: Delete
EOF

echo ""
echo "2. Attesa creazione plugin (60 secondi)..."
for i in {1..12}; do
    sleep 5
    STATUS=$(kubectl get plugin "$PLUGIN_NAME" -n default -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    SYNCED=$(kubectl get plugin "$PLUGIN_NAME" -n default -o jsonpath='{.status.conditions[?(@.type=="Synced")].status}' 2>/dev/null || echo "Unknown")
    echo "  [$i/12] Ready: $STATUS, Synced: $SYNCED"
    if [ "$STATUS" == "True" ] && [ "$SYNCED" == "True" ]; then
        echo -e "${GREEN}Plugin creato con successo!${NC}"
        break
    fi
done

echo ""
echo "3. Stato finale plugin:"
kubectl get plugin "$PLUGIN_NAME" -n default 2>&1 || true

echo ""
echo "4. Verifica nel database:"
DB_POD=$(kubectl get pod -n default -l io.kompose.service=iotronic-db -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$DB_POD" ]; then
    kubectl exec -n default "$DB_POD" -- mysql -uroot -ps4t iotronic -e "SELECT uuid, name FROM plugins WHERE name='Test Plugin';" 2>/dev/null || echo "Plugin non trovato nel database"
else
    echo "Database pod non trovato"
fi

echo ""
echo "5. Log Crossplane Provider:"
kubectl logs -n crossplane-system -l pkg.crossplane.io/provider=provider-s4t --tail=20 2>&1 | grep -i "plugin\|$PLUGIN_NAME" || echo "Nessun log rilevante"

echo ""
echo "=========================================="
echo "Test completato!"
echo "=========================================="
