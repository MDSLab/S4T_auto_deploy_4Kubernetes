# Stack4Things/IoTronic API Documentation

This document provides comprehensive documentation of all API endpoints in Stack4Things/IoTronic and their mapping to Crossplane Provider CRDs.

## Base URL

- **Endpoint**: `http://iotronic-conductor:8812/v1`
- **Authentication**: Keystone token via `X-Auth-Token` header
- **Content-Type**: `application/json`

## API Endpoints

### 1. Boards (Devices)

#### Create Board
- **Method**: `POST`
- **Endpoint**: `/v1/boards`
- **Request Body**:
  ```json
  {
    "name": "string (required)",
    "code": "string (required)",
    "type": "string (virtual|physical)",
    "location": [
      {
        "latitude": "string",
        "longitude": "string",
        "altitude": "string"
      }
    ]
  }
  ```
- **Response**: Board object with UUID
- **Crossplane CRD**: `devices.iot.s4t.crossplane.io`
- **Controller**: `internal/controller/device/device.go`
- **Status**: ✅ Implemented

#### Get Board
- **Method**: `GET`
- **Endpoint**: `/v1/boards/{uuid}`
- **Response**: Board details
- **Crossplane**: Read via `Observe()` method
- **Status**: ✅ Implemented

#### Update Board
- **Method**: `PATCH`
- **Endpoint**: `/v1/boards/{uuid}`
- **Request Body**: Partial board object
- **Crossplane**: Update via `Update()` method
- **Status**: ✅ Implemented

#### Delete Board
- **Method**: `DELETE`
- **Endpoint**: `/v1/boards/{uuid}`
- **Crossplane**: Delete via `Delete()` method
- **Status**: ✅ Implemented

#### List Boards
- **Method**: `GET`
- **Endpoint**: `/v1/boards`
- **Response**: Array of board objects
- **Crossplane**: Not directly mapped (use `kubectl get device`)

### 2. Plugins

#### Create Plugin
- **Method**: `POST`
- **Endpoint**: `/v1/plugins`
- **Request Body**:
  ```json
  {
    "name": "string (required)",
    "code": "string (required, Python code)",
    "parameters": {
      "key": "value"
    }
  }
  ```
- **Response**: Plugin object with UUID
- **Crossplane CRD**: `plugins.iot.s4t.crossplane.io`
- **Controller**: `internal/controller/plugin/plugin.go`
- **Status**: ✅ Implemented
- **Note**: The `code` field contains the full Python plugin code as a string

#### Get Plugin
- **Method**: `GET`
- **Endpoint**: `/v1/plugins/{uuid}`
- **Response**: Plugin details
- **Crossplane**: Read via `Observe()` method
- **Status**: ✅ Implemented

#### Update Plugin
- **Method**: `PATCH`
- **Endpoint**: `/v1/plugins/{uuid}`
- **Request Body**: Partial plugin object
- **Crossplane**: Update via `Update()` method
- **Status**: ✅ Implemented (note: typo in SDK method name `PacthPlugin`)

#### Delete Plugin
- **Method**: `DELETE`
- **Endpoint**: `/v1/plugins/{uuid}`
- **Crossplane**: Delete via `Delete()` method
- **Status**: ✅ Implemented

### 3. Plugin Injection

#### Inject Plugin into Board
- **Method**: `PUT`
- **Endpoint**: `/v1/boards/{board_uuid}/plugins/`
- **Request Body**:
  ```json
  {
    "plugin": "plugin_uuid"
  }
  ```
- **Response**: `"PluginInject result: INJECTED"` (Status 200)
- **Crossplane CRD**: `boardplugininjections.iot.s4t.crossplane.io`
- **Controller**: `internal/controller/boardplugininjection/boardplugininjection.go`
- **Status**: ✅ Implemented
- **Important**: 
  - Board must be **online** (Lightning Rod connected)
  - Plugin must exist in database
  - Injection creates entry in `injected_plugins` table (if board is online)

#### Get Injected Plugins for Board
- **Method**: `GET`
- **Endpoint**: `/v1/boards/{board_uuid}/plugins`
- **Response**:
  ```json
  {
    "injections": [
      {
        "plugin": "plugin_uuid",
        "status": "injected|running|stopped",
        "onboot": false,
        "created_at": "timestamp",
        "updated_at": "timestamp|null"
      }
    ]
  }
  ```
- **Crossplane**: Read via `Observe()` method
- **Status**: ✅ Implemented (via `GetBoardPlugins()` SDK method)

