package screens

import (
	"fmt"

	tea "github.com/charmbracelet/bubbletea"
	message "github.com/nbardavid/taskmaster-tui/internals/ui/msg"
	"github.com/nbardavid/taskmaster-tui/internals/ui/styles"
	"github.com/nbardavid/taskmaster-tui/internals/worker"
)

type ProgramDetails struct {
	Program worker.Program
	Name 	string
}

type DetailModel struct {
	program *worker.Program
	name 	string
}

func InitDetailModel() DetailModel {
	return DetailModel{
		program: nil,
		name: "",
	};
}

func (m DetailModel) Init() tea.Cmd {
	return nil;
}

// Details for: webserver
// ────────────────────────────
// cmd:        ./bin/server
// numprocs:   2
// autostart:  true
// stdout:     /tmp/webserver.out
// stderr:     /tmp/webserver.err
// umask:      022

func fallback(str string, fallback string) string {
	if str == ""{
		return fallback
	}
	return str
}

func (m DetailModel) View() string {
	if m.program == nil {
		return styles.Title.Render("LOADING DETAILS\n")
	}

	s := styles.Title.Render(fmt.Sprintf("Details for: %s", m.name)) + "\n"
	s += styles.GrayText.Render("────────────────────────────") + "\n\n"
    s += fmt.Sprintf("cmd:        %s\n", m.program.Cmd)
    s += fmt.Sprintf("numprocs:   %d\n", m.program.NumProcs)
    s += fmt.Sprintf("autostart:  %t\n", m.program.AutoStart)
    s += fmt.Sprintf("stdout:     %s\n", m.program.Stdout)
    s += fmt.Sprintf("stderr:     %s\n", m.program.Stderr)
	s += fmt.Sprintf("umask:      %s\n", fallback(m.program.Umask, "undefined"))

	s += styles.GrayText.Render("\n  [q] quit  [<-] return")
	return s
}


func (m DetailModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
    switch msg := msg.(type) {
    case tea.KeyMsg:
        switch msg.String() {
        case "q", "ctrl+c":
            return m, tea.Quit
		case "left", "h":
			return m, message.ToCmd(message.GoBackToSelection{})
        }
	case ProgramDetails:
		m.program = &msg.Program
		m.name = msg.Name
		return m, nil
	}
	return m, nil
}
