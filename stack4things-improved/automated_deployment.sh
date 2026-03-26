#!/bin/bash

set -euo pipefail

###############################
# Interactive Setup Script for
# Stack4Things on Local K3s
###############################

### Utility: show title step ###
step() {
  echo ""
  echo "================================================================="
  echo " STEP $1: $2"
  echo "================================================================="
}

### Detect interface and subnet ###
detect_ip_range() {
  step "0" "Detecting local network IP range for MetalLB"
  INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
  LOCAL_IP=$(ip -4 addr show "$INTERFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
  SUBNET=$(echo "$LOCAL_IP" | cut -d. -f1-3)

  IP_POOL_START="${SUBNET}.240"
  IP_POOL_END="${SUBNET}.250"

  echo "✔ Active network interface: $INTERFACE"
  echo "✔ Detected IP address: $LOCAL_IP"
  echo "✔ Proposed MetalLB IP pool: $IP_POOL_START - $IP_POOL_END"
}

detect_ip_range

export KUBECONFIG="/etc/rancher/k3s/k3s.yaml"

#################################
step "1" "Installing K3s (Lightweight Kubernetes)"
#################################
if ! command -v k3s &>/dev/null && ! command -v kubectl &>/dev/null; then
  echo "🔧 Installing K3s..."
  curl -sfL https://get.k3s.io | sh -
  sudo chmod 644 $KUBECONFIG
else
  echo "✔ K3s is already installed."
fi

kubectl get nodes

#################################
step "2" "Installing Helm (Kubernetes package manager)"
#################################
if ! command -v helm &>/dev/null; then
  echo "🔧 Installing Helm..."
  curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
  chmod 700 get_helm.sh
  ./get_helm.sh
else
  echo "✔ Helm is already installed."
fi

#################################
step "3" "Installing MetalLB (LoadBalancer for bare-metal)"
#################################
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.10/config/manifests/metallb-native.yaml

echo "⏳ Waiting for MetalLB pods to become available..."
sleep 10
kubectl wait --namespace metallb-system --for=condition=available deployment --all --timeout=90s

echo " Generating MetalLB configuration..."
cat <<EOF > metallb-config.yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system 
spec:
  addresses:
  - ${IP_POOL_START}-${IP_POOL_END}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2-config
  namespace: metallb-system
EOF

kubectl apply -f metallb-config.yaml
echo "✔ MetalLB configured with IP pool: $IP_POOL_START - $IP_POOL_END"

#################################
step "4" "Installing Istio (Service Mesh & Ingress Gateway)"
#################################
helm repo add istio https://istio-release.storage.googleapis.com/charts || true
helm repo update

helm upgrade --install istio-base istio/base -n istio-system --create-namespace --set defaultRevision=default
helm upgrade --install istiod istio/istiod -n istio-system --wait

kubectl create namespace istio-ingress || true
helm upgrade --install istio-ingress istio/gateway -n istio-ingress --wait

echo "✔ Istio installed and ready."

#################################
step "5" "Cloning and deploying Stack4Things on K3s"
#################################
if [ ! -d "Stack4Things_k3s_deployment" ]; then
  git clone https://github.com/MDSLab/Stack4Things_k3s_deployment.git
fi

cd Stack4Things_k3s_deployment

echo " Applying core services from 'yaml_file/'..."
kubectl apply -f yaml_file/

echo " Applying Istio VirtualServices and Gateways from 'istioconf/'..."
kubectl apply -f istioconf/

#################################
step "6" "Configuring Istio Ingress Service Ports"
#################################
cat <<EOF | kubectl patch svc istio-ingress -n istio-ingress --patch-file /dev/stdin
spec:
  ports:
    - name: tcp-crossbar
      port: 8181
      targetPort: 8181
      protocol: TCP
    - name: lr
      port: 1474
      targetPort: 1474
      protocol: TCP
    - name: conductor
      port: 8812
      targetPort: 8812
      protocol: TCP
    - name: wstun
      port: 8080
      targetPort: 8080
      protocol: TCP
    - name: rabbit
      port: 5672
      targetPort: 5672
      protocol: TCP
    - name: rabbitui
      port: 15672
      targetPort: 15672
      protocol: TCP
    - name: iotronic-ui
      port: 8070
      targetPort: 8070
      protocol: TCP
EOF

echo "✔ Ingress ports updated for Stack4Things services."

#################################
step "7" "Verifying Deployment Status"
#################################
kubectl get pods -A
kubectl get svc -n istio-ingress
kubectl get gateway
kubectl get virtualservice

LB_IP=$(kubectl get svc istio-ingress -n istio-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo " Public LoadBalancer IP: http://$LB_IP/"

#################################
step "8" "Testing Web Access (Iotronic UI)"
#################################
echo "⏳ Waiting 5 seconds before attempting to connect..."
sleep 5
curl -s --max-time 5 http://$LB_IP/ || echo " Could not reach the UI — try again in a minute."

echo ""
echo " DONE! Stack4Things has been successfully deployed on your local K3s node."
echo " Access the UI at: http://$LB_IP/horizon"
