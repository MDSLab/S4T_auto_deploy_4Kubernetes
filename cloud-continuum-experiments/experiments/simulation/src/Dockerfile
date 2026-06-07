FROM python:3.10-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# PYTHONPATH permette di importare common.utils
ENV PYTHONPATH=/app

# Comando di default (verrà sovrascritto nel manifest K8s)
CMD ["python", "cloud/teans.py"]
