import time
import os
import sys
import subprocess

def get_metrics():
    try:
        # CPU usage (1s interval)
        cpu = subprocess.check_output("top -bn2 -d1 | grep 'Cpu(s)' | tail -n1 | awk '{print 100-$8}'", shell=True).decode().strip()
        
        # RAM usage
        mem_info = subprocess.check_output("free -m | grep Mem", shell=True).decode().split()
        ram_total = mem_info[1]
        ram_used = mem_info[2]
        
        # Network (eth0)
        net_info = subprocess.check_output("cat /proc/net/dev | grep 'eth0\\|tailscale0\\|wg0' | head -n1", shell=True).decode().split()
        net_recv = net_info[1]
        net_sent = net_info[9]
        
        # CPU Temperature (Raspberry Pi / Linux)
        temp = "N/A"
        if os.path.exists("/sys/class/thermal/thermal_zone0/temp"):
            with open("/sys/class/thermal/thermal_zone0/temp") as f:
                temp = float(f.read()) / 1000.0
        
        return {
            "timestamp": int(time.time()),
            "cpu_percent": cpu,
            "ram_used_mb": ram_used,
            "ram_total_mb": ram_total,
            "net_bytes_recv": net_recv,
            "net_bytes_sent": net_sent,
            "cpu_temp_c": temp
        }
    except Exception as e:
        return None

if __name__ == "__main__":
    node_name = sys.argv[1] if len(sys.argv) > 1 else "unknown"
    interval = int(sys.argv[2]) if len(sys.argv) > 2 else 5
    output_file = f"resource_utilization_{node_name}.csv"
    
    print(f"Sampling resources for {node_name} every {interval}s to {output_file}")
    
    with open(output_file, "w") as f:
        f.write("timestamp,cpu_percent,ram_used_mb,ram_total_mb,net_bytes_recv,net_bytes_sent,cpu_temp_c\n")
    
    try:
        while True:
            m = get_metrics()
            if m:
                with open(output_file, "a") as f:
                    f.write(f"{m['timestamp']},{m['cpu_percent']},{m['ram_used_mb']},{m['ram_total_mb']},{m['net_bytes_recv']},{m['net_bytes_sent']},{m['cpu_temp_c']}\n")
            time.sleep(interval)
    except KeyboardInterrupt:
        print("Stopped sampling.")
