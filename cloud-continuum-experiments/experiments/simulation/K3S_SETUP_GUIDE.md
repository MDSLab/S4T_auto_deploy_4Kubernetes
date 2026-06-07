# Multi-Cluster K3s Setup Guide for REC Simulation

This guide explains how to configure the distributed environment composed of lightweight K3s clusters and how to deploy the Renewable Energy Community (REC) simulation (TEANS, EPREM, ECREM).

## 1. Cluster Architecture

The environment consists of the following tiers:
- **Edge Tier**: Gateway nodes (Prosumer/Residential) + Local Scheduler.
- **Fog Tier**: Mediation nodes (EPREM) + Physical/Simulated Sources.
- **Cloud Tier**: Centralized orchestration (Kafka, TEANS, ECREM).
- **Storage Node**: Hosting the time-series database (InfluxDB).

## 2. K3s Installation

On each machine dedicated to the clusters, run the quick installation command:

```bash
curl -sfL https://get.k3s.io | sh -
```

After installation, retrieve the configuration file (`/etc/rancher/k3s/k3s.yaml`) and rename it appropriately (e.g., `edge.yaml`, `cloud.yaml`).

> **Note**: In the `.yaml` file, replace `127.0.0.1` with the public or VPN IP of the machine.

## 3. Cloud Prerequisites (Strimzi Kafka Operator)

On the **Cloud** cluster, install the Kafka operator to manage topics:

```bash
export KUBECONFIG=cloud.yaml
kubectl create namespace kafka
kubectl apply -f 'https://strimzi.io/install/1.0.0?namespace=kafka' -n kafka
```

## 4. Networking Configuration (Cross-Cluster)

The simulation uses **NodePorts** for cross-cluster communication. Ensure that ports `31000-31005` are open on the firewalls of the respective nodes.

| Service | Port | Target Cluster |
| :--- | :--- | :--- |
| TEANS (Kafka In) | 31001 (NodePort) | Cloud |
| ECREM (API) | 31002 (NodePort) | Cloud |
| EPREM (API) | 31003 (NodePort) | Fog |
| Scheduler | 31004 (NodePort) | Edge |

## 5. Deployment

### 5.1 Image Build
From the project root, build the microservices image:

```bash
docker build -t your-registry/rec-microservices:latest ./experiments/simulation/src/
docker push your-registry/rec-microservices:latest
```

### 5.2 Execution
Use the provided master script to deploy the full continuum:

```bash
./deploy-continuum.sh --registry <your-registry>
```

## 6. Verification

1.  **Check Pods**: `kubectl get pods -n simulation` on every cluster.
2.  **Edge Logs**: `kubectl logs -l app=simulator-edge -n simulation -f`
3.  **Cloud Logs (TEANS)**: `kubectl logs -l app=teans -n simulation -f`

## 7. Troubleshooting

- **Connectivity**: If a pod cannot reach another, verify the IP addresses provided during deployment (variables `CLOUD_IP` and `FOG_IP`).
- **Kafka**: If TEANS fails to start, verify that Kafka topics were correctly created: `kubectl get kafkas -n simulation`.
- **Resilience**: If the Cloud tier is unavailable, check the Edge pod logs to verify that the local buffer (`/data/edge_buffer.jsonl`) is correctly caching records.
