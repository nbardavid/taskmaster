package command

import (
	"fmt"
	"strings"
	"github.com/nbardavid/taskmaster/internals/ui"
)

type Code int8

const (
	status Code = iota
	start
	restart
	stop
	reload
	quit
	dump
)

type State struct {
	Code Code
	Input string
	Payload string
	Err error
}

func ParseInput (state *State, UI *ui.Manager) (State, error) {
	var cmd State
	parts := strings.Fields(state.Input)
	if len(parts) == 0 {
		return State{}, fmt.Errorf("empty input")
	}

	commandPart := parts[0]
	var payload string
	if len(parts) > 1 {
		payload = parts[1]
	}
	switch commandPart {
	case "status":
		cmd.Code=status
	case "start":
		cmd.Code=start
	case "restart":
		cmd.Code=restart
	case "stop":
		cmd.Code=stop
	case "reload":
		cmd.Code=reload
	case "quit":
		cmd.Code=quit
	case "dump":
		cmd.Code=dump
	default:
		ui.SetPromptColor(*UI, ui.Yellow)
		return State{}, fmt.Errorf("unknown command: %q", commandPart)
	}
	if payload != "" {
		cmd.Payload = payload
	} else {
		cmd.Payload = ""
	}
	return cmd, nil
}
