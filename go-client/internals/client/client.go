package client

import (
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
	"github.com/nbardavid/taskmaster/internals/ui"
	"github.com/chzyer/readline"
)

const socketPath = "/tmp/taskmaster.server.sock"
type StateFunc func(*Context) StateFunc
var sigs chan os.Signal

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

type Queue struct {
	value 	[]string
	head 	int
}

type Connection struct {
	conn net.Conn
	err error
}

type CommandState struct {
	code CommandCode
	input string
	payload string
	err error
}

//TODO: change any

type Context struct {
	connection Connection
	UI ui.Manager
	Command CommandState
	pending Queue
}

func ParseInput (ctx *Context) (CommandState, error) {
	var cmd CommandState
	parts := strings.Fields(ctx.Command.input)
	if len(parts) == 0 {
		return CommandState{}, fmt.Errorf("empty input")
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
		ui.SetPromptColor(ctx.UI, ui.Yellow)
		return CommandState{}, fmt.Errorf("unknown command: %q", commandPart)
	}
	if payload != "" {
		cmd.payload = payload
	} else {
		cmd.payload = ""
	}
	return cmd, nil
}

func ExitingProperly (ctx *Context) StateFunc {
	ctx.connection.conn.Close()
	ctx.UI.Rl.Close()
	signal.Stop(sigs)
	fmt.Printf("exit\n")
	return nil
}

func SendCommandAndPayload (ctx *Context) StateFunc {
	if len(ctx.Command.payload) > 255 {
		return SendToLongPayload
	}
	_, ctx.connection.err = ctx.connection.conn.Write([]byte{byte(ctx.Command.code), byte(len(ctx.Command.payload))})
	if ctx.connection.err != nil {
		return NeedsToDisconnect
	}
	_, ctx.connection.err = ctx.connection.conn.Write([]byte(ctx.Command.payload))
	return FetchInputs
}

func SendSimpleCommand (ctx *Context) StateFunc{
	_, ctx.connection.err = ctx.connection.conn.Write([]byte{byte(ctx.Command.code), 0})
	if ctx.connection.err != nil {
		return NeedsToDisconnect
	}
	return FetchInputs
}

func RouteCommand (ctx *Context) StateFunc {
	if ctx.Command.payload != "" {
		return SendCommandAndPayload
	}
	return SendSimpleCommand
}

func ParseInputs (ctx *Context) StateFunc {
	ctx.Command, ctx.Command.err = ParseInput(ctx)
	if ctx.Command.err != nil {
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
	ctx.Command.input, ctx.Command.err = ctx.UI.Rl.Readline()
	switch ctx.Command.err {
	case io.EOF:
		return ExitingProperly
	case readline.ErrInterrupt:
		ui.SetPromptColor(ctx.UI, ui.Red)
		return FetchInputs
	}
	return ParseInputs
}

func IgnoreSigint() {
    sigs = make(chan os.Signal, 1)
    signal.Notify(sigs, syscall.SIGINT)
    go func() {
        for range sigs {
        }
    }()
}

func ConnectedToServer (ctx *Context) StateFunc {
	ctx.UI.Rl, ctx.UI.Err = readline.New("> ")
	if ctx.UI.Err != nil {
		return EncounteredFatalError
	}
	IgnoreSigint()
	go ListenToServer((ctx))
	return FetchInputs
}

func DisconnectedFromServer (ctx *Context) StateFunc {
	ctx.connection.conn, ctx.connection.err = net.Dial("unix", socketPath)
	if ctx.connection.conn != nil {
		return EncounteredFatalError
	} 
	return ConnectedToServer
}
