package ui

import (
	"context"

	tea "github.com/charmbracelet/bubbletea"
	message "github.com/nbardavid/taskmaster-tui/internals/ui/msg"
	"github.com/nbardavid/taskmaster-tui/internals/ui/screens"
	// "github.com/nbardavid/taskmaster-tui/internals/worker"
)

type Screen int
const (
	ScreenDisconnect Screen = iota
	ScreenChooseProgram
	ScreenDetail
)

type RootModel struct {
	stopWorker	context.CancelFunc
	// Ctx 		worker.WorkerContext
	screen      Screen
	disconnect  screens.DisconnectModel
	choose      screens.ChooseModel
	detail      screens.DetailModel
}

func InitRootscreens(cancel context.CancelFunc) RootModel {
	return RootModel{
		stopWorker: cancel,
		// Ctx:		worker.WorkerContext{},
		screen:     ScreenDisconnect,
		disconnect: screens.InitDisconnectModel(),
		choose:     screens.InitChooseModel(),
		detail:     screens.InitDetailModel(),
	}
}

func (m *RootModel) View() string {
	switch m.screen {
	case ScreenDisconnect:
		return m.disconnect.View()
	case ScreenChooseProgram:
		return m.choose.View()
	case ScreenDetail:
		return m.detail.View()
	default:
		return ""
	}
}

func (m *RootModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case message.ConnectionSuccessMsg:
		m.screen = ScreenChooseProgram
		return m, m.choose.Init()

	case tea.KeyMsg:
		switch msg.String() {
		case "q", "ctrl+c":
			m.stopWorker()
			return m, tea.Quit
		}
	}


	switch m.screen {
	case ScreenDisconnect:
		updated, cmd := m.disconnect.Update(msg)
		if um, ok := updated.(screens.DisconnectModel); ok {
			m.disconnect = um
		}
		return m, cmd

	case ScreenChooseProgram:
		updated, cmd := m.choose.Update(msg)
		if um, ok := updated.(screens.ChooseModel); ok {
			m.choose = um
		}
		return m, cmd

	case ScreenDetail:
		updated, cmd := m.detail.Update(msg)
		if um, ok := updated.(screens.DetailModel); ok {
			m.detail = um
		}
		return m, cmd
	}

	return m, nil
}

func (m *RootModel) Init() tea.Cmd {
	switch m.screen {
	case ScreenDisconnect:
		return m.disconnect.Init()
	case ScreenChooseProgram:
		return m.choose.Init()
	case ScreenDetail:
		return m.detail.Init()
	}
	return nil
}
