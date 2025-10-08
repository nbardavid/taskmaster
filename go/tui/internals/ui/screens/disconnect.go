package screens

import (
	tea "github.com/charmbracelet/bubbletea"
	message "github.com/nbardavid/taskmaster-tui/internals/ui/msg"
)


type DisconnectModel struct {
	// Nbtry int
}

func InitDisconnectModel() DisconnectModel {
	return DisconnectModel{
		// Nbtry: 0,
	}
}

func (m DisconnectModel) Init() tea.Cmd {
    // m.Nbtry = 0
	return nil
}

func (m DisconnectModel) View() string {
	s := "Connecting to the server\n"
	// s += fmt.Sprintf("try %d\n", m.Nbtry)
	return s
}

func (m DisconnectModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
    switch msg := msg.(type) {
	case message.ConnectionFailedMsg:
		// m.Nbtry++;
    	// return m, tea.Tick(2*time.Second, func(time.Time) tea.Msg { return tryConnect()() })
		return m, nil
    case tea.KeyMsg:
        switch msg.String() {
        case "q", "ctrl+c":
            return m, tea.Quit
        }
	}
	return m, nil
}
