package client

import (
	"fmt"
	"net"
	"strings"
	"github.com/chzyer/readline"
)

const socketPath = "/tmp/taskmaster.server.sock"
type StateFunc func(*Context) StateFunc

type CommandCode int8

const (
	status CommandCode = iota
	start
	restart
	stop
	realod
	quit
	dump
)

type Command struct {
	code CommandCode
	payload string
}

type Context struct {
	conn net.Conn
	rl  *readline.Instance 
	cmd Command
	input string
	err error
}

func ParseInput (input string) (Command, error) {
	var cmd Command
	parts := strings.Fields(input)
	if len(parts) == 0 {
		return Command{}, fmt.Errorf("empty input")
	}

	commandPart := parts[0]
	var payload string
	if len(parts) > 1 {
		payload = parts[1]
	}
	switch commandPart {
	case "status":
		cmd.code=status
	case "start":
		cmd.code=start
	case "restart":
		cmd.code=restart
	case "stop":
		cmd.code=stop
	case "realod":
		cmd.code=realod
	case "quit":
		cmd.code=quit
	case "dump":
		cmd.code=dump
	default:
		return Command{}, fmt.Errorf("unknown command: %q", commandPart)
	}
	if payload != "" {
		cmd.payload = payload
	} else {
		cmd.payload = ""
	}
	return cmd, nil
}

func SendCommandAndPayload (ctx *Context) StateFunc {
	if len(ctx.cmd.payload) > 255 {
		return SendToLongPayload
	}
	_, ctx.err = ctx.conn.Write([]byte{byte(ctx.cmd.code), byte(len(ctx.cmd.payload))})
	if ctx.err != nil {
		return NeedsToDisconnect
	}
	_, ctx.err = ctx.conn.Write([]byte(ctx.cmd.payload))
	return FetchInputs
}

func SendSimpleCommand (ctx *Context) StateFunc{
	_, ctx.err = ctx.conn.Write([]byte{byte(ctx.cmd.code), 0})
	if ctx.err != nil {
		return NeedsToDisconnect
	}
	return FetchInputs
}

func RouteCommand (ctx *Context) StateFunc {
	if ctx.cmd.payload != "" {
		return SendCommandAndPayload
	}
	return SendSimpleCommand
}

func ParseInputs (ctx *Context) StateFunc {
	ctx.cmd, ctx.err = ParseInput(ctx.input)
	if ctx.err != nil {
		return ReceivedInvalidCommand
	}
	return RouteCommand
}

func FetchInputs (ctx *Context) StateFunc {
	ctx.input, ctx.err = ctx.rl.Readline()
	if ctx.err != nil {
		return EncounteredFatalError
	}
	return ParseInputs
}

func ConnectedToServer (ctx *Context) StateFunc {
	ctx.rl, ctx.err = readline.New("> ")
	if ctx.err != nil {
		return EncounteredFatalError
	}
	return FetchInputs
}

func DisconnectedFromServer (ctx *Context) StateFunc {
	ctx.conn, ctx.err = net.Dial("unix", socketPath)
	if ctx.err != nil {
		return EncounteredFatalError
	} 
	return ConnectedToServer
}

