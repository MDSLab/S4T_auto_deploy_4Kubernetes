FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY config.py http_client.py \
     s1_ingest.py s2_normalize.py s3_detect.py \
     s4_aggregate.py s5_alert.py ./

CMD ["python", "s1_ingest.py"]
