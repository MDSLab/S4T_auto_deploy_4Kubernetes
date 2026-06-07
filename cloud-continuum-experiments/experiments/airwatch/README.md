# AirWatch Urban Monitoring - Pipeline Services

This directory contains the pipeline services for the AirWatch urban monitoring use case.

## Deployment

1.  **Configure Credentials**: Update `k3s/fog/configmap-secret.yaml` with your actual InfluxDB and Kafka credentials.
2.  **Run Deployment**:
    ```bash
    ./deploy.sh --registry <your-registry>
    ```

## Post-Deployment

- **Ingress Routes**: After services are online, apply Traefik IngressRoutes if public access is required.
- **Monitoring**: Access the Grafana dashboard via the Fog gateway.

## Data Extraction

Use the `extract_metrics.sh` script in the root directory to gather logs and CSV data:
```bash
./extract_metrics.sh --app airwatch --minutes 10 --output-dir ./results
```

The generated files (`airwatch_raw.csv`, etc.) contain the timestamps needed to calculate end-to-end latencies as described in the paper.
