#!/bin/bash

################################################################################
# Stack4Things Deployment Verification Script
# 
# This script checks the status of the Stack4Things deployment and provides
# diagnostic information and troubleshooting guidance.
#
# Usage: ./verify-deployment.sh
################################################################################

set -euo pipefail

### Colors ###
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

### Counters ###
HEALTHY=0
WARNINGS=0
FAILURES=0

### Utility functions ###
section() {
  echo ""
  echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
  echo -e "${BLUE}  $1${NC}"
  echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
}

ok() {
  echo -e "${GREEN}✔${NC} $1"
  HEALTHY=$((HEALTHY + 1))
}

warn() {
  echo -e "${YELLOW}⚠${NC} $1"
  WARNINGS=$((WARNINGS + 1))
}

fail() {
  echo -e "${RED}✗${NC} $1"
  FAILURES=$((FAILURES + 1))
}

### Check kubeconfig ###
section "Kubernetes Configuration"

if [ -z "${KUBECONFIG:-}" ]; then
  if [ -f /etc/rancher/k3s/k3s.yaml ]; then
    export KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
    ok "KUBECONFIG set to: /etc/rancher/k3s/k3s.yaml"
  elif [ -f ~/.kube/config ]; then
    export KUBECONFIG="~/.kube/config"
    ok "KUBECONFIG set to: ~/.kube/config"
  else
    fail "No kubeconfig found. Cannot proceed."
    exit 1
  fi
else
  ok "KUBECONFIG is set: $KUBECONFIG"
fi

### Check cluster connectivity ###
section "Cluster Connectivity"

if kubectl cluster-info &>/dev/null; then
  ok "Kubernetes cluster is reachable"
  CLUSTER_INFO=$(kubectl cluster-info 2>/dev/null | head -1)
  ok "  $CLUSTER_INFO"
else
  fail "Cannot connect to Kubernetes cluster"
  exit 1
fi

### Check nodes ###
section "Node Status"

NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
if [ "$NODE_COUNT" -gt 0 ]; then
  ok "Found $NODE_COUNT node(s)"
  kubectl get nodes --no-headers 2>/dev/null | while read node rest; do
    STATUS=$(echo "$rest" | awk '{print $4}')
    if [ "$STATUS" = "Ready" ]; then
      echo -e "  ${GREEN}✔${NC} $node: Ready"
    else
      echo -e "  ${RED}✗${NC} $node: $STATUS"
    fi
  done
else
  fail "No nodes found"
fi

### Check namespaces ###
section "Kubernetes Namespaces"

REQUIRED_NAMESPACES=("default" "kube-system" "metallb-system" "istio-system" "istio-ingress" "crossplane-system")

for ns in "${REQUIRED_NAMESPACES[@]}"; do
  if kubectl get namespace "$ns" &>/dev/null; then
    ok "Namespace exists: $ns"
  else
    if [ "$ns" = "default" ] || [ "$ns" = "kube-system" ]; then
      fail "Critical namespace missing: $ns"
    else
      warn "Namespace not found: $ns (may not be needed)"
    fi
  fi
done

### Check Stack4Things Pods ###
section "Stack4Things Pods (default namespace)"

EXPECTED_PODS=("iotronic-db" "iotronic-conductor" "crossbar" "iotronic-wagent" "iotronic-ui" "rabbitmq")

