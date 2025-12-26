# Taskmaster

A robust process supervisor written in Zig, similar to supervisord or systemd. Taskmaster manages and monitors multiple long-running processes with automatic restart capabilities, HTTP REST API control, and hot configuration reloading.

## Features

- **Process Management**: Start, stop, restart, and monitor multiple processes
- **Automatic Restart**: Configurable restart policies (always, never, unexpected)
- **Process Lifecycle**: Complete state machine with stability checks and retry logic
- **HTTP REST API**: Full-featured JSON API for remote control and monitoring
- **Hot Reload**: Update configuration without stopping running processes
- **Process Groups**: Manage multiple instances of the same program
- **Output Redirection**: Capture stdout/stderr to files
- **Signal Handling**: Graceful shutdown with configurable stop signals
- **Resource Control**: Working directory, umask, and environment variables per program
- **Comprehensive Logging**: Structured event logging for all process lifecycle events

## Quick Start

### Build

```bash
zig build
```

### Run

```bash
./zig-out/bin/server config.json
```

The supervisor will start on `http://127.0.0.1:8080` by default.

## Configuration

Create a `config.json` file with your program definitions:

```json
{
  "programs": {
    "my_app": {
      "cmd": "/path/to/executable",
      "argv": ["arg1", "arg2"],
      "numprocs": 2,
      "autostart": true,
      "autorestart": "unexpected",
      "exitcodes": [0],
      "starttime": 1,
      "startsecs": 3,
      "startretries": 3,
      "stopsignal": "TERM",
      "stoptime": 10,
      "stdout": "/var/log/my_app.log",
      "stderr": "/var/log/my_app.err",
      "workingdir": "/app",
      "umask": 22,
      "env": {
        "ENV_VAR": "value"
      }
    }
  }
}
```

### Configuration Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `cmd` | string | required | Path to the executable |
| `argv` | array | `[]` | Command line arguments |
| `numprocs` | integer | `1` | Number of process instances to maintain |
| `autostart` | boolean | `true` | Start program when supervisor launches |
| `autorestart` | string | `"unexpected"` | When to restart: `"always"`, `"never"`, `"unexpected"` |
| `exitcodes` | array | `[0]` | Exit codes considered "expected" |
| `starttime` | integer | `1` | Seconds to wait before considering process started |
| `startsecs` | integer | `1` | Seconds process must stay running to be considered stable |
| `startretries` | integer | `3` | Max restart attempts before giving up |
| `stopsignal` | string | `"TERM"` | Signal to send when stopping (TERM, KILL, INT, etc.) |
| `stoptime` | integer | `10` | Seconds to wait before force-killing process |
| `stdout` | string | `null` | Path to redirect stdout |
| `stderr` | string | `null` | Path to redirect stderr |
| `workingdir` | string | `null` | Working directory for the process |
| `umask` | integer | `null` | Umask for the process |
| `env` | object | `null` | Environment variables |

## REST API Documentation

The supervisor provides a comprehensive REST API for monitoring and control.

### Base URL

```
http://127.0.0.1:8080
```

### API Endpoints

#### Health Check

Check if the supervisor is running and healthy.

**Request:**
```http
GET /
```

**Response:**
```json
{
  "success": true,
  "status": "healthy",
  "version": "1.0.0",
  "uptime_seconds": 123,
  "port": 8080
}
```

---

#### API Information

Get information about all available endpoints.

**Request:**
```http
GET /api
```

**Response:**
```json
{
  "success": true,
  "version": "1.0.0",
  "endpoints": {
    "health": {
      "method": "GET",
      "path": "/",
      "description": "Health check endpoint"
    },
    "api_info": {
      "method": "GET",
      "path": "/api",
      "description": "API information and available endpoints"
    },
    "status": {
      "method": "GET",
      "path": "/status",
      "description": "Get status of all programs with full configuration"
    },
    "program_status": {
      "method": "GET",
      "path": "/programs/:name",
      "description": "Get detailed status of a specific program including all processes"
    },
    "program_start": {
      "method": "POST",
      "path": "/programs/:name/start",
      "description": "Start a program"
    },
    "program_stop": {
      "method": "POST",
      "path": "/programs/:name/stop",
      "description": "Stop a program"
    },
    "program_restart": {
      "method": "POST",
      "path": "/programs/:name/restart",
      "description": "Restart a program"
    },
    "reload": {
      "method": "POST",
      "path": "/reload",
      "description": "Reload configuration from file"
    },
    "shutdown": {
      "method": "POST",
      "path": "/shutdown",
      "description": "Gracefully shutdown the supervisor"
    }
  }
}
```

