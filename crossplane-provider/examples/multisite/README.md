# Stack4Things Multisite Examples

This directory contains examples for deploying and managing Stack4Things in a multisite environment using Crossplane.

## Prerequisites

1. Stack4Things deployed and running
2. Crossplane installed
3. Crossplane S4T Provider installed
4. RBAC manifests applied

## Quick Start

### 1. Configure Provider Credentials

First, create a secret with your Stack4Things credentials:

```bash
kubectl apply -f providerconfig.yaml
```

Edit the secret to match your actual Stack4Things credentials.

### 2. Create Sites

Create your multisite structure:

```bash
kubectl apply -f site-example.yaml
```

This creates three sites:
- `site-production`: Main production site
- `site-staging`: Staging environment (child of production)
- `site-development`: Development environment (child of staging)

### 3. Create Devices

Associate devices with sites:

```bash
kubectl apply -f device-with-site.yaml
```

### 4. Configure RBAC

Apply RBAC rules for multisite management:

```bash
# Apply base RBAC roles
kubectl apply -f ../../cluster/rbac/

# Apply example RBAC bindings (customize as needed)
kubectl apply -f rbac-example.yaml
```

## RBAC Roles

The provider includes three predefined ClusterRoles:

1. **s4t-multisite-admin**: Full access to all S4T resources
   - Create, read, update, delete sites, devices, services, plugins
   - Manage ProviderConfigs

2. **s4t-multisite-operator**: Operational access
   - Read and update sites (no delete)
   - Full CRUD on devices, services, plugins

3. **s4t-multisite-viewer**: Read-only access
   - View all S4T resources
   - No modification permissions

## Site Hierarchy

Sites can be organized hierarchically using the `parentSite` field:

```
site-production (root)
  └── site-staging
      └── site-development
```

This allows for:
- Hierarchical device management
- Site-specific configurations
- Inheritance of settings from parent sites

## Labeling Resources

Use labels to associate resources with sites:

```yaml
metadata:
  labels:
    site: site-production
```

This enables:
- Site-based filtering
- Site-scoped RBAC policies
- Resource organization

## Customization

### Custom Site Configuration

Sites support custom configuration via the `config` field:

```yaml
spec:
  forProvider:
    config:
      region: "us-east-1"
      timezone: "America/New_York"
      custom-key: "custom-value"
```

### Site-Specific ProviderConfigs

You can create site-specific ProviderConfigs for different S4T instances:

```yaml
apiVersion: s4t.crossplane.io/v1alpha1
kind: ProviderConfig
metadata:
  name: s4t-provider-site-production
spec:
  credentials:
    source: Secret
    secretRef:
      name: s4t-credentials-production
      namespace: crossplane-system
```

Then reference it in your Site:

```yaml
spec:
  providerConfigRef:
    name: s4t-provider-site-production
```

## Troubleshooting

### Check Site Status

```bash
kubectl get sites
kubectl describe site site-production
```

### Check RBAC Permissions

```bash
kubectl auth can-i create sites --as=system:serviceaccount:crossplane-system:s4t-admin
kubectl get clusterrole s4t-multisite-admin -o yaml
```

### View Provider Logs

```bash
kubectl logs -n crossplane-system -l pkg.crossplane.io/provider=provider-s4t
```

## Next Steps

- Create site-specific namespaces for better isolation
- Implement site-based network policies
- Set up monitoring and alerting per site
- Configure backup and disaster recovery per site

