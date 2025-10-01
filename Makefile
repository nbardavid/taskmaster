ZIG = zig
GO = go
BUILD_DIR = zig-out
SERVER_BIN = $(BUILD_DIR)/bin/taskmaster-server
CLIENT_BIN = $(BUILD_DIR)/bin/taskmaster-client
GO_CLIENT_BIN = go-client/taskmaster-client

all: zig go

zig:
	$(ZIG) build

go:
	cd go-client && $(GO) build -o taskmaster-client ./main.go

run-server: zig
	$(SERVER_BIN)

run-client: go
	$(GO_CLIENT_BIN)

clean:
	rm -rf $(BUILD_DIR)
	rm -f $(GO_CLIENT_BIN)

fclean: clean
	rm -f taskmaster.log

re: fclean all
