#!/bin/bash

################################################################################
# Stack4Things Complete Automated Setup Script
# 
# This script automates the entire Stack4Things deployment from scratch:
# 1. Installs k3s (if not present)
# 2. Installs Helm and required tools
# 3. Generates TLS certificates for Keycloak/Crossbar
# 4. Creates necessary ConfigMaps
# 5. Deploys the complete stack (MetalLB, Istio, Stack4Things, Keycloak, Keystone, Crossplane)
# 6. Verifies the deployment
#
# Usage: ./setup-all.sh [--skip-k3s] [--skip-helm] [--help]
################################################################################

set -euo pipefail

### Colors ###
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

### Utility: show title section ###
section() {
  echo ""
  echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
  echo -e "${BLUE}  $1${NC}"
  echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
}

step() {
  echo ""
  echo -e "${YELLOW}▶ STEP $1: $2${NC}"
}

ok() {
  echo -e "${GREEN}✔${NC} $1"
}

warn() {
  echo -e "${YELLOW}⚠️${NC} $1"
}

fail() {
  echo -e "${RED}✖ ERROR: $1${NC}"
  exit 1
}

### Parse command line arguments ###
SKIP_K3S=false
SKIP_HELM=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --skip-k3s)
      SKIP_K3S=true
      shift
      ;;
    --skip-helm)
      SKIP_HELM=true
      shift
      ;;
    --help)
      echo "Usage: ./setup-all.sh [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --skip-k3s    Skip k3s installation (use existing cluster)"
      echo "  --skip-helm   Skip Helm installation (use existing Helm)"
      echo "  --help        Show this help message"
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
done

### Determine script directories ###
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK4THINGS_DIR="${SCRIPT_DIR}/../stack4things-improved"
DEPLOY_SCRIPT="${STACK4THINGS_DIR}/deploy-complete-improved.sh"
PREFLIGHT_SCRIPT="${STACK4THINGS_DIR}/scripts/preflight-deploy.sh"
KEYCLOAK_KEYSTONE_DIR="${STACK4THINGS_DIR}/keycloak-keystone-integration"
KEYSTONE_CONFIG_DIR="${KEYCLOAK_KEYSTONE_DIR}/keystone-config"
KEYCLOAK_CONFIG_DIR="${KEYCLOAK_KEYSTONE_DIR}/keycloak-config"

ENV_FILE="${SCRIPT_DIR}/../.env"
if [ ! -f "$ENV_FILE" ]; then
  fail "ERROR: .env not found at: $ENV_FILE"
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

if ! command -v envsubst >/dev/null 2>&1; then
  fail "ERROR: envsubst not found (install gettext-base)"
fi

### Validate repository structure ###
section "Validating Repository Structure"

if [ ! -f "$DEPLOY_SCRIPT" ]; then
  fail "Deploy script not found at: $DEPLOY_SCRIPT"
fi
ok "Found deploy script: $DEPLOY_SCRIPT"

if [ ! -d "$STACK4THINGS_DIR/yaml_file" ]; then
  fail "yaml_file directory not found at: $STACK4THINGS_DIR/yaml_file"
fi
ok "Found yaml_file directory"

if [ ! -d "$STACK4THINGS_DIR/istioconf" ]; then
  fail "istioconf directory not found at: $STACK4THINGS_DIR/istioconf"
fi
ok "Found istioconf directory"

if [ ! -d "$STACK4THINGS_DIR/scripts" ]; then
  fail "scripts directory not found at: $STACK4THINGS_DIR/scripts"
fi
ok "Found scripts directory"

