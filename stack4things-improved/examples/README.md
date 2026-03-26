# Stack4Things Plugin Examples

This directory contains example plugins for Stack4Things that can be deployed using Crossplane.

## Available Plugins

### 1. Simple Environmental Logger (`plugin-simple-example.yaml`)

A basic plugin that logs simulated environmental data (temperature, humidity, pressure) every 30 seconds.

**Features:**
- Simple logging of environmental data
- Configurable interval
- Minimal code footprint

**Usage:**
```bash
cd stack4things-improved
./scripts/create-plugin.sh simple-environmental-logger examples/plugin-simple-example.yaml
```

### 2. Environmental Monitor (`plugin-environmental-monitor.yaml`)

A more complete environmental monitoring plugin that logs structured data with multiple metrics.

**Features:**
- Structured JSON logging
- Multiple environmental metrics (temperature, humidity, pressure, wind)
- Error handling
- Configurable parameters

**Usage:**
```bash
cd stack4things-improved
./scripts/create-plugin.sh environmental-monitor examples/plugin-environmental-monitor.yaml
```

## Plugin Structure

All plugins follow the Stack4Things plugin structure:

```python
from iotronic_lightningrod.plugins import Plugin
from oslo_log import log as logging

LOG = logging.getLogger(__name__)

class Worker(Plugin.Plugin):
    def __init__(self, uuid, name, q_result, params=None):
        super(Worker, self).__init__(uuid, name, q_result, params)
        
    def run(self):
        # Plugin logic here
        LOG.info("Plugin running")
        self.q_result.put("SUCCESS")
```

## Deploying Plugins

### Step 1: Create Plugin

```bash
./scripts/create-plugin.sh <plugin-name> [plugin-yaml-file]
```

### Step 2: Verify Plugin

```bash
kubectl get plugin <plugin-name> -n default
kubectl describe plugin <plugin-name> -n default
```

### Step 3: Inject into Board

```bash
./scripts/inject-plugin-to-board.sh <BOARD_CODE> <PLUGIN_NAME>
```

### Step 4: Start Plugin

Use the IoTronic API or dashboard to start the plugin on the board.

## Customizing Plugins

You can customize plugins by:

1. **Modifying parameters**: Edit the `parameters` section in the YAML
2. **Changing code**: Modify the `code` section with your Python logic
3. **Adding dependencies**: Ensure required Python packages are available in Lightning Rod

## Reference

Based on the original [S4T_Application_demo](https://github.com/MDSLab/S4T_Application_demo.git) repository, but simplified:
- Removed InfluxDB dependency
- Removed CSV file download
- Simplified to basic logging
- Easy to understand and modify
