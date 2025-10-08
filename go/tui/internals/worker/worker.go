package worker

import (
	"context"
	"encoding/binary"
	"io"
	"net"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	message "github.com/nbardavid/taskmaster-tui/internals/ui/msg"
)

const socketPath = "/tmp/taskmaster.server.sock"

type WorkerContext struct {
	conn net.Conn
	config Config
}

type Worker struct {
	wctx     WorkerContext
	p 		*tea.Program
}

func WorkerStart(ctx context.Context, p *tea.Program){
	worker := Worker{
		p: p,
		wctx: WorkerContext{},
	}

	for ok := false; !ok; {
		ok = worker.connect()
		time.Sleep(time.Second * 2)
	}
	worker.run(ctx)
}

func (w *Worker) connect () bool {
	conn, err := net.DialTimeout("unix", socketPath, 2*time.Second)
	if err != nil {
		w.p.Send(message.ConnectionFailedMsg{Err: err})
		return false
	}
	w.wctx.conn = conn
	w.p.Send(message.ConnectionSuccessMsg{Conn: conn})
	return true
}

type CommandId uint8

const (
	config CommandId = iota
	start
	stop
)

type Response struct {
	commandId CommandId
	reserved uint8
	payload_len uint16
	payload 	string
}

func (w *Worker) run (ctx context.Context) {
	buf := make([]byte, 4)


	for {
		w.wctx.conn.SetReadDeadline(time.Now().Add(time.Millisecond * 500))

		if _, err := io.ReadFull(w.wctx.conn, buf); err != nil {
			if ne, ok := err.(net.Error); ok && ne.Timeout() {
				select {
				case <-ctx.Done():
					// fmt.Println("Worker stop demandé")
					return
				default:
					continue
				}
			}
			return
		}

		var res = Response{
			commandId: CommandId(buf[0]), 
			reserved: buf[1],
			payload_len: binary.LittleEndian.Uint16(buf[2:4]),
		}

		payloadBuf := make([]byte, res.payload_len)
		if _, err := io.ReadFull(w.wctx.conn, payloadBuf); err != nil {
			// ctx.listenerErr = err
			return
		}

		res.payload = string(payloadBuf)
		go w.computeResponse(res)
	}
}

func (w *Worker) computeResponse (r Response) {
	switch r.commandId {
	case config:
		w.UpdateConfig(r.payload)
	case start:
		//
	case stop:
		//
	}
}