### Step 1: Install k3s (if needed) ###
if [ "$SKIP_K3S" = false ]; then
  section "Installing k3s (Lightweight Kubernetes)"
  
  if command -v k3s &>/dev/null || command -v kubectl &>/dev/null; then
    ok "k3s or kubectl already installed, skipping k3s installation"
  else
    step "1" "Downloading and installing k3s from get.k3s.io"
    curl -sfL https://get.k3s.io | sh - || fail "k3s installation failed"
    ok "k3s installed successfully"
    
    # Set kubeconfig permissions
    if [ -f /etc/rancher/k3s/k3s.yaml ]; then
      sudo chmod 644 /etc/rancher/k3s/k3s.yaml || warn "Could not set kubeconfig permissions"
      ok "kubeconfig permissions set"
    fi
    
    # Give k3s a moment to start
    sleep 5
    
    # Wait for k3s to be ready
    step "1" "Waiting for k3s cluster to be ready..."
    for i in {1..30}; do
      if kubectl cluster-info &>/dev/null 2>&1; then
        ok "k3s cluster is ready"
        break
      fi
      if [ $i -eq 30 ]; then
        fail "k3s cluster did not become ready within 2.5 minutes"
      fi
      echo -n "."
      sleep 5
    done
  fi
else
  ok "Skipping k3s installation (--skip-k3s flag used)"
fi

### Step 2: Ensure kubeconfig is set ###
section "Configuring Kubernetes Access"

if [ -f /etc/rancher/k3s/k3s.yaml ]; then
  export KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
  ok "Using kubeconfig: /etc/rancher/k3s/k3s.yaml"
elif [ -f ~/.kube/config ]; then
  export KUBECONFIG=~/.kube/config
  ok "Using kubeconfig: ~/.kube/config"
else
  fail "No kubeconfig found. Please configure Kubernetes access manually."
fi

### Verify cluster connectivity ###
step "2" "Verifying cluster connectivity..."
if ! kubectl cluster-info &>/dev/null 2>&1; then
  fail "Cannot connect to Kubernetes cluster. Check KUBECONFIG and cluster status."
fi
ok "Kubernetes cluster is accessible"

### Step 3: Install Helm (if needed) ###
if [ "$SKIP_HELM" = false ]; then
  section "Installing Helm (Kubernetes Package Manager)"
  
  if command -v helm &>/dev/null; then
    HELM_VERSION=$(helm version --short 2>/dev/null | head -1 || echo "")
    ok "Helm is already installed: $HELM_VERSION"
  else
    step "3" "Installing Helm from get.helm.sh..."
    curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod 700 /tmp/get_helm.sh
    /tmp/get_helm.sh || fail "Helm installation failed"
    rm -f /tmp/get_helm.sh
    ok "Helm installed successfully"
  fi
else
  ok "Skipping Helm installation (--skip-helm flag used)"
fi

### Step 4: Generate TLS Certificates ###
section "Generating TLS Certificates for Keycloak and Crossbar"

CERTS_DIR="${KEYCLOAK_CONFIG_DIR}/certs"
mkdir -p "$CERTS_DIR"

# Check if certificates already exist
if [ -f "${CERTS_DIR}/keycloak.key" ] && [ -f "${CERTS_DIR}/keycloak.pem" ]; then
  ok "Keycloak certificates already exist, skipping generation"
