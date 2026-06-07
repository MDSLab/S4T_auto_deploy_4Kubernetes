FROM apache/spark:3.5.1-python3

USER root

# Spark standard workdir
WORKDIR /opt/spark/work-dir

# Pre-install dependencies Python
RUN pip install --no-cache-dir \
    influxdb==5.3.2 \
    kafka-python==2.0.2

# Creiamo la directory home per lo user spark (185) e impostiamo i permessi per Ivy cache
RUN mkdir -p /home/spark/.ivy2/cache && \
    mkdir -p /home/spark/.ivy2/jars && \
    chown -R 185:0 /home/spark && \
    chmod -R g+w /home/spark

# Impostiamo la variabile HOME affinché Spark/Ivy sappiano dove scrivere
ENV HOME=/home/spark

# Copiamo il codice sorgente
COPY s4_spark.py .

# Ensure that la working directory is writable per l'utente spark
RUN chown -R 185:0 /opt/spark/work-dir && \
    chmod -R g+w /opt/spark/work-dir

USER 185
