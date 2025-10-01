package ui

import (
	"github.com/chzyer/readline"
)

type Color int8 

const (
	Red Color = iota
	Green
	Yellow
)

type setPromptColor func (Color)

type Manager struct {
	Rl *readline.Instance
	Err error
}

func SetPromptColor (m Manager, c Color) {
	switch (c) {
		case Red:
			m.Rl.SetPrompt("\033[32m> \033[0m")
		case Green:
			m.Rl.SetPrompt("\033[31m> \033[0m")
		case Yellow:
			m.Rl.SetPrompt("\033[33m> \033[0m")
	}
}
