# Complete Stack4Things Setup Guide

## Quick Start (Recommended)

```bash
# Clone the repository
git clone https://github.com/lucadagati/s4t_crossplane_deployment.git
cd s4t_crossplane_deployment

# Run the complete setup (installs everything)
./setup-all.sh
```

**That's it!** The script will:
- ✅ Install k3s (lightweight Kubernetes)
- ✅ Install Helm
- ✅ Generate TLS certificates
- ✅ Create all required ConfigMaps
- ✅ Deploy MetalLB, Istio, and Stack4Things
- ✅ Deploy Keycloak and Keystone
- ✅ Deploy Crossplane and custom provider
- ✅ Verify the deployment
- ✅ Display access information

## Prerequisites

### System Requirements
- **OS**: Linux (Ubuntu 20.04+, Debian, CentOS, etc.)
- **CPU**: 4+ cores recommended
- **RAM**: 8GB+ recommended
- **Disk**: 20GB+ free space
- **Network**: Internet connectivity for downloading images

### Required Tools (automatically installed by setup-all.sh)
- `curl` - downloading scripts and images
- `openssl` - generating TLS certificates
- `kubectl` - managing Kubernetes
- `helm` - managing Kubernetes packages

## Setup Options

### Option 1: Complete Installation (Default)
```bash
./setup-all.sh
```
Installs everything from scratch: k3s, Helm, and the entire Stack4Things stack.

### Option 2: Use Existing k3s
```bash
./setup-all.sh --skip-k3s
```
If you already have k3s installed and running, skip the k3s installation step.

### Option 3: Use Existing Helm
```bash
./setup-all.sh --skip-helm
```
If you already have Helm installed, skip the Helm installation step.

### Option 4: Use Both Existing Tools
```bash
./setup-all.sh --skip-k3s --skip-helm
```
Use existing k3s and Helm installations.

## What Gets Installed

### Core Infrastructure
- **k3s**: Lightweight Kubernetes distribution
- **Helm**: Kubernetes package manager
- **MetalLB**: Load balancer for bare-metal clusters
- **Istio**: Service mesh for traffic management

### Stack4Things Components
- **IoTronic Conductor**: Central management service
- **Crossbar**: WAMP message router
- **Wagent**: IoT device agent
- **IoTronic UI (Horizon)**: Web dashboard
- **RabbitMQ**: Message broker

### Identity & Federation
- **Keycloak**: OIDC identity provider
- **Keystone**: OpenStack-compatible federation service

### Infrastructure-as-Code
- **Crossplane**: Declarative infrastructure management
- **Custom S4T Provider**: Crossplane provider for Stack4Things resources

### Persistent Storage
- **Certificates**: TLS certs for Keycloak and Crossbar
- **Configuration**: ConfigMaps for services

## Accessing the Dashboard

### 1. Get the Access URL

**Option A: Using LoadBalancer (Recommended)**
```bash
# Get the LoadBalancer IP
kubectl get svc istio-ingress -n istio-ingress -o wide

# Access at: http://<LOADBALANCER_IP>/horizon
```

**Option B: Using NodePort (Fallback)**
```bash
# Get the node IP
kubectl get nodes -o wide

# Get the NodePort
kubectl get svc iotronic-ui-direct -n default

# Access at: http://<NODE_IP>:<NODEPORT>/horizon
```

**Option C: Port Forwarding (Local Only)**
```bash
kubectl port-forward -n default svc/iotronic-ui 8070:80
# Access at: http://localhost:8070/horizon
```

### 2. Login Credentials

```
Username: admin
Password: s4t
```

## Troubleshooting

### Pods not starting?
```bash
# Check pod status
kubectl get pods -n default

# Check specific pod logs
kubectl logs -f -n default <pod-name>

# Describe pod for detailed info
kubectl describe pod -n default <pod-name>
```

### Services not accessible?
```bash
# Check if services are created
kubectl get svc -n default

# Check if endpoints are populated
kubectl get endpoints -n default

# Try port-forwarding
kubectl port-forward -n default svc/<service-name> <local-port>:<service-port>
```

### ConfigMaps missing?
```bash
# List all ConfigMaps
kubectl get configmap -n default

# Check specific ConfigMap
kubectl describe configmap -n default <configmap-name>
```

### Check Keycloak/Keystone Status
```bash
# Check Keycloak
kubectl get pods -n keycloak
kubectl logs -f -n keycloak keycloak-0

# Check Keystone
kubectl get pods -n keystone
kubectl logs -f -n keystone keystone-0
```

