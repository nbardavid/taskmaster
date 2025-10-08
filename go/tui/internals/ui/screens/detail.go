package screens

import (
	tea "github.com/charmbracelet/bubbletea"
)

type DetailModel struct {}

func InitDetailModel() DetailModel {
	return DetailModel{};
}

func (m DetailModel) Init() tea.Cmd {
	return nil;
}

func (m DetailModel) View() string {
	return "Details"
}

func (m DetailModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
    switch msg := msg.(type) {
    case tea.KeyMsg:
        switch msg.String() {
        case "q", "ctrl+c":
            return m, tea.Quit
        }
	}
	return m, nil
}
