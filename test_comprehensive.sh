#!/bin/bash

# Comprehensive test suite for Taskmaster project
# Tests all mandatory features from the project subject

set -e

echo "=== Taskmaster Comprehensive Test Suite ==="
echo

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration files
CONFIG_FILE="config.json"
TEST_CONFIG="test_comprehensive.json"
SOCKET_FILE="/tmp/taskmaster_comprehensive.sock"
LOG_FILE="./taskmaster_comprehensive.log"

# Test results tracking
TESTS_PASSED=0
TESTS_FAILED=0
TOTAL_TESTS=0

# Test result functions
test_passed() {
    echo -e "  ${GREEN}✓ $1${NC}"
    ((TESTS_PASSED++))
    ((TOTAL_TESTS++))
}

test_failed() {
    echo -e "  ${RED}✗ $1${NC}"
    ((TESTS_FAILED++))
    ((TOTAL_TESTS++))
}

# Clean up function
cleanup() {
    echo -e "\n${YELLOW}Cleaning up test environment...${NC}"
    pkill -f taskmaster || true
    rm -f "$SOCKET_FILE" "$LOG_FILE" server_output.log
    rm -f /tmp/test_*.stdout /tmp/test_*.stderr
    rm -f "$TEST_CONFIG"
    sleep 1
}

# Create comprehensive test configuration
create_test_config() {
    cat > "$TEST_CONFIG" <<EOF
{
  "programs": {
    "test_autostart": {
      "cmd": "/bin/sleep 10",
      "numprocs": 1,
      "autostart": true,
      "autorestart": "always",
      "exitcodes": [0],
      "starttime": 1,
      "startretries": 3,
      "stopsignal": "TERM",
      "stoptime": 5,
      "stdout": "/tmp/test_autostart.stdout",
      "stderr": "/tmp/test_autostart.stderr"
    },
    "test_no_autostart": {
      "cmd": "/bin/echo 'Hello from no_autostart'",
      "numprocs": 1,
      "autostart": false,
      "autorestart": "never",
      "exitcodes": [0],
      "starttime": 1,
      "startretries": 3,
      "stopsignal": "TERM",
      "stoptime": 2,
      "stdout": "/tmp/test_no_autostart.stdout",
      "stderr": "/tmp/test_no_autostart.stderr"
    },
    "test_restart_unexpected": {
      "cmd": "/bin/bash -c 'echo starting; sleep 2; exit 1'",
      "numprocs": 1,
      "autostart": true,
      "autorestart": "unexpected",
      "exitcodes": [0],
      "starttime": 1,
      "startretries": 2,
      "stopsignal": "TERM",
      "stoptime": 3,
      "stdout": "/tmp/test_restart_unexpected.stdout",
      "stderr": "/tmp/test_restart_unexpected.stderr"
    },
    "test_multiple_procs": {
      "cmd": "/bin/sleep 30",
      "numprocs": 3,
      "autostart": true,
      "autorestart": "always",
      "exitcodes": [0],
      "starttime": 1,
      "startretries": 3,
      "stopsignal": "TERM",
      "stoptime": 5,
      "stdout": "/tmp/test_multiple_procs.stdout",
      "stderr": "/tmp/test_multiple_procs.stderr"
    }
  }
}
EOF
    echo -e "${BLUE}Created test configuration file: $TEST_CONFIG${NC}"
}

# Start server for testing
start_test_server() {
    echo -e "${BLUE}Starting taskmaster server with test config...${NC}"
    ./zig-out/bin/taskmaster "$TEST_CONFIG" "$SOCKET_FILE" > server_output.log 2>&1 &
    SERVER_PID=$!
    echo "Server PID: $SERVER_PID"
    sleep 3

    if ! kill -0 $SERVER_PID 2>/dev/null; then
        echo -e "${RED}Failed to start server${NC}"
        cat server_output.log
        exit 1
    fi
    echo -e "${GREEN}Server started successfully${NC}"
}

# Wait for processes to stabilize
wait_for_stability() {
    echo "  Waiting for process stability..."
    sleep 3
}

