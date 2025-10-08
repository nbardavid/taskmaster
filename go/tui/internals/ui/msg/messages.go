package msg

import (
	"net"
	tea "github.com/charmbracelet/bubbletea"
)

func ToCmd(msg tea.Msg) (func () tea.Msg ) {
	return func () tea.Msg {
		return msg
	}
}

type ConnectionSuccessMsg struct{ Conn net.Conn }
type ConnectionFailedMsg struct{ Err error }
type GoBackToSelection struct {}
