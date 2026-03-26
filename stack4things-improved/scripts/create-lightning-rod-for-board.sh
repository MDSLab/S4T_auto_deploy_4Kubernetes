#!/bin/bash

# Script per creare Lightning Rod per una board specifica
# Configura settings.json con board_code e URL WSS di Crossbar

set -euo pipefail

# Colori
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Verifica argomenti
if [ $# -lt 1 ]; then
    echo -e "${RED}Usage: $0 <BOARD_CODE> [BOARD_UUID]${NC}"
    echo ""
    echo "Esempio:"
    echo "  $0 TEST-BOARD-123"
    echo "  $0 TEST-BOARD-123 550e8400-e29b-41d4-a716-446655440000"
    exit 1
fi

BOARD_CODE="$1"
BOARD_UUID="${2:-}"

# Configurazione kubeconfig
if [ -f /etc/rancher/k3s/k3s.yaml ]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
elif [ -f /etc/rancher/k3s/k3s.yaml_backup ]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml_backup
else
    echo -e "${RED}ERROR: kubeconfig not found${NC}"
    exit 1
fi

# Configurazione servizi
CROSSBAR_SERVICE="crossbar.default.svc.cluster.local"
CROSSBAR_PORT="8181"
WSS_URL="wss://${CROSSBAR_SERVICE}:${CROSSBAR_PORT}/"
WAMP_REALM="s4t"

echo ""
echo "=========================================="
echo "  CREAZIONE LIGHTNING ROD PER BOARD"
echo "=========================================="
echo ""
echo "Board Code: $BOARD_CODE"
if [ -n "$BOARD_UUID" ]; then
    echo "Board UUID: $BOARD_UUID"
fi
echo "WSS URL: $WSS_URL"
echo "WAMP Realm: $WAMP_REALM"
echo ""

# Nota: UUID non viene incluso nel settings.json
# L'UUID verrà aggiunto dal cloud alla prima connessione di Lightning Rod
echo "Nota: UUID verrà aggiunto dal cloud alla prima connessione"

# Crea il deployment YAML
# Converti BOARD_CODE in lowercase per il nome del deployment (Kubernetes requirement)
DEPLOYMENT_NAME=$(echo "lightning-rod-${BOARD_CODE}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-\|-$//g')
echo ""
echo "Creazione deployment Lightning Rod..."
echo "Nome deployment: $DEPLOYMENT_NAME"

cat > /tmp/lightning-rod-${BOARD_CODE}.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOYMENT_NAME}
  namespace: default
  labels:
    board-code: "${BOARD_CODE}"
    app: lightning-rod
spec:
  replicas: 1
  selector:
    matchLabels:
      board-code: "${BOARD_CODE}"
  template:
    metadata:
      labels:
        board-code: "${BOARD_CODE}"
        app: lightning-rod
    spec:
      containers:
      - name: lightning-rod
        image: lucadagati/lrod:compose
        ports:
        - containerPort: 1474
          protocol: TCP
        securityContext:
          privileged: true
        stdin: true
        tty: true
        command:
          - /bin/bash
          - -c
        args:
          - |
            set -x
            
            # Crea directory necessarie
            mkdir -p /var/lib/iotronic
            mkdir -p /etc/iotronic
            
            # Crea iotronic.conf PRIMA di qualsiasi altra operazione
            cat > /etc/iotronic/iotronic.conf <<'IOTRONIC_EOF'
            [DEFAULT]
            lightningrod_home = /var/lib/iotronic
            skip_cert_verify = True
            
            log_level = info
            log_file = /var/log/iotronic/lightning-rod.log
            log_rotation_type = size
            max_logfile_size_mb = 5
            max_logfile_count = 3
            
            [services]
            wstun_bin = /usr/bin/wstun
            
            [webservices]
            proxy = nginx
            
            [autobahn]
            connection_timer = 30
            alive_timer = 600
            rpc_alive_timer = 10
            connection_failure_timer = 300
            
            [wamp]
            wamp_transport_url = ${WSS_URL}
            wamp_realm = ${WAMP_REALM}
            IOTRONIC_EOF
            chmod 644 /etc/iotronic/iotronic.conf
            
            # Crea settings.json con board_code (registration token) e URL WSS di Crossbar
            # L'UUID verrà aggiunto dal cloud alla prima connessione
            cat > /etc/iotronic/settings.json <<SETTINGS_EOF
            {
                "iotronic": {
                    "board": {
                        "code": "${BOARD_CODE}"
                    },
                    "wamp": {
                        "registration-agent": {
                            "url": "${WSS_URL}",
                            "realm": "${WAMP_REALM}"
                        }
                    }
                }
            }
            SETTINGS_EOF
            chmod 644 /etc/iotronic/settings.json
            
            # Copia in /var/lib/iotronic per compatibilità
            cp /etc/iotronic/settings.json /var/lib/iotronic/settings.json
            chmod 644 /var/lib/iotronic/settings.json
            
            # Fix per wstun_ip
            sed -i 's|self\.wstun_ip *= *urlparse(board\.wamp_config\["url"\])\[1\]\.split('\'':'\'')\[0\]|self.wstun_ip = "iotronic-wstun"|' /usr/local/lib/python3*/site-packages/iotronic_lightningrod/modules/service_manager.py
            
            # Verifica configurazione
            echo "[INFO] Configurazione completata:"
            echo "[INFO] iotronic.conf:"
            cat /etc/iotronic/iotronic.conf | grep -A 3 "\[wamp\]"
            echo "[INFO] settings.json:"
            cat /etc/iotronic/settings.json
            
            # Avvia Lightning Rod
            exec startLR
      restartPolicy: Always