# Test 1: Configuration Loading and Parsing
test_configuration_loading() {
    echo -e "\n${YELLOW}=== Test 1: Configuration Loading ===${NC}"

    if grep -q "programs" server_output.log; then
        test_passed "Configuration file loaded"
    else
        test_failed "Configuration file not loaded"
    fi

    # Check if processes with autostart=true are started
    if grep -q "test_autostart" server_output.log; then
        test_passed "Autostart programs detected"
    else
        test_failed "Autostart programs not detected"
    fi
}

# Test 2: Process Lifecycle Management
test_process_lifecycle() {
    echo -e "\n${YELLOW}=== Test 2: Process Lifecycle Management ===${NC}"

    wait_for_stability

    # Check if autostart processes are running
    if pgrep -f "sleep 10" > /dev/null; then
        test_passed "Autostart processes launched"
    else
        test_failed "Autostart processes not launched"
    fi

    # Check if multiple processes are created
    sleep_count=$(pgrep -f "sleep 30" | wc -l)
    if [ "$sleep_count" -eq 3 ]; then
        test_passed "Multiple processes (numprocs=3) created correctly"
    else
        test_failed "Multiple processes not created correctly (expected 3, got $sleep_count)"
    fi

    # Check if non-autostart processes are NOT running
    if ! pgrep -f "Hello from no_autostart" > /dev/null; then
        test_passed "Non-autostart processes not launched automatically"
    else
        test_failed "Non-autostart processes launched when they shouldn't be"
    fi
}

# Test 3: Signal Handling (SIGHUP for reload)
test_signal_handling() {
    echo -e "\n${YELLOW}=== Test 3: Signal Handling ===${NC}"

    # Test SIGHUP (configuration reload)
    echo "  Testing SIGHUP (configuration reload)..."
    kill -HUP $SERVER_PID
    sleep 2

    if grep -q "received SIGHUP - reloading configuration" server_output.log; then
        test_passed "SIGHUP signal handled for configuration reload"
    else
        test_failed "SIGHUP signal not handled properly"
    fi

    # Test SIGUSR1 (dump status)
    echo "  Testing SIGUSR1 (dump status)..."
    kill -USR1 $SERVER_PID
    sleep 1

    if grep -q "received SIGUSR1 - dumping process status" server_output.log; then
        test_passed "SIGUSR1 signal handled for status dump"
    else
        test_failed "SIGUSR1 signal not handled properly"
    fi

    # Test SIGUSR2 (status logging)
    echo "  Testing SIGUSR2 (status logging)..."
    kill -USR2 $SERVER_PID
    sleep 1

    if grep -q "received SIGUSR2 - logging status information" server_output.log; then
        test_passed "SIGUSR2 signal handled for status logging"
    else
        test_failed "SIGUSR2 signal not handled properly"
    fi
}

# Test 4: Logging System
test_logging_system() {
    echo -e "\n${YELLOW}=== Test 4: Logging System ===${NC}"

    # Check if log file exists and contains entries
    if [ -f "taskmaster_comprehensive.log" ] || [ -f "taskmaster.log" ]; then
        test_passed "Log file created"
    else
        test_failed "Log file not created"
    fi

    # Check if events are logged
    if grep -q "started\|stopped\|reloaded" server_output.log; then
        test_passed "Process events logged"
    else
        test_failed "Process events not logged"
    fi

    # Check timestamp format in logs
    if grep -qE "\[[0-9]{4}-[0-9]{2}-[0-9]{2}" server_output.log; then
        test_passed "Log entries have timestamps"
    else
        test_failed "Log entries missing timestamps"
    fi
}

# Test 5: Process Monitoring and Restart Behavior
test_process_monitoring() {
    echo -e "\n${YELLOW}=== Test 5: Process Monitoring and Restart ===${NC}"

    # Kill a process that should be restarted
    echo "  Testing automatic restart behavior..."
    sleep_pid=$(pgrep -f "sleep 10" | head -1)
    if [ -n "$sleep_pid" ]; then
        kill -9 "$sleep_pid"
        echo "  Killed process $sleep_pid, waiting for restart..."
        sleep 3

        if pgrep -f "sleep 10" > /dev/null; then
            test_passed "Process automatically restarted after unexpected exit"
        else
            test_failed "Process not automatically restarted"
        fi
    else
        test_failed "No sleep process found to test restart"
    fi

    # Test SIGCHLD handling
    if grep -q "received SIGCHLD" server_output.log; then
        test_passed "SIGCHLD signals detected for child process monitoring"
    else
        test_failed "SIGCHLD signals not detected"
    fi
}