#### Remove Injected Plugin
- **Method**: `DELETE`
- **Endpoint**: `/v1/boards/{board_uuid}/plugins/{plugin_uuid}`
- **Crossplane**: Delete via `Delete()` method
- **Status**: ✅ Implemented

#### Start Plugin on Board
- **Method**: `POST`
- **Endpoint**: `/v1/boards/{board_uuid}/plugins/{plugin_uuid}/start`
- **Request Body**: Empty or action object
- **Response**: Plugin status
- **Crossplane**: Not directly mapped (use dashboard or direct API call)
- **Status**: ⚠️ Not implemented in Crossplane

#### Stop Plugin on Board
- **Method**: `POST`
- **Endpoint**: `/v1/boards/{board_uuid}/plugins/{plugin_uuid}/stop`
- **Crossplane**: Not directly mapped
- **Status**: ⚠️ Not implemented in Crossplane

### 4. Services

#### Create Service
- **Method**: `POST`
- **Endpoint**: `/v1/services`
- **Request Body**:
  ```json
  {
    "name": "string (required)",
    "port": "integer (required)",
    "protocol": "TCP|UDP (required)",
    "project": "string (optional)"
  }
  ```
- **Response**: Service object with UUID
- **Crossplane CRD**: `services.iot.s4t.crossplane.io`
- **Controller**: `internal/controller/service/service.go`
- **Status**: ✅ Implemented

#### Get Service
- **Method**: `GET`
- **Endpoint**: `/v1/services/{uuid}`
- **Crossplane**: Read via `Observe()` method
- **Status**: ✅ Implemented

#### Update Service
- **Method**: `PATCH`
- **Endpoint**: `/v1/services/{uuid}`
- **Crossplane**: Update via `Update()` method
- **Status**: ✅ Implemented

#### Delete Service
- **Method**: `DELETE`
- **Endpoint**: `/v1/services/{uuid}`
- **Crossplane**: Delete via `Delete()` method
- **Status**: ✅ Implemented

### 5. Service Injection

#### Expose Service on Board
- **Method**: `PUT`
- **Endpoint**: `/v1/boards/{board_uuid}/services/`
- **Request Body**:
  ```json
  {
    "service": "service_uuid"
  }
  ```
- **Crossplane CRD**: `boardserviceinjections.iot.s4t.crossplane.io`
- **Controller**: `internal/controller/boardserviceinjection/boardserviceinjection.go`
- **Status**: ✅ Implemented

#### Get Exposed Services for Board
- **Method**: `GET`
- **Endpoint**: `/v1/boards/{board_uuid}/services`
- **Crossplane**: Read via `Observe()` method
- **Status**: ✅ Implemented

#### Remove Exposed Service
- **Method**: `DELETE`
- **Endpoint**: `/v1/boards/{board_uuid}/services/{service_uuid}`
- **Crossplane**: Delete via `Delete()` method
- **Status**: ✅ Implemented

### 6. Fleets

#### Create Fleet
- **Method**: `POST`
- **Endpoint**: `/v1/fleets`
- **Request Body**:
  ```json
  {
    "name": "string (required)",
    "description": "string (optional)",
    "project": "string (optional)"
  }
  ```
- **Crossplane CRD**: `fleets.iot.s4t.crossplane.io`
- **Controller**: `internal/controller/fleet/fleet.go`
- **Status**: ✅ Implemented

#### Get Fleet
- **Method**: `GET`
- **Endpoint**: `/v1/fleets/{uuid}`
- **Crossplane**: Read via `Observe()` method
- **Status**: ✅ Implemented

#### Update Fleet
- **Method**: `PATCH`
- **Endpoint**: `/v1/fleets/{uuid}`
- **Crossplane**: Update via `Update()` method
- **Status**: ✅ Implemented

#### Delete Fleet
- **Method**: `DELETE`
- **Endpoint**: `/v1/fleets/{uuid}`
- **Crossplane**: Delete via `Delete()` method
- **Status**: ✅ Implemented

### 7. Webservices

#### Create Webservice
- **Method**: `POST`
- **Endpoint**: `/v1/webservices`
- **Request Body**:
  ```json
  {
    "name": "string (required)",
    "port": "integer (required)",
    "board_uuid": "string (required)",
    "secure": "boolean (optional)"
  }
  ```
- **Crossplane CRD**: `webservices.iot.s4t.crossplane.io`
- **Controller**: `internal/controller/webservice/webservice.go`
- **Status**: ✅ Implemented

