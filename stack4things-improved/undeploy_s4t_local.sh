#!/bin/bash

set -euo pipefail

echo ""
echo "==========================================================="
echo " UNINSTALLING Stack4Things + K3s + Istio + MetalLB"
echo "This will delete all Kubernetes resources and tools"
echo "==========================================================="

read -p " Do you want to proceed? [y/N]: " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo " Uninstall aborted."
    exit 1
fi

### Step 1: Delete Stack4Things manifests ###
echo ""
echo " Removing Stack4Things manifests (if present)..."
if [ -d "Stack4Things_k3s_deployment" ]; then
    kubectl delete -f Stack4Things_k3s_deployment/istioconf/ || true
    kubectl delete -f Stack4Things_k3s_deployment/yaml_file/ || true
    rm -rf Stack4Things_k3s_deployment
    echo "✔ Stack4Things removed."
else
    echo " Stack4Things repo not found. Skipping..."
fi

### Step 2: Uninstall Istio ###
echo ""
echo " Uninstalling Istio..."
helm uninstall istio-ingress -n istio-ingress || true
helm uninstall istiod -n istio-system || true
helm uninstall istio-base -n istio-system || true

kubectl delete namespace istio-system || true
kubectl delete namespace istio-ingress || true

### Step 3: Uninstall MetalLB ###
echo ""
echo " Removing MetalLB..."
kubectl delete -f metallb-config.yaml || true
kubectl delete -f https://raw.githubusercontent.com/metallb/metallb/v0.13.10/config/manifests/metallb-native.yaml || true
kubectl delete namespace metallb-system || true

### Step 4: Delete Helm binary (optional) ###
if command -v helm &>/dev/null; then
    read -p " Do you want to remove Helm from this system? [y/N]: " REMOVE_HELM
    if [[ "$REMOVE_HELM" == "y" || "$REMOVE_HELM" == "Y" ]]; then
        sudo rm -f /usr/local/bin/helm
        echo "✔ Helm binary removed."
    fi
fi

### Step 5: Stop and uninstall K3s ###
echo ""
echo " Uninstalling K3s and wiping Kubernetes data..."
if command -v k3s-uninstall.sh &>/dev/null; then
    sudo /usr/local/bin/k3s-uninstall.sh
    echo "✔ K3s removed."
else
    echo " k3s-uninstall.sh not found. Manual uninstall may be needed."
fi

### Step 6: Clean up local files ###
echo ""
echo " Cleaning up local files..."
rm -f get_helm.sh metallb-config.yaml

echo ""
echo " Uninstallation complete! Your system has been cleaned."