---

#### Get All Programs Status

Get status of all programs with their complete configuration.

**Request:**
```http
GET /status
```

**Response:**
```json
{
  "success": true,
  "timestamp": 36845554439558,
  "server_uptime_seconds": 123,
  "total_programs": 2,
  "programs": [
    {
      "name": "my_app",
      "state": "running",
      "running": 2,
      "alive": 2,
      "total": 2,
      "uptime_seconds": 456,
      "fatal_count": 0,
      "config": {
        "cmd": "/path/to/executable",
        "numprocs": 2,
        "autostart": true,
        "autorestart": "unexpected",
        "start_delay_seconds": 1,
        "startsecs": 3,
        "start_retries": 3,
        "stop_signal": "SIGTERM",
        "stop_timeout_seconds": 10,
        "redirect_stdout": true,
        "redirect_stderr": true,
        "stdout_path": "/var/log/my_app.log",
        "stderr_path": "/var/log/my_app.err",
        "working_directory": "/app",
        "umask": 22,
        "exitcodes": [0]
      }
    }
  ]
}
```

**Fields:**
- `name`: Program name
- `state`: Group state (stopped, starting, running, stopping, fatal)
- `running`: Number of processes in "running" state
- `alive`: Number of processes that are alive (starting, running, or stopping)
- `total`: Total number of configured processes
- `uptime_seconds`: Total uptime across all processes
- `fatal_count`: Number of processes that exceeded retry limit
- `config`: Complete program configuration

---

#### Get Program Details

Get detailed status of a specific program, including individual process information.

**Request:**
```http
GET /programs/:name
```

**Response:**
```json
{
  "success": true,
  "program": {
    "name": "my_app",
    "state": "running",
    "running": 2,
    "alive": 2,
    "total": 2,
    "uptime_seconds": 456,
    "fatal_count": 0,
    "config": {
      "cmd": "/path/to/executable",
      "numprocs": 2,
      "autostart": true,
      "autorestart": "unexpected",
      "start_delay_seconds": 1,
      "startsecs": 3,
      "start_retries": 3,
      "stop_signal": "SIGTERM",
      "stop_timeout_seconds": 10,
      "redirect_stdout": true,
      "redirect_stderr": true,
      "stdout_path": "/var/log/my_app.log",
      "stderr_path": "/var/log/my_app.err",
      "working_directory": "/app",
      "umask": 22,
      "exitcodes": [0]
    },
    "processes": [
      {
        "id": 0,
        "pid": 12345,
        "state": "running",
        "uptime_seconds": 234,
        "retries_count": 0,
        "is_stable": true
      },
      {
        "id": 1,
        "pid": 12346,
        "state": "running",
        "uptime_seconds": 234,
        "retries_count": 0,
        "is_stable": true
      }
    ]
  }
}
```

**Process States:**
- `stopped`: Process is not running
- `starting`: Process is starting (within starttime window)
- `running`: Process is running and has passed stability check
- `stopping`: Process is being stopped
- `exited`: Process has exited
- `killed`: Process was force-killed
- `backoff`: Process is waiting before retry

---

#### Start Program

Start a program that is currently stopped.

**Request:**
```http
POST /programs/:name/start
```

**Response (Success):**
```json
{
  "success": true,
  "message": "Program started"
}
```

**Response (Already Running):**
```json
{
  "success": false,
  "err": {
    "code": 409,
    "message": "Program already running",
    "detail": "Stop the program first or use restart"
  }
}
```

---

#### Stop Program

Stop a running program.

**Request:**
```http
POST /programs/:name/stop
```

**Response:**
```json
{
  "success": true,
  "message": "Program stopped"
}
```

---

#### Restart Program