else
  step "4" "Generating Keycloak CA and certificates..."
  
  # Generate CA key and certificate
  openssl genrsa -out "${CERTS_DIR}/iotronic_CA.key" 2048 2>/dev/null || fail "Failed to generate CA key"
  openssl req -new -x509 -days 365 -key "${CERTS_DIR}/iotronic_CA.key" \
    -out "${CERTS_DIR}/iotronic_CA.pem" \
    -subj "/C=IT/ST=State/L=City/O=Stack4Things/CN=iotronic-ca" 2>/dev/null || fail "Failed to generate CA certificate"
  
  # Generate Keycloak key
  openssl genrsa -out "${CERTS_DIR}/keycloak.key" 2048 2>/dev/null || fail "Failed to generate Keycloak key"
  
  # Generate Keycloak CSR
  openssl req -new -key "${CERTS_DIR}/keycloak.key" \
    -out "${CERTS_DIR}/keycloak.csr" \
    -subj "/C=IT/ST=State/L=City/O=Stack4Things/CN=keycloak.default.svc.cluster.local" 2>/dev/null || fail "Failed to generate Keycloak CSR"
  
  # Sign Keycloak certificate
  openssl x509 -req -in "${CERTS_DIR}/keycloak.csr" \
    -CA "${CERTS_DIR}/iotronic_CA.pem" \
    -CAkey "${CERTS_DIR}/iotronic_CA.key" \
    -CAcreateserial -out "${CERTS_DIR}/keycloak.pem" \
    -days 365 -extfile <(printf "subjectAltName=DNS:keycloak.default.svc.cluster.local,DNS:keycloak") 2>/dev/null || fail "Failed to sign Keycloak certificate"
  
  # Generate Crossbar key and certificate
  openssl genrsa -out "${CERTS_DIR}/crossbar.key" 2048 2>/dev/null || fail "Failed to generate Crossbar key"
  
  openssl req -new -key "${CERTS_DIR}/crossbar.key" \
    -out "${CERTS_DIR}/crossbar.csr" \
    -subj "/C=IT/ST=State/L=City/O=Stack4Things/CN=crossbar.default.svc.cluster.local" 2>/dev/null || fail "Failed to generate Crossbar CSR"
  
  openssl x509 -req -in "${CERTS_DIR}/crossbar.csr" \
    -CA "${CERTS_DIR}/iotronic_CA.pem" \
    -CAkey "${CERTS_DIR}/iotronic_CA.key" \
    -CAcreateserial -out "${CERTS_DIR}/crossbar.pem" \
    -days 365 -extfile <(printf "subjectAltName=DNS:crossbar.default.svc.cluster.local,DNS:crossbar") 2>/dev/null || fail "Failed to sign Crossbar certificate"
  
  # Clean up CSR files
  rm -f "${CERTS_DIR}"/*.csr "${CERTS_DIR}"/*.srl
  
  ok "TLS certificates generated successfully"
  ok "Certificates location: $CERTS_DIR"
fi

### Step 5: Create Keycloak ConfigMaps ###
section "Creating Keycloak ConfigMaps"

if kubectl get configmap -n default keycloak-certs &>/dev/null; then
  ok "keycloak-certs ConfigMap already exists, skipping"
else
  step "5" "Creating keycloak-certs ConfigMap..."
  kubectl create configmap keycloak-certs \
    --from-file="${CERTS_DIR}/keycloak.key" \
    --from-file="${CERTS_DIR}/keycloak.pem" \
    --from-file="keycloak.crt=${CERTS_DIR}/keycloak.pem" \
    --from-file="${CERTS_DIR}/iotronic_CA.pem" \
    -n default 2>/dev/null || fail "Failed to create keycloak-certs ConfigMap"
  ok "keycloak-certs ConfigMap created"
fi

# Ensure the same certs configmap exists in keycloak namespace for Keycloak deployment mounts
kubectl create namespace keycloak --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 || true
if kubectl get configmap -n keycloak keycloak-certs &>/dev/null; then
  ok "keycloak-certs ConfigMap already exists in keycloak namespace, skipping"
else
  step "5" "Creating keycloak-certs ConfigMap in keycloak namespace..."
  kubectl create configmap keycloak-certs \
    --from-file="${CERTS_DIR}/keycloak.key" \
    --from-file="${CERTS_DIR}/keycloak.pem" \
    --from-file="keycloak.crt=${CERTS_DIR}/keycloak.pem" \
    --from-file="${CERTS_DIR}/iotronic_CA.pem" \
    -n keycloak 2>/dev/null || fail "Failed to create keycloak-certs ConfigMap in keycloak namespace"
  ok "keycloak-certs ConfigMap created in keycloak namespace"
fi

# Create realm config if it doesn't exist
REALM_FILE="${KEYCLOAK_CONFIG_DIR}/stack4things-realm.json"
if [ ! -f "$REALM_FILE" ]; then
  step "5" "Creating Keycloak realm configuration..."
  mkdir -p "$(dirname "$REALM_FILE")"
  cat > "$REALM_FILE" << EOF
{
  "realm": "stack4things",
  "enabled": true,
  "clients": [
    {
      "clientId": "kubernetes",
      "enabled": true,
      "protocol": "openid-connect",
      "publicClient": false,
      "standardFlowEnabled": true,
      "directAccessGrantsEnabled": true,
      "redirectUris": ["*"],
      "webOrigins": ["*"]
    }
  ],
  "users": [
    {
      "username": "${KEYCLOAK_ADMIN_USERNAME}",
      "enabled": true,
      "emailVerified": true,
      "credentials": [
        {
          "type": "password",
          "value": "${KEYCLOAK_ADMIN_PASSWORD}"
        }
      ],
      "realmRoles": ["default-roles-stack4things", "offline_access", "uma_authorization"]
    }
  ]
}
EOF
  ok "Keycloak realm configuration created"
fi

if kubectl get configmap -n default keycloak-realm-config &>/dev/null; then
  ok "keycloak-realm-config ConfigMap already exists, skipping"
else
  step "5" "Creating keycloak-realm-config ConfigMap..."
  kubectl create configmap keycloak-realm-config \
    --from-file="${REALM_FILE}" \
    -n default 2>/dev/null || fail "Failed to create keycloak-realm-config ConfigMap"
  ok "keycloak-realm-config ConfigMap created"
fi

# Ensure realm configmap exists in keycloak namespace as well
if kubectl get configmap -n keycloak keycloak-realm-config &>/dev/null; then
  ok "keycloak-realm-config ConfigMap already exists in keycloak namespace, skipping"
else
  step "5" "Creating keycloak-realm-config ConfigMap in keycloak namespace..."
  kubectl create configmap keycloak-realm-config \
    --from-file="${REALM_FILE}" \
    -n keycloak 2>/dev/null || fail "Failed to create keycloak-realm-config ConfigMap in keycloak namespace"
  ok "keycloak-realm-config ConfigMap created in keycloak namespace"
fi

### Step 6: Create Keystone ConfigMaps ###
section "Creating Keystone ConfigMaps"

kubectl create namespace keystone --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 || true

create_keystone_configmap() {
  local cm_name="$1"
  local cm_file="$2"

  if [ ! -f "$cm_file" ]; then
    warn "${cm_name} source file not found at $cm_file, skipping"
    return
  fi

  for ns in default keystone; do
    if kubectl get configmap -n "$ns" "$cm_name" &>/dev/null; then
      ok "${cm_name} ConfigMap already exists in ${ns} namespace, skipping"
    else
      step "6" "Creating ${cm_name} ConfigMap in ${ns} namespace..."
      kubectl create configmap "$cm_name" \
        --from-file="$cm_file" \
        -n "$ns" 2>/dev/null || fail "Failed to create ${cm_name} ConfigMap in ${ns} namespace"
      ok "${cm_name} ConfigMap created in ${ns} namespace"
    fi
  done
}

RENDERED_KEYSTONE_DIR="${SCRIPT_DIR}/.tmp/rendered-keystone-config"
mkdir -p "$RENDERED_KEYSTONE_DIR"

KEYSTONE_ENV_SUBST_VARS='$KEYSTONE_DB_HOST $KEYSTONE_DB_NAME $KEYSTONE_DB_USER $KEYSTONE_DB_PASSWORD $OIDC_CLIENT_SECRET $OIDC_CRYPTO_PASSPHRASE'
envsubst "$KEYSTONE_ENV_SUBST_VARS" < "${KEYSTONE_CONFIG_DIR}/keystone.conf" > "${RENDERED_KEYSTONE_DIR}/keystone.conf"
envsubst "$KEYSTONE_ENV_SUBST_VARS" < "${KEYSTONE_CONFIG_DIR}/wsgi-keystone.conf" > "${RENDERED_KEYSTONE_DIR}/wsgi-keystone.conf"

create_keystone_configmap "keystone-config" "${RENDERED_KEYSTONE_DIR}/keystone.conf"
create_keystone_configmap "keystone-mapping" "${KEYSTONE_CONFIG_DIR}/keystone-mapping.json"
create_keystone_configmap "keystone-sso" "${KEYSTONE_CONFIG_DIR}/sso_callback.html"
create_keystone_configmap "keystone-wsgi" "${RENDERED_KEYSTONE_DIR}/wsgi-keystone.conf"

### Step 7: Run Preflight Checks ###
section "Running Pre-Deployment Checks"

if [ -x "$PREFLIGHT_SCRIPT" ]; then
  step "7" "Executing preflight checks..."
  if "$PREFLIGHT_SCRIPT"; then
    ok "All pre-flight checks passed"
  else
    warn "Some pre-flight warnings detected (non-blocking)"
  fi
else
  warn "Preflight script not executable, skipping checks"
fi

### Step 8: Create Crossplane ConfigMaps for Certificates ###
section "Preparing Crossbar SSL Certificates"

# Create ConfigMap for SSL certificates in default namespace
SSL_CONFIGMAP_NAME="iotronic-ssl-certs"
if kubectl get configmap -n default "$SSL_CONFIGMAP_NAME" &>/dev/null; then
  ok "SSL certificates ConfigMap already exists"
else
  step "8" "Creating SSL certificates ConfigMap for Crossbar..."
  kubectl create configmap "$SSL_CONFIGMAP_NAME" \
    --from-file="${CERTS_DIR}/crossbar.key" \
    --from-file="${CERTS_DIR}/crossbar.pem" \
    --from-file="${CERTS_DIR}/iotronic_CA.pem" \
    -n default 2>/dev/null || fail "Failed to create SSL ConfigMap"
  ok "SSL certificates ConfigMap created"
fi

### Step 9: Run Main Deployment Script ###
section "Deploying Stack4Things Complete Stack"

step "9" "Executing deploy script: $DEPLOY_SCRIPT"
if ! (cd "$STACK4THINGS_DIR" && bash "$DEPLOY_SCRIPT"); then
  fail "Main deployment script failed"
fi
ok "Main deployment completed"

### Step 10: Post-Deployment SSL Certificate Setup (Crossbar) ###
section "Post-Deployment: Fixing Crossbar SSL Certificates"

step "10" "Waiting for iotronic-ssl PVC to be available..."
for i in {1..30}; do
  if kubectl get pvc iotronic-ssl -n default &>/dev/null; then
    ok "iotronic-ssl PVC is available"
    break
  fi
  if [ $i -eq 30 ]; then
    warn "iotronic-ssl PVC not found within 2.5 minutes (may be normal)"
  fi
  echo -n "."
  sleep 5
done

# Create helper pod to copy SSL certs if PVC exists
if kubectl get pvc iotronic-ssl -n default &>/dev/null; then
  step "10" "Creating helper pod to setup SSL certificates in PVC..."
  
  # Create SSL fixer pod
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ssl-fixer
  namespace: default
spec:
  containers:
  - name: setup
    image: busybox
    command: ['sh', '-c', 'while true; do sleep 3600; done']
    volumeMounts:
    - name: ssl
      mountPath: /ssl
  volumes:
  - name: ssl
    persistentVolumeClaim:
      claimName: iotronic-ssl
  restartPolicy: Never
EOF
  
  # Wait for helper pod to be ready
  sleep 10
  for i in {1..20}; do
    if kubectl get pod ssl-fixer -n default -o jsonpath='{.status.phase}' 2>/dev/null | grep -q "Running"; then
      ok "SSL fixer pod is running"
      break
    fi
    echo -n "."
    sleep 3
  done
  
  # Copy certificates into PVC
  step "10" "Copying SSL certificates to PVC..."
  kubectl cp "${CERTS_DIR}/crossbar.key" default/ssl-fixer:/ssl/crossbar.key 2>/dev/null || warn "Could not copy crossbar.key"
  kubectl cp "${CERTS_DIR}/crossbar.pem" default/ssl-fixer:/ssl/crossbar.pem 2>/dev/null || warn "Could not copy crossbar.pem"
  kubectl cp "${CERTS_DIR}/iotronic_CA.pem" default/ssl-fixer:/ssl/iotronic_CA.pem 2>/dev/null || warn "Could not copy iotronic_CA.pem"
  
  # Fix permissions
  step "10" "Fixing file permissions in PVC..."
  kubectl exec -n default ssl-fixer -- chmod 644 /ssl/crossbar.key 2>/dev/null || warn "Could not fix crossbar.key permissions"
  kubectl exec -n default ssl-fixer -- chmod 644 /ssl/crossbar.pem 2>/dev/null || warn "Could not fix crossbar.pem permissions"
  kubectl exec -n default ssl-fixer -- chmod 644 /ssl/iotronic_CA.pem 2>/dev/null || warn "Could not fix CA permissions"
  
  # Delete helper pod
  kubectl delete pod ssl-fixer -n default 2>/dev/null || warn "Could not delete ssl-fixer pod"
  
  ok "SSL certificates installed and permissions fixed"
fi

### Step 11: Verify Deployment ###
section "Verifying Deployment Status"

step "11" "Checking pod status..."
echo ""
echo "📊 Stack4Things Pods:"
kubectl get pods -n default 2>/dev/null | grep -E "iotronic|keystone|crossbar|rabbitmq|keycloak" || warn "Some Stack4Things pods not found"

echo ""
echo "📊 Crossplane Status:"
kubectl get pods -n crossplane-system 2>/dev/null || warn "Crossplane not ready yet"

echo ""
echo "📊 Services:"
kubectl get svc -n istio-ingress 2>/dev/null || warn "Istio ingress not ready yet"

echo ""
echo "📊 Keycloak Status:"
kubectl get pods -n keycloak 2>/dev/null || echo "  (Keycloak namespace not yet created)"

echo ""
echo "📊 Keystone Status:"
kubectl get pods -n keystone 2>/dev/null || echo "  (Keystone namespace not yet created)"

### Step 12: Display Access Information ###
section "Deployment Complete"

echo ""
echo -e "${GREEN}✅ STACK4THINGS DEPLOYMENT COMPLETE!${NC}"
echo ""

# Get LoadBalancer IP
LB_IP=$(kubectl get svc istio-ingress -n istio-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")

if [ -n "$LB_IP" ]; then
  echo -e "${GREEN}Public LoadBalancer IP: ${YELLOW}http://$LB_IP/${NC}"
  echo -e "${GREEN}Access UI at: ${YELLOW}http://$LB_IP/horizon${NC}"
else
  NODE_PORT=$(kubectl get svc iotronic-ui-direct -n default -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "")
  if [ -n "$NODE_PORT" ]; then
    NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "localhost")
    echo -e "${GREEN}Direct NodePort Access: ${YELLOW}http://$NODE_IP:$NODE_PORT/horizon${NC}"
  fi
fi

echo ""
echo -e "${GREEN}Dashboard Credentials:${NC}"
echo "  Username: ${YELLOW}${STACK4THINGS_ADMIN_USER}${NC}"
echo "  Password: ${YELLOW}${STACK4THINGS_ADMIN_PASSWORD}${NC}"
echo ""

echo -e "${GREEN}Default Keycloak Credentials:${NC}"
echo "  Username: ${YELLOW}${KEYCLOAK_ADMIN_USERNAME}${NC}"
echo "  Password: ${YELLOW}${KEYCLOAK_ADMIN_PASSWORD}${NC}"
echo ""

echo -e "${GREEN}What's Next:${NC}"
echo "  1. Wait for all pods to be Running: ${YELLOW}kubectl get pods -n default${NC}"
echo "  2. Create Lightning Rods for boards"
echo "  3. Configure k3s OIDC integration (optional)"
echo "  4. Deploy custom resources using Crossplane"
echo ""

echo -e "${GREEN}Useful Commands:${NC}"
echo "  Check pod logs:        ${YELLOW}kubectl logs -f -n default <pod-name>${NC}"
echo "  Port-forward to UI:    ${YELLOW}kubectl port-forward -n default svc/iotronic-ui 8070:80${NC}"
echo "  Exec into pod:         ${YELLOW}kubectl exec -it -n default <pod-name> -- bash${NC}"
echo "  Check service status:  ${YELLOW}kubectl get svc -n default${NC}"
echo ""

echo -e "${GREEN}Documentation:${NC}"
echo "  README: ${YELLOW}${STACK4THINGS_DIR}/README.md${NC}"
echo "  Scripts: ${YELLOW}${STACK4THINGS_DIR}/scripts/${NC}"
echo ""

exit 0
