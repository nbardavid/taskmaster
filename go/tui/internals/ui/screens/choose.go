package screens

import (
	"fmt"

	tea "github.com/charmbracelet/bubbletea"
	// message "github.com/nbardavid/taskmaster-tui/internals/ui/msg"
	"github.com/nbardavid/taskmaster-tui/internals/worker"
)

type ChooseModel struct {
	names		[]string
	cursor 		int
	config		*worker.Config
}

func InitChooseModel() ChooseModel {
	return ChooseModel{
		config: nil,
		names: nil,
		cursor: 0,
	}
}

func (m ChooseModel) Init() tea.Cmd {
	return nil;
}

// Choose a program:
//
// > webserver
//   worker
//   scheduler
//   database
//
// [q] quit  [enter] select

func (m ChooseModel) View() string {
	s := "Choose a program\n\n"

	if m.config == nil {
		s += "Config is loading\n"
		return s
	}

	for i, name := range m.names {
		if m.cursor == i {
			s += ">"
		} else {
			s += " "
		}
		s += fmt.Sprintf(" %s\n", name)
	}
	s += "\n[q] quit  [enter] select\n"
	return s
}

func (m *ChooseModel) fillNames() {
	m.names = make([]string, 0, len(m.config.Programs))
	for name := range m.config.Programs {
		m.names = append(m.names, name)
	}
}

func (m ChooseModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
    switch msg := msg.(type) {
    case tea.KeyMsg:
        switch msg.String() {
        case "q", "ctrl+c":
            return m, tea.Quit
		case "up":
			if m.cursor > 0 { m.cursor--; }
		case "down":
			if m.cursor < len(m.config.Programs) - 1 { m.cursor++; }
        }
	case worker.MsgConfigUpdated:
		m.config = &msg.Config
		m.fillNames()
	}
	return m, nil
}
