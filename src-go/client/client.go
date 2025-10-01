package client

import (
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"strings"
	"time"

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

type Queue struct {
	value 	[]string
	head 	int
}

type Context struct {
	conn net.Conn
	rl  *readline.Instance 
	cmd Command
	input string
	err error
	listenerErr error
	pending Queue
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
	time.Sleep(time.Millisecond * 50)
	for len(ctx.pending.value) > ctx.pending.head {
		print(ctx.pending.value[ctx.pending.head])
		ctx.pending.head++
	}

	ctx.input, ctx.err = ctx.rl.Readline()
	if ctx.err != nil {
		return EncounteredFatalError
	}
	return ParseInputs
}

//TODO: move

type ResponseStatus uint8

const (
	success = iota
	err
	not_found
)

type Response struct {
	status ResponseStatus
	reserved uint8
	payload_len uint16
}

//

func ListenToServer (ctx *Context) {
	buf := make([]byte, 4)

	for {
		if _, err := io.ReadFull(ctx.conn, buf); err != nil {
			ctx.listenerErr = err
			return
		}
		var res = Response{
			status: ResponseStatus(buf[0]), 
			reserved: buf[1],
			payload_len: binary.LittleEndian.Uint16(buf[2:4]),
		}

		payloadBuf := make([]byte, res.payload_len)
		if _, err := io.ReadFull(ctx.conn, payloadBuf); err != nil {
			ctx.listenerErr = err
			return
		}
		ctx.pending.value = append(ctx.pending.value, string(payloadBuf))
	}
}

func ConnectedToServer (ctx *Context) StateFunc {
	ctx.rl, ctx.err = readline.New("> ")
	if ctx.err != nil {
		return EncounteredFatalError
	}
	go ListenToServer((ctx))
	return FetchInputs
}

func DisconnectedFromServer (ctx *Context) StateFunc {
	ctx.conn, ctx.err = net.Dial("unix", socketPath)
	if ctx.err != nil {
		return EncounteredFatalError
	} 
	return ConnectedToServer
}