### Clear and Restart
```bash
# Delete all Stack4Things pods (they'll restart automatically)
kubectl delete pods -n default -l io.kompose.service=iotronic-conductor
kubectl delete pods -n default -l io.kompose.service=crossbar
kubectl delete pods -n default -l io.kompose.service=iotronic-wagent

# Wait for new pods to start
kubectl get pods -n default -w
```

## Advanced Usage

### Manual Steps (if setup-all.sh doesn't work)

1. **Install k3s**
   ```bash
   curl -sfL https://get.k3s.io | sh -
   ```

2. **Set kubeconfig permissions**
   ```bash
   sudo chmod 644 /etc/rancher/k3s/k3s.yaml
   export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
   ```

3. **Install Helm**
   ```bash
   curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
   ```

4. **Generate certificates**
   ```bash
   cd stack4things-improved
   mkdir -p keycloak-keystone-integration/keycloak-config/certs
   # Use openssl to generate certs (see setup-all.sh for details)
   ```

5. **Create ConfigMaps**
   ```bash
   kubectl create configmap keycloak-certs --from-file=<cert-files> -n default
   ```

6. **Run deployment**
   ```bash
   cd stack4things-improved
   ./deploy-complete-improved.sh
   ```

7. **Deploy Keycloak & Keystone**
   ```bash
   ./scripts/deploy-keycloak-keystone.sh
   ```

## Project Structure

```
s4t_crossplane_deployment/
├── setup-all.sh                    # Main setup script (RUN THIS!)
├── stack4things-improved/
│   ├── deploy-complete-improved.sh # Core deployment script
│   ├── yaml_file/                  # Kubernetes manifests
│   ├── istioconf/                  # Istio configurations
│   ├── scripts/                    # Helper scripts
│   ├── keycloak-keystone-integration/
│   │   ├── keycloak-config/        # Keycloak realm & certs
│   │   └── keystone-config/        # Keystone configuration
│   └── README.md                   # Detailed documentation
├── crossplane-provider/            # Crossplane S4T provider
└── stack4things/                   # Legacy deployment (not used)
```

## Key Files Generated

After running `setup-all.sh`, these files are created:

- `stack4things-improved/keycloak-keystone-integration/keycloak-config/certs/`
  - `iotronic_CA.key` - Certificate Authority private key
  - `iotronic_CA.pem` - Certificate Authority certificate
  - `keycloak.key` - Keycloak private key
  - `keycloak.pem` - Keycloak certificate
  - `crossbar.key` - Crossbar private key
  - `crossbar.pem` - Crossbar certificate

- Kubernetes ConfigMaps (in default namespace):
  - `keycloak-certs` - Keycloak certificates
  - `keycloak-realm-config` - Keycloak OIDC realm definition
  - `keystone-config` - Keystone configuration
  - `keystone-mapping` - Keystone federated identity mapping
  - `keystone-sso` - Keystone SSO callback
  - `keystone-wsgi` - Keystone WSGI configuration
  - `iotronic-ssl-certs` - Crossbar SSL certificates

## Environment Variables

The setup script respects these environment variables:

```bash
# Use custom kubeconfig
export KUBECONFIG=/path/to/kubeconfig

# Override network interface for MetalLB (auto-detected by default)
# (not directly supported, but can be modified in deploy-complete-improved.sh)
```

## Uninstalling Stack4Things

### Remove Kubernetes Deployment Only
```bash
cd stack4things-improved
kubectl delete -f yaml_file/
kubectl delete namespace keycloak keystone crossplane-system istio-system metallb-system
```

### Remove Entire k3s Cluster
```bash
# On the k3s node
/usr/local/bin/k3s-uninstall.sh

# Or for rootless k3s
/usr/local/bin/k3s-uninstall-rootless.sh
```

## Next Steps After Deployment

1. **Access the Dashboard**
   - URL: http://<IP>:8070/horizon
   - Credentials: admin / s4t

2. **Create Lightning Rods**
   ```bash
   cd stack4things-improved/scripts
   ./create-lightning-rod-for-board.sh <BOARD_CODE>
   ```

3. **Deploy IoT Boards**
   - Use the UI to register boards
   - Or deploy via Crossplane CRDs

4. **Configure OIDC (Optional)**
   ```bash
   ./scripts/configure-k3s-oidc.sh
   ```

5. **Setup RBAC (Optional)**
   ```bash
   ./scripts/deploy-rbac-operator.sh
   ```

## Support & Documentation

- **Stack4Things Wiki**: See `stack4things-improved/README.md` for detailed documentation
- **Crossplane Docs**: https://docs.crossplane.io/
- **k3s Documentation**: https://docs.k3s.io/
- **Istio Documentation**: https://istio.io/docs/

## License

This project is part of Stack4Things and follows the same licensing terms.
