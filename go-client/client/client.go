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
	prompt string
	pending Queue
}

func ParseInput (ctx *Context) (Command, error) {
	var cmd Command
	parts := strings.Fields(ctx.input)
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
		ctx.prompt = "\033[33m> \033[0m"
		return Command{}, fmt.Errorf("unknown command: %q", commandPart)
	}
	if payload != "" {
		cmd.payload = payload
	} else {
		cmd.payload = ""
	}
	return cmd, nil
}

func ExitingProperly (ctx *Context) StateFunc {
	ctx.conn.Close()
	ctx.rl.Close()
	signal.Stop(sigs)
	fmt.Printf("exit\n")
	return nil
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
	ctx.cmd, ctx.err = ParseInput(ctx)
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
	ctx.rl.SetPrompt(ctx.prompt)
	ctx.input, ctx.err = ctx.rl.Readline()
	switch ctx.err {
	case io.EOF:
		return ExitingProperly
	case readline.ErrInterrupt:
		ctx.prompt = "\033[31m> \033[0m"
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
	ctx.prompt = "\033[32m>\033[0m "
	ctx.rl, ctx.err = readline.New(ctx.prompt)
	if ctx.err != nil {
		return EncounteredFatalError
	}
	IgnoreSigint()
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