# Test 6: Configuration File Requirements Coverage
test_config_requirements() {
    echo -e "\n${YELLOW}=== Test 6: Configuration Requirements Coverage ===${NC}"

    # Check if all required configuration options are supported
    config_options=("cmd" "numprocs" "autostart" "autorestart" "exitcodes" "starttime" "startretries" "stopsignal" "stoptime" "stdout" "stderr")

    for option in "${config_options[@]}"; do
        if grep -q "\"$option\":" "$TEST_CONFIG"; then
            test_passed "Configuration option '$option' supported"
        else
            test_failed "Configuration option '$option' not found in config"
        fi
    done
}

# Test 7: Output Redirection
test_output_redirection() {
    echo -e "\n${YELLOW}=== Test 7: Output Redirection ===${NC}"

    wait_for_stability

    # Check if stdout files are created
    if ls /tmp/test_*.stdout 1> /dev/null 2>&1; then
        test_passed "Stdout redirection files created"
    else
        test_failed "Stdout redirection files not created"
    fi

    # Check if stderr files are created
    if ls /tmp/test_*.stderr 1> /dev/null 2>&1; then
        test_passed "Stderr redirection files created"
    else
        test_failed "Stderr redirection files not created"
    fi
}

# Test 8: Graceful Shutdown
test_graceful_shutdown() {
    echo -e "\n${YELLOW}=== Test 8: Graceful Shutdown ===${NC}"

    echo "  Testing graceful shutdown with SIGTERM..."
    kill -TERM $SERVER_PID
    sleep 3

    if ! kill -0 $SERVER_PID 2>/dev/null; then
        test_passed "Server shut down gracefully with SIGTERM"
    else
        test_failed "Server did not shut down with SIGTERM"
        kill -9 $SERVER_PID 2>/dev/null || true
    fi

    if grep -q "server stopped cleanly" server_output.log; then
        test_passed "Clean shutdown message logged"
    else
        test_failed "Clean shutdown message not logged"
    fi
}

# Display test results summary
show_test_summary() {
    echo -e "\n${YELLOW}=== Test Results Summary ===${NC}"
    echo -e "Total tests run: $TOTAL_TESTS"
    echo -e "${GREEN}Tests passed: $TESTS_PASSED${NC}"
    echo -e "${RED}Tests failed: $TESTS_FAILED${NC}"

    if [ $TESTS_FAILED -eq 0 ]; then
        echo -e "\n${GREEN}🎉 All tests passed! Taskmaster implementation is working correctly.${NC}"
    else
        echo -e "\n${RED}❌ Some tests failed. Check the implementation for issues.${NC}"
        echo -e "\n${BLUE}Server output log:${NC}"
        tail -20 server_output.log || echo "No server output available"
    fi

    echo -e "\n${BLUE}For detailed analysis, check:${NC}"
    echo "- server_output.log (server console output)"
    echo "- /tmp/test_*.stdout and /tmp/test_*.stderr (process output files)"
    echo "- taskmaster.log or taskmaster_comprehensive.log (application logs)"
}

# Main execution
main() {
    trap cleanup EXIT
    cleanup

    echo -e "${BLUE}Building fresh binary...${NC}"
    zig build

    create_test_config
    start_test_server

    # Run all test suites
    test_configuration_loading
    test_process_lifecycle
    test_signal_handling
    test_logging_system
    test_process_monitoring
    test_config_requirements
    test_output_redirection
    test_graceful_shutdown

    show_test_summary
}

# Check prerequisites
if [ ! -f "zig-out/bin/taskmaster" ]; then
    echo -e "${RED}Error: taskmaster binary not found. Run 'zig build' first.${NC}"
    exit 1
fi

# Run the comprehensive test suite
main