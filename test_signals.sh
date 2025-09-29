#!/bin/bash

# Signal handling test script for taskmaster server
# Usage: ./test_signals.sh

set -e

echo "=== Taskmaster Signal Handling Test Suite ==="
echo

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Build fresh binary
echo -e "${BLUE}Building fresh binary...${NC}"
zig build
echo

# Configuration files
CONFIG_FILE="config.json"
SOCKET_FILE="/tmp/taskmaster_test.sock"
LOG_FILE="./taskmaster_test.log"

# Clean up any existing processes and files
cleanup() {
    echo -e "\n${YELLOW}Cleaning up...${NC}"
    pkill -f taskmaster || true
    rm -f "$SOCKET_FILE" "$LOG_FILE"
    sleep 1
}

# Start server in background
start_server() {
    echo -e "${BLUE}Starting taskmaster server...${NC}"
    ./zig-out/bin/taskmaster "$CONFIG_FILE" "$SOCKET_FILE" > server_output.log 2>&1 &
    SERVER_PID=$!
    echo "Server PID: $SERVER_PID"
    sleep 2

    if ! kill -0 $SERVER_PID 2>/dev/null; then
        echo -e "${RED}Failed to start server${NC}"
        cat server_output.log
        exit 1
    fi
}

# Wait for signal processing
wait_for_processing() {
    echo "  Waiting for signal processing..."
    sleep 2
}

# Test function template
test_signal() {
    local signal_name=$1
    local signal_num=$2
    local expected_msg=$3

    echo -e "${BLUE}Testing $signal_name...${NC}"
    echo "  Sending $signal_name to PID $SERVER_PID"

    kill "$signal_num" $SERVER_PID
    wait_for_processing

    if grep -q "$expected_msg" server_output.log; then
        echo -e "  ${GREEN}✓ $signal_name handled correctly${NC}"
    else
        echo -e "  ${RED}✗ $signal_name not handled properly${NC}"
        echo "  Expected: $expected_msg"
    fi
    echo
}

# Main test execution
main() {
    trap cleanup EXIT
    cleanup
    start_server

    echo -e "${YELLOW}=== Phase 1: Basic Signal Functionality ===${NC}"

    # Test SIGHUP (configuration reload)
    test_signal "SIGHUP" "-HUP" "received SIGHUP - reloading configuration"

    # Test SIGUSR1 (dump command)
    test_signal "SIGUSR1" "-USR1" "received SIGUSR1 - dumping process status"

    # Test SIGUSR2 (status command)
    test_signal "SIGUSR2" "-USR2" "received SIGUSR2 - logging status information"

    echo -e "${YELLOW}=== Phase 2: Concurrency Testing ===${NC}"
    echo -e "${BLUE}Testing rapid signal sending...${NC}"

    # Send multiple SIGHUP signals rapidly
    for i in {1..5}; do
        kill -HUP $SERVER_PID
        sleep 0.1
    done

    sleep 2
    sighup_count=$(grep -c "received SIGHUP" server_output.log)
    echo "  SIGHUP signals processed: $sighup_count"

    if [ "$sighup_count" -ge 5 ]; then
        echo -e "  ${GREEN}✓ Concurrency test passed${NC}"
    else
        echo -e "  ${RED}✗ Some signals may have been lost${NC}"
    fi
    echo

    echo -e "${YELLOW}=== Phase 3: Graceful Shutdown Testing ===${NC}"

    # Test SIGTERM (graceful shutdown)
    echo -e "${BLUE}Testing SIGTERM (graceful shutdown)...${NC}"
    echo "  Sending SIGTERM to PID $SERVER_PID"

    kill -TERM $SERVER_PID
    sleep 3

    if ! kill -0 $SERVER_PID 2>/dev/null; then
        echo -e "  ${GREEN}✓ Server shut down gracefully${NC}"
        if grep -q "server stopped cleanly" server_output.log; then
            echo -e "  ${GREEN}✓ Clean shutdown message found${NC}"
        else
            echo -e "  ${YELLOW}! Clean shutdown message not found${NC}"
        fi
    else
        echo -e "  ${RED}✗ Server did not shut down${NC}"
        kill -9 $SERVER_PID 2>/dev/null || true
    fi

    echo
    echo -e "${YELLOW}=== Test Results Summary ===${NC}"
    echo "Check server_output.log for detailed output"
    echo "Check stderr output for signal detection messages"

    # Show last few lines of output
    echo -e "\n${BLUE}Last 10 lines of server output:${NC}"
    tail -10 server_output.log || echo "No output file found"
}

# Check if config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}Error: $CONFIG_FILE not found${NC}"
    echo "Please ensure config.json exists in the current directory"
    exit 1
fi

# Run main test function
main