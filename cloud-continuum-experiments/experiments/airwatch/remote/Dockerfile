FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY config.py r2_notify.py ./

CMD ["python", "r2_notify.py"]