EOF

# Converti BOARD_CODE in lowercase per il nome del deployment
DEPLOYMENT_NAME=$(echo "lightning-rod-${BOARD_CODE}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-\|-$//g')

# Verifica se il deployment esiste già
if kubectl get deployment ${DEPLOYMENT_NAME} -n default >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠️  Deployment già esistente per $BOARD_CODE${NC}"
    echo "Eliminazione deployment esistente..."
    kubectl delete deployment ${DEPLOYMENT_NAME} -n default 2>&1 | grep -v "Warning" || true
    sleep 5
fi

# Applica il deployment
echo "Applicazione deployment..."
kubectl apply -f /tmp/lightning-rod-${BOARD_CODE}.yaml

echo ""
echo "Attesa che il pod sia Ready..."
kubectl wait --for=condition=Ready pod -n default -l board-code="${BOARD_CODE}" --timeout=120s 2>&1 || true

echo ""
echo "=========================================="
echo "  VERIFICA"
echo "=========================================="
echo ""

sleep 5

# Verifica pod
POD_NAME=$(kubectl get pod -n default -l board-code="${BOARD_CODE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "$POD_NAME" ]; then
    echo -e "${GREEN}✅ Pod creato: $POD_NAME${NC}"
    echo ""
    echo "Verifica settings.json nel pod:"
    kubectl exec -n default "$POD_NAME" -- cat /etc/iotronic/settings.json 2>&1 | jq '.' || kubectl exec -n default "$POD_NAME" -- cat /etc/iotronic/settings.json 2>&1
    echo ""
    echo "Log Lightning Rod (ultime 10 righe):"
    kubectl logs -n default "$POD_NAME" --tail=10 2>&1 | tail -10
else
    echo -e "${YELLOW}⚠️  Pod non trovato${NC}"
fi

echo ""
echo "=========================================="
echo -e "${GREEN}✅ COMPLETATO${NC}"
echo "=========================================="
echo ""
echo "Lightning Rod creato per board: $BOARD_CODE"
echo ""
echo "Per vedere i log:"
echo "  kubectl logs -n default -l board-code=$BOARD_CODE -f"
echo ""
