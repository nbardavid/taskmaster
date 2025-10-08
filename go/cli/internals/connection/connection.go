package connection

import "net"

type State struct {
	Conn net.Conn
	Err error
}