#### Get Webservice
- **Method**: `GET`
- **Endpoint**: `/v1/webservices/{uuid}`
- **Crossplane**: Read via `Observe()` method
- **Status**: ✅ Implemented

#### Delete Webservice
- **Method**: `DELETE`
- **Endpoint**: `/v1/webservices/{uuid}`
- **Crossplane**: Delete via `Delete()` method
- **Status**: ✅ Implemented

### 8. Ports

#### Create Port
- **Method**: `PUT`
- **Endpoint**: `/v1/boards/{board_uuid}/ports`
- **Request Body**:
  ```json
  {
    "network": "string (required)",
    "MAC_add": "string (optional)",
    "VIF_name": "string (optional)",
    "ip": "string (optional)"
  }
  ```
- **Crossplane CRD**: `ports.iot.s4t.crossplane.io`
- **Controller**: `internal/controller/port/port.go`
- **Status**: ✅ Implemented

#### Get Port
- **Method**: `GET`
- **Endpoint**: `/v1/ports/{uuid}`
- **Crossplane**: Read via `Observe()` method
- **Status**: ✅ Implemented

#### Delete Port
- **Method**: `DELETE`
- **Endpoint**: `/v1/ports/{uuid}`
- **Crossplane**: Delete via `Delete()` method
- **Status**: ✅ Implemented

### 9. Requests

#### Create Request
- **Method**: `POST`
- **Endpoint**: `/v1/requests`
- **Request Body**:
  ```json
  {
    "destination_uuid": "string (required)",
    "action": "string (required)",
    "type": "integer (required)",
    "project": "string (optional)"
  }
  ```
- **Crossplane CRD**: `requests.iot.s4t.crossplane.io`
- **Controller**: `internal/controller/request/request.go`
- **Status**: ✅ Implemented

#### Get Request
- **Method**: `GET`
- **Endpoint**: `/v1/requests/{uuid}`
- **Crossplane**: Read via `Observe()` method
- **Status**: ✅ Implemented

### 10. Results

#### Get Result
- **Method**: `GET`
- **Endpoint**: `/v1/results/{uuid}`
- **Query Parameters**: `request_uuid` (optional)
- **Crossplane CRD**: `results.iot.s4t.crossplane.io`
- **Controller**: `internal/controller/result/result.go`
- **Status**: ✅ Implemented (read-only)

### 11. Sites

#### Create Site
- **Method**: `POST`
- **Endpoint**: `/v1/sites`
- **Request Body**:
  ```json
  {
    "name": "string (required)",
    "description": "string (optional)",
    "location": "string (optional)"
  }
  ```
- **Crossplane CRD**: `sites.iot.s4t.crossplane.io`
- **Controller**: `internal/controller/site/site.go`
- **Status**: ⚠️ Placeholder (not fully implemented)

## Error Responses

All endpoints return standard HTTP status codes:

- `200 OK`: Success
- `201 Created`: Resource created
- `400 Bad Request`: Invalid request
- `401 Unauthorized`: Authentication required
- `404 Not Found`: Resource not found
- `500 Internal Server Error`: Server error

Error response format:
```json
{
  "error": {
    "message": "Error description",
    "code": "ERROR_CODE"
  }
}
```

## Authentication

All API requests require a Keystone authentication token:

```bash
curl -H "X-Auth-Token: <token>" \
     -H "Content-Type: application/json" \
     http://iotronic-conductor:8812/v1/boards
```

To obtain a token:
```python
from keystoneauth1.identity import v3
from keystoneauth1 import session

auth = v3.Password(
    auth_url='http://keystone:5000/v3',
    username='admin',
    password='s4t',
    project_name='admin',
    user_domain_name='default',
    project_domain_name='default'
)
sess = session.Session(auth=auth)
token = sess.get_token()
```

## Known Issues and Limitations

1. **Plugin Injection**: 
   - Plugin must be injected when board is **online**
   - Injection may not persist in `injected_plugins` table if board goes offline
   - Dashboard reads from API, not directly from database

2. **SDK Method Names**:
   - `PacthPlugin` (typo) instead of `PatchPlugin`
   - `InjectPLuginBoard` (typo) instead of `InjectPluginBoard`

3. **Missing Implementations**:
   - Plugin start/stop actions not mapped to Crossplane
   - Service enable/disable actions not fully mapped
   - Site operations are placeholders

## References

- IoTronic Repository: https://opendev.org/x/iotronic.git
- Crossplane Provider: `crossplane-provider/` directory
- SDK: `github.com/MIKE9708/s4t-sdk-go`