Restart a program (stop then start).

**Request:**
```http
POST /programs/:name/restart
```

**Response:**
```json
{
  "success": true,
  "message": "Program restarted"
}
```

---

#### Reload Configuration

Reload configuration from file without stopping running processes. Changes are applied intelligently:

- **Programs added**: Created and auto-started if configured
- **Programs removed**: Stopped and removed
- **Programs modified**:
  - Respawned if command, args, env, working directory, or umask changed
  - Scaled up/down if numprocs changed
  - Updated in-place if only runtime config changed (autorestart, signals, etc.)
- **Programs unchanged**: Left running

**Request:**
```http
POST /reload
```

**Response:**
```json
{
  "success": true,
  "message": "Reload scheduled"
}
```

---

#### Shutdown Supervisor

Gracefully shutdown the supervisor and all managed processes.

**Request:**
```http
POST /shutdown
```

**Response:**
```json
{
  "success": true,
  "message": "Shutdown scheduled"
}
```

---

### Error Responses

All errors follow a consistent format:

```json
{
  "success": false,
  "err": {
    "code": 404,
    "message": "Program not found",
    "detail": "No program with that name is configured"
  }
}
```

**HTTP Status Codes:**
- `200 OK`: Request successful
- `400 Bad Request`: Invalid request parameters
- `404 Not Found`: Resource not found
- `405 Method Not Allowed`: Invalid HTTP method for endpoint
- `409 Conflict`: Request conflicts with current state
- `500 Internal Server Error`: Server-side error

---

### Example Usage with curl

```bash
# Health check
curl http://127.0.0.1:8080/

# Get all programs status with full config
curl http://127.0.0.1:8080/status

# Get detailed program info including processes
curl http://127.0.0.1:8080/programs/my_app

# Start a program
curl -X POST http://127.0.0.1:8080/programs/my_app/start

# Stop a program
curl -X POST http://127.0.0.1:8080/programs/my_app/stop

# Restart a program
curl -X POST http://127.0.0.1:8080/programs/my_app/restart

# Reload configuration
curl -X POST http://127.0.0.1:8080/reload

# Shutdown supervisor
curl -X POST http://127.0.0.1:8080/shutdown
```

---

### Example Usage with Python

A Python client is included in `scripts/tm_client.py`:

```python
import tm_client

# Get all programs status
client = tm_client.TaskmasterClient()
status = client.get_status()

# Get specific program
program = client.get_program("my_app")

# Control programs
client.start_program("my_app")
client.stop_program("my_app")
client.restart_program("my_app")

# Reload config
client.reload()
```

## Signal Handling

The supervisor handles the following signals:

- **SIGTERM / SIGINT**: Graceful shutdown (stops all processes)
- **SIGHUP**: Reload configuration

```bash
# Graceful shutdown
kill -TERM <supervisor_pid>

# Reload configuration
kill -HUP <supervisor_pid>
```

## Logging

Logs are written to `/tmp/taskmaster.log` by default and also to stderr. All process lifecycle events are logged with timestamps:

- Program started/stopped/restarted
- Process failures and exits
- Configuration reloads
- API requests

## Architecture

```
┌─────────────────────────────────────┐
│     HTTP REST API (Port 8080)      │
├─────────────────────────────────────┤
│    ProcessGroupManager              │
│  - Config hot reload                │
│  - Group lifecycle management       │
├─────────────────────────────────────┤
│    ProcessGroup (per program)       │
│  - Multiple process instances       │
│  - Auto-restart logic               │
│  - Scaling (numprocs)               │
├─────────────────────────────────────┤
│    Process (per instance)           │
│  - State machine                    │
│  - Stability checking               │
│  - Retry/backoff logic              │
└─────────────────────────────────────┘
```

## Testing

### Unit Tests

```bash
zig build test
```

### Integration Tests

```bash
# Start the supervisor
./zig-out/bin/server config.json &

# Run Python integration tests
python3 scripts/integration_test.py
```

## License

MIT License - see LICENSE file for details.

## Contributing

Contributions are welcome! Please ensure all tests pass before submitting a pull request.

## Author

Built with Zig for robustness and performance.
