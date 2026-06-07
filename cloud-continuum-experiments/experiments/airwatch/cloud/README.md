# AirWatch Cloud — Deployment guide on k3s (cloud cluster)

## Struttura

```
cloud/
├── spark/
│   ├── s4_spark.py      # Job PySpark Structured Streaming
│   └── Dockerfile       # Immagine airwatch/s4-spark:v1.2.0
└── k3s/
    ├── kafka/
    │   ├── kafka-cluster.yaml    # Strimzi operator + Kafka + Topic
    │   └── configmap-patch.yaml  # Patch to apply to the fog cluster
    └── airwatch-cloud/
        ├── spark-operator.yaml   # Namespace, RBAC, ConfigMap, Secret
        └── s4-spark-application.yaml  # SparkApplication CRD
```

## Prerequisiti

- k3s pulito raggiungibile via VPN
- `kubectl` configured for the cloud cluster
- `helm` installato

## 1. Installa Strimzi operator

```bash
kubectl create namespace kafka
kubectl create -f https://strimzi.io/install/1.0.0?namespace=kafka -n kafka

# Wait for l'operatore to be ready
kubectl wait deployment strimzi-cluster-operator \
  -n kafka --for=condition=Available --timeout=120s
```

## 2. Deploy Kafka cluster e topic

```bash
kubectl apply -f k3s/kafka/kafka-cluster.yaml

# Wait for Kafka to be ready (puo' take 2-3 minutes)
kubectl wait kafka/airwatch-kafka \
  -n kafka --for=condition=Ready --timeout=300s

# Verifica
kubectl get kafka -n kafka
kubectl get kafkatopic -n kafka
```

## 3. Retrieve the NodePort di Kafka

```bash
kubectl get svc -n kafka | grep external
```

Nota la NodePort (es. 32092) — serve per configurare s2 sul cluster fog.

## 4. Aggiorna il ConfigMap del cluster fog

Sul cluster fog, aggiungi al ConfigMap airwatch-config:

```bash
kubectl patch configmap airwatch-config -n airwatch --patch '
data:
  KAFKA_BOOTSTRAP: "IP_VPN_CLUSTER_CLOUD:NODEPORT_KAFKA"
  KAFKA_TOPIC: "airwatch-normalized"
'

# Riavvia s2 per applicare la nuova configurazione
kubectl rollout restart deployment/s2 -n airwatch
```

## 5. Installa spark-on-k8s-operator

```bash
helm repo add spark https://apache.github.io/spark-kubernetes-operator
helm repo update
helm install spark-operator spark/spark-kubernetes-operator \
  --namespace airwatch-cloud \
  --create-namespace \
  

kubectl wait deployment spark-operator \
  -n airwatch-cloud --for=condition=Available --timeout=120s
```

## 6. Configura InfluxDB nel ConfigMap

```bash
# Modify INFLUX_HOST in k3s/airwatch-cloud/spark-operator.yaml
# con l'IP o hostname reale di InfluxDB
vim k3s/airwatch-cloud/spark-operator.yaml

kubectl apply -f k3s/airwatch-cloud/spark-operator.yaml
```

## 7. Build e push immagine Spark

```bash
cd spark
docker build -t mariorossi851234/s4-spark:v1.2.0 .
docker push mariorossi851234/s4-spark:v1.2.0
```

## 8. Deploy SparkApplication

```bash
kubectl apply -f k3s/airwatch-cloud/s4-spark-application.yaml

# Monitora il job
kubectl get sparkapplication -n airwatch-cloud
kubectl describe sparkapplication s4-aggregator -n airwatch-cloud
```

## 9. Verifica end-to-end

```bash
# Log del driver Spark
kubectl logs -n airwatch-cloud \
  $(kubectl get pod -n airwatch-cloud -l spark-role=driver -o name)

# Verifica dati aggregati su InfluxDB
kubectl exec -n airwatch deploy/s1 -- python -c "
from influxdb import InfluxDBClient
c = InfluxDBClient(host='INFLUX_HOST', port=8086,
                   username='admin', password='changeme',
                   database='airwatch')
print(list(c.query('SELECT * FROM env_aggregated_spark LIMIT 5').get_points()))
"
```

## Architettura dei tre cluster

```
[Device IoT]
  edge_plugin.py
  Lightning-Rod
       |
       | wstun tunnel
       v
[Cluster Fog]
  s1 -> s2 -> s3 -> s5 -> r2 (remote)
         |
         | HTTP (real-time)    | Kafka topic (cross-cluster via VPN)
         v                     v
        s3                [Cluster Cloud]
                           Kafka -> Spark s4 -> InfluxDB

[Cluster Remote]
  Grafana (r1) <- InfluxDB
  r2 (notify)  <- s5
```
