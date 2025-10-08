package msg

import (
	"net"
)

type ConnectionSuccessMsg struct{ Conn net.Conn }
type ConnectionFailedMsg struct{ Err error }
