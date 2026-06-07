import json
import socket
import platform
import subprocess
import time
import os
from datetime import datetime

def get_cpu_info():
    try:
        if platform.system() == "Linux":
            command = "cat /proc/cpuinfo | grep 'model name' | head -1 | cut -d':' -f2"
            model = subprocess.check_output(command, shell=True).decode().strip()
            if not model:
                model = subprocess.check_output("lscpu | grep 'Model name' | cut -d':' -f2", shell=True).decode().strip()
            return model
    except:
        return "Unknown"

def get_k8s_version():
    try:
        return subprocess.check_output("kubectl version --short 2>/dev/null || kubectl version", shell=True).decode().strip().split('\n')[0]
    except:
        return "N/A"

def get_ntp_offset():
    # Try multiple methods for NTP sync status
    methods = [
        "chronyc tracking | grep 'RMS offset' | awk '{print $4}'",
        "timedatectl status | grep 'System clock synchronized' | awk '{print $4}'",
        "ntpq -pn | tail -1 | awk '{print $9}'"
    ]
    for cmd in methods:
        try:
            out = subprocess.check_output(cmd, shell=True).decode().strip()
            if out: return out
        except: continue
    return "Unknown/Not Synced"

def get_cloud_node_info():
    # Try to get cloud node info using the master kubeconfig if available
    try:
        nodes = subprocess.check_output("kubectl --kubeconfig kubeconfigs/cloud-cloud.yaml --insecure-skip-tls-verify get nodes -o json", shell=True)
        data = json.loads(nodes)
        node = data['items'][0]
        status = node['status']['capacity']
        return {
            "cpu_cores": status.get('cpu'),
            "ram": status.get('memory'),
            "kernel": node['status']['nodeInfo'].get('kernelVersion'),
            "os": node['status']['nodeInfo'].get('osImage')
        }
    except:
        return {"provider": "SLICES / UNIBO", "info": "Consult documentation"}

def get_metadata(run_id=None):
    metadata = {
        "lightning_rod_version": "1.2.0-provenance-enabled",
        "eprem_version": "1.2.0",
        "teans_version": "1.2.0",
        "kafka_version": "3.7.0 (confluent)",
        "spark_version": "3.5.0",
        "influxdb_version": "1.8.10",
        "kubernetes_version": get_k8s_version(),
        "os_kernel": platform.release(),
        "python_version": platform.python_version(),
        "experiment_tag": "FGCS-REV-2026",
        "started_at": datetime.now().isoformat(),
        "run_id": run_id,
        "ntp_sync_offset": get_ntp_offset(),
        "airwatch_config": {
            "polling_interval_s": 5.0,
            "spark_window_s": 60,
            "batch_limit": 100
        },
        "fog_node": {
            "hostname": socket.gethostname(),
            "cpu_model": get_cpu_info(),
            "cpu_cores": os.cpu_count(),
            "ram_gb": round(os.sysconf('SC_PAGE_SIZE') * os.sysconf('SC_PHYS_PAGES') / (1024.**3), 2),
            "os": platform.platform(),
        },
        "cloud_node": get_cloud_node_info()
    }
    return metadata

if __name__ == "__main__":
    import sys
    run_id = sys.argv[1] if len(sys.argv) > 1 else None
    metadata = get_metadata(run_id)
    with open("experiment_metadata.json", "w") as f:
        json.dump(metadata, f, indent=2)
    print("Metadata written to experiment_metadata.json")
