#!/bin/bash

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RBAC_OPERATOR_DIR="$BASE_DIR/rbac-operator"

echo ""
echo "=========================================="
echo "  DEPLOYMENT RBAC OPERATOR"
echo "=========================================="
echo ""

TARGET_IMAGE_REPO="docker.io/mariorossi851234/s4t-rbac-operator:latest"
IMG="${IMG:-$TARGET_IMAGE_REPO}"
BUILD_IMAGE="${RBAC_OPERATOR_BUILD_IMAGE:-false}"

ensure_cert_manager() {
        if kubectl get crd certificates.cert-manager.io >/dev/null 2>&1 && \
             kubectl get crd issuers.cert-manager.io >/dev/null 2>&1; then
                echo -e "${GREEN}✔ cert-manager CRDs already present${NC}"
                return 0
        fi

        echo "0. Installazione cert-manager (dipendenza webhook RBAC Operator)..."
        if ! command -v helm >/dev/null 2>&1; then
                echo -e "${RED}ERROR: helm non disponibile, impossibile installare cert-manager${NC}"
                return 1
        fi

        helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
        helm repo update >/dev/null 2>&1 || true
        helm upgrade --install cert-manager jetstack/cert-manager \
            --namespace cert-manager --create-namespace \
            --set crds.enabled=true \
            --wait --timeout=5m || {
                echo -e "${RED}ERROR: installazione cert-manager fallita${NC}"
                return 1
            }

        kubectl wait --for=condition=Available deployment/cert-manager -n cert-manager --timeout=300s >/dev/null 2>&1 || true
        kubectl wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=300s >/dev/null 2>&1 || true
        kubectl wait --for=condition=Available deployment/cert-manager-cainjector -n cert-manager --timeout=300s >/dev/null 2>&1 || true

        if ! kubectl get crd certificates.cert-manager.io >/dev/null 2>&1; then
                echo -e "${RED}ERROR: cert-manager CRD certificates.cert-manager.io non trovata${NC}"
                return 1
        fi
        echo -e "${GREEN}✔ cert-manager pronto${NC}"
}

# Configurazione kubeconfig
if [ -f /etc/rancher/k3s/k3s.yaml ]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
elif [ -f /etc/rancher/k3s/k3s.yaml_backup ]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml_backup
else
    echo -e "${RED}ERROR: kubeconfig not found${NC}"
    exit 1
fi

# Verificare che il repository rbac-operator esista
if [ ! -d "$RBAC_OPERATOR_DIR" ]; then
    echo -e "${RED}ERROR: Directory rbac-operator non trovata in $RBAC_OPERATOR_DIR${NC}"
    exit 1
fi

cd "$RBAC_OPERATOR_DIR"

ensure_cert_manager || exit 1

# 1. Installare CRDs
echo "1. Installazione CRDs RBAC Operator..."
make install || {
    echo -e "${YELLOW}⚠️  Make install fallito, provo installazione diretta CRD...${NC}"
    kubectl apply -f config/crd/bases/s4t.s4t.io_projects.yaml || {
        echo -e "${RED}ERROR: Impossibile installare CRD${NC}"
        exit 1
    }
}
echo -e "${GREEN}✔ CRDs installate${NC}"

# 2. Build e push immagine (opzionale)
echo "2. Build immagine RBAC Operator..."
if [ "$BUILD_IMAGE" = "true" ]; then
    if command -v docker &> /dev/null; then
        echo "Building image: $IMG"
        make docker-build IMG="$IMG" || {
            echo -e "${YELLOW}⚠️  Build Docker fallito, uso immagine pre-esistente${NC}"
        }

        echo "Pushing image: $IMG"
        make docker-push IMG="$IMG" || echo -e "${YELLOW}⚠️  Push fallito (verifica docker login e permessi registry)${NC}"
    else
        echo -e "${YELLOW}⚠️  Docker non disponibile, uso immagine pre-esistente${NC}"
    fi
else
    echo "Skipping build/push locale (RBAC_OPERATOR_BUILD_IMAGE=false)."
    echo "Using remote image: $IMG"
fi

# 3. Deploy RBAC Operator
echo "3. Deploy RBAC Operator..."
if [ -f "dist/install.yaml" ]; then
    # Usa il bundle pre-generato se disponibile
    kubectl apply -f dist/install.yaml
else
    # Altrimenti usa make deploy
    make deploy IMG="${IMG:-$TARGET_IMAGE_REPO}" || {
        echo -e "${YELLOW}⚠️  Make deploy fallito, provo deploy fallback con kustomize build...${NC}"
        if [ -x "bin/kustomize" ]; then
            (cd config/manager && "$RBAC_OPERATOR_DIR/bin/kustomize" edit set image controller="${IMG:-$TARGET_IMAGE_REPO}")
            "$RBAC_OPERATOR_DIR/bin/kustomize" build config/default | kubectl apply -f -
        elif command -v kustomize >/dev/null 2>&1; then
            (cd config/manager && kustomize edit set image controller="${IMG:-$TARGET_IMAGE_REPO}")
            kustomize build config/default | kubectl apply -f -
        else
            kubectl kustomize config/default | kubectl apply -f -
        fi
    }
fi

# 4. Attendere che l'operator sia ready
echo "4. Attesa RBAC Operator ready..."
kubectl wait --for=condition=available deployment/s4t-rbac-operator-controller-manager -n s4t-rbac-operator-system --timeout=300s || {
    echo -e "${YELLOW}⚠️  Timeout attesa operator, verificare manualmente${NC}"
}

# 5. Creare ClusterRole e ClusterRoleBinding per project-creator
echo "5. Creazione ClusterRole per project-creator..."
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: s4t-project-creator
rules:
- apiGroups: ["s4t.s4t.io"]
  resources: ["projects"]
  verbs: ["create","get","patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: s4t-project-creator-binding
subjects:
- kind: Group
  name: s4t:project-creator
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: s4t-project-creator
  apiGroup: rbac.authorization.k8s.io
EOF

echo -e "${GREEN}✔ ClusterRole e ClusterRoleBinding creati${NC}"

echo ""
echo "=========================================="
echo -e "${GREEN}✅ RBAC OPERATOR DEPLOYATO!${NC}"
echo "=========================================="
echo ""
echo "Per verificare lo stato:"
echo "  kubectl get pods -n s4t-rbac-operator-system"
echo "  kubectl get projects.s4t.s4t.io"
echo ""