package styles

import (
	"github.com/charmbracelet/lipgloss"
)

var (
	Cursor = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("141"))
	Title = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("255"))
	Normal = lipgloss.NewStyle().Bold(false).Foreground(lipgloss.Color("255"))
	GrayText = lipgloss.NewStyle().Bold(false).Foreground(lipgloss.Color("244"))
)
