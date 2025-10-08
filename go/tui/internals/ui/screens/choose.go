package screens

import (
	"fmt"

	tea "github.com/charmbracelet/bubbletea"
	// message "github.com/nbardavid/taskmaster-tui/internals/ui/msg"
	"github.com/nbardavid/taskmaster-tui/internals/ui/styles"
	"github.com/nbardavid/taskmaster-tui/internals/worker"
)

type ProgramChosenMsg struct {
	Program worker.Program
	Name 	string
}

type ChooseModel struct {
	loaded		bool
	names		[]string
	cursor 		int
	config		*worker.Config
}

func InitChooseModel() ChooseModel {
	return ChooseModel{
		loaded: false,
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
	s := styles.Title.Render("Choose a program") + "\n\n"

	if m.config == nil {
		s += styles.Normal.Render("Config is loading") + "\n"
		return s
	}

	for i, name := range m.names {
		if m.cursor == i {
			s += styles.Cursor.Render(">")
		} else {
			s += " "
		}
		s += fmt.Sprintf(" %s\n", name)
	}
	s += styles.GrayText.Render("\n  [q] quit  [enter] select\n")
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
		if m.loaded == false {
			return m, nil
		}
        switch msg.String() {
        case "q", "ctrl+c":
            return m, tea.Quit
		case "up", "k":
			if m.cursor > 0 { m.cursor--; }
		case "down", "j":
			if m.cursor < len(m.config.Programs) - 1 { m.cursor++; }
		case "enter", "l":
			return m, func () tea.Msg {
				return ProgramChosenMsg{Name: m.names[m.cursor], Program: m.config.Programs[m.names[m.cursor]]}
			}
        }
	case worker.MsgConfigUpdated:
		m.config = &msg.Config
		m.loaded = true
		m.fillNames()
	}
	return m, nil
}