for pod_label in "${EXPECTED_PODS[@]}"; do
  POD_COUNT=$(kubectl get pods -n default -l io.kompose.service="$pod_label" --no-headers 2>/dev/null | wc -l)
  
  if [ "$POD_COUNT" -gt 0 ]; then
    POD_NAME=$(kubectl get pods -n default -l io.kompose.service="$pod_label" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    STATUS=$(kubectl get pod -n default "$POD_NAME" -o jsonpath='{.status.phase}' 2>/dev/null)
    
    if [ "$STATUS" = "Running" ]; then
      READY=$(kubectl get pod -n default "$POD_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
      if [ "$READY" = "True" ]; then
        ok "$pod_label: Running"
      else
        warn "$pod_label: Running but not ready"
      fi
    else
      warn "$pod_label: $STATUS"
    fi
  else
    fail "No pod found for: $pod_label"
  fi
done

### Check Services ###
section "Stack4Things Services"

EXPECTED_SERVICES=("iotronic-conductor" "iotronic-ui" "crossbar" "rabbitmq" "iotronic-db" "keystone")

for svc in "${EXPECTED_SERVICES[@]}"; do
  if kubectl get svc -n default "$svc" &>/dev/null 2>&1; then
    ENDPOINTS=$(kubectl get endpoints -n default "$svc" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | wc -w)
    if [ "$ENDPOINTS" -gt 0 ]; then
      ok "Service available: $svc ($ENDPOINTS endpoint(s))"
    else
      warn "Service exists but has no endpoints: $svc"
    fi
  else
    warn "Service not found: $svc"
  fi
done

### Check LoadBalancer ###
section "Load Balancer & Ingress"

if kubectl get svc -n istio-ingress istio-ingress &>/dev/null 2>&1; then
  LB_IP=$(kubectl get svc istio-ingress -n istio-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  
  if [ -z "$LB_IP" ]; then
    warn "Istio ingress service exists but LoadBalancer IP not yet assigned"
    warn "  Status: $(kubectl get svc istio-ingress -n istio-ingress -o jsonpath='{.status.loadBalancer}' 2>/dev/null)"
  else
    ok "LoadBalancer IP assigned: $LB_IP"
    ok "  UI URL: http://$LB_IP/horizon"
  fi
else
  warn "Istio ingress service not found"
fi

### Check ConfigMaps ###
section "Keycloak & Keystone ConfigMaps"

REQUIRED_CONFIGMAPS=("keycloak-certs" "keycloak-realm-config" "keystone-config" "keystone-mapping" "keystone-sso" "keystone-wsgi")

for cm in "${REQUIRED_CONFIGMAPS[@]}"; do
  if kubectl get configmap -n default "$cm" &>/dev/null 2>&1; then
    ok "ConfigMap exists: $cm"
  else
    warn "ConfigMap not found: $cm"
  fi
done

### Check Keycloak Deployment ###
section "Keycloak & Keystone Status"

if kubectl get namespace keycloak &>/dev/null 2>&1; then
  KC_PODS=$(kubectl get pods -n keycloak --no-headers 2>/dev/null | wc -l)
  if [ "$KC_PODS" -gt 0 ]; then
    KC_READY=$(kubectl get pods -n keycloak -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -c "True" || echo "0")
    ok "Keycloak: $KC_READY/$KC_PODS pods ready"
  else
    warn "Keycloak namespace exists but no pods found"
  fi
else
  warn "Keycloak namespace not found"
fi

if kubectl get namespace keystone &>/dev/null 2>&1; then
  KS_PODS=$(kubectl get pods -n keystone --no-headers 2>/dev/null | wc -l)
  if [ "$KS_PODS" -gt 0 ]; then
    KS_READY=$(kubectl get pods -n keystone -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -c "True" || echo "0")
    ok "Keystone: $KS_READY/$KS_PODS pods ready"
  else
    warn "Keystone namespace exists but no pods found"
  fi
else
  warn "Keystone namespace not found"
fi

### Check Crossplane ###
section "Crossplane Status"

if kubectl get namespace crossplane-system &>/dev/null 2>&1; then
  CP_PODS=$(kubectl get pods -n crossplane-system --no-headers 2>/dev/null | wc -l)
  if [ "$CP_PODS" -gt 0 ]; then
    CP_READY=$(kubectl get pods -n crossplane-system -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -c "True" || echo "0")
    ok "Crossplane: $CP_READY/$CP_PODS pods ready"
  else
    warn "Crossplane namespace exists but no pods found"
  fi
else
  warn "Crossplane namespace not found"
fi

### Check Istio ###
section "Istio Status"

if kubectl get namespace istio-system &>/dev/null 2>&1; then
  ISTIO_PODS=$(kubectl get pods -n istio-system --no-headers 2>/dev/null | wc -l)
  if [ "$ISTIO_PODS" -gt 0 ]; then
    ISTIO_READY=$(kubectl get pods -n istio-system -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -c "True" || echo "0")
    ok "Istio: $ISTIO_READY/$ISTIO_PODS pods ready"
  else
    warn "Istio namespace exists but no pods found"
  fi
else
  warn "Istio system namespace not found"
fi

### Check MetalLB ###
section "MetalLB Status"

if kubectl get namespace metallb-system &>/dev/null 2>&1; then
  MLB_PODS=$(kubectl get pods -n metallb-system --no-headers 2>/dev/null | wc -l)
  if [ "$MLB_PODS" -gt 0 ]; then
    MLB_READY=$(kubectl get pods -n metallb-system -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -c "True" || echo "0")
    ok "MetalLB: $MLB_READY/$MLB_PODS pods ready"
  else
    warn "MetalLB namespace exists but no pods found"
  fi
else
  warn "MetalLB namespace not found"
fi

### Test API Connectivity ###
section "API Connectivity Tests"

# Test Conductor API
CONDUCTOR_SVC="iotronic-conductor.default.svc.cluster.local"
if kubectl exec -it $(kubectl get pods -n default -l io.kompose.service=iotronic-ui -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) -n default -- \
  wget -q -O /dev/null "http://$CONDUCTOR_SVC:8812/v1" 2>/dev/null; then
  ok "Conductor API (/v1) is reachable"
else
  warn "Could not reach Conductor API (may be normal if UI pod not ready)"
fi

### Display Access Information ###
section "How to Access Stack4Things"

echo ""
echo -e "${GREEN}Dashboard:${NC}"
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "localhost")
NODE_PORT=$(kubectl get svc iotronic-ui-direct -n default -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "31123")
echo "  URL: http://$NODE_IP:$NODE_PORT/horizon"
echo "  Username: admin"
echo "  Password: s4t"

LB_IP=$(kubectl get svc istio-ingress -n istio-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
if [ -n "$LB_IP" ]; then
  echo "  (or via LoadBalancer: http://$LB_IP/horizon)"
fi

echo ""
echo -e "${GREEN}Useful Commands:${NC}"
echo "  Check pod status:      kubectl get pods -n default"
echo "  View pod logs:         kubectl logs -f -n default <pod-name>"
echo "  Describe pod:          kubectl describe pod -n default <pod-name>"
echo "  Port-forward UI:       kubectl port-forward -n default svc/iotronic-ui 8070:80"
echo "  Check services:        kubectl get svc -n default"
echo "  Watch deployment:      kubectl get pods -n default -w"

### Summary ###
section "Verification Summary"

TOTAL=$((HEALTHY + WARNINGS + FAILURES))
echo ""
echo -e "${GREEN}✓ Healthy:  $HEALTHY${NC}"
echo -e "${YELLOW}⚠ Warnings: $WARNINGS${NC}"
echo -e "${RED}✗ Failures: $FAILURES${NC}"
echo ""

if [ "$FAILURES" -eq 0 ]; then
  if [ "$WARNINGS" -eq 0 ]; then
    echo -e "${GREEN}✅ DEPLOYMENT LOOKS GOOD!${NC}"
    echo ""
    echo "All critical components are present and healthy."
    echo "You should be able to access the dashboard now."
    exit 0
  else
    echo -e "${YELLOW}⚠️  DEPLOYMENT IS MOSTLY OKAY${NC}"
    echo ""
    echo "Some components may still be starting up. Wait a few moments"
    echo "and run this script again to see if warnings are resolved."
    exit 0
  fi
else
  echo -e "${RED}❌ DEPLOYMENT HAS ISSUES${NC}"
  echo ""
  echo "Some critical components are missing or not ready."
  echo "Check the errors above and refer to QUICKSTART.md for troubleshooting."
  exit 1
fi
