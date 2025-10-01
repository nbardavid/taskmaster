package client

import (
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/chzyer/readline"
	"github.com/nbardavid/taskmaster/internals/command"
	"github.com/nbardavid/taskmaster/internals/ui"
)

const socketPath = "/tmp/taskmaster.server.sock"
type StateFunc func(*Context) StateFunc
var sigs chan os.Signal

type Queue struct {
	value 	[]string
	head 	int
}

type Connection struct {
	conn net.Conn
	err error
}

//TODO: change any

type Context struct {
	connection Connection
	UI ui.Manager
	Command command.State
	pending Queue
}


func ExitingProperly (ctx *Context) StateFunc {
	ctx.connection.conn.Close()
	ctx.UI.Rl.Close()
	signal.Stop(sigs)
	fmt.Printf("exit\n")
	return nil
}

func SendCommandAndPayload (ctx *Context) StateFunc {
	if len(ctx.Command.Payload) > 255 {
		return SendToLongPayload
	}
	_, ctx.connection.err = ctx.connection.conn.Write([]byte{byte(ctx.Command.Code), byte(len(ctx.Command.Payload))})
	if ctx.connection.err != nil {
		return NeedsToDisconnect
	}
	_, ctx.connection.err = ctx.connection.conn.Write([]byte(ctx.Command.Payload))
	return FetchInputs
}

func SendSimpleCommand (ctx *Context) StateFunc{
	_, ctx.connection.err = ctx.connection.conn.Write([]byte{byte(ctx.Command.Code), 0})
	if ctx.connection.err != nil {
		return NeedsToDisconnect
	}
	return FetchInputs
}

func RouteCommand (ctx *Context) StateFunc {
	if ctx.Command.Payload != "" {
		return SendCommandAndPayload
	}
	return SendSimpleCommand
}

func ParseInputs (ctx *Context) StateFunc {
	ctx.Command, ctx.Command.Err = command.ParseInput(&ctx.Command, &ctx.UI)
	if ctx.Command.Err != nil {
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
	ctx.Command.Input, ctx.Command.Err = ctx.UI.Rl.Readline()
	switch ctx.Command.Err {
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
