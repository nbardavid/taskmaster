package client

import (
	"encoding/binary"
	"io"
)

type ResponseStatus uint8

const (
	success = iota
	err
	not_found
)

type Response struct {
	status ResponseStatus
	reserved uint8
	payload_len uint16
}

func ListenToServer (ctx *Context) {
	buf := make([]byte, 4)

	for {
		if _, err := io.ReadFull(ctx.conn, buf); err != nil {
			ctx.listenerErr = err
			return
		}
		var res = Response{
			status: ResponseStatus(buf[0]), 
			reserved: buf[1],
			payload_len: binary.LittleEndian.Uint16(buf[2:4]),
		}

		payloadBuf := make([]byte, res.payload_len)
		if _, err := io.ReadFull(ctx.conn, payloadBuf); err != nil {
			ctx.listenerErr = err
			return
		}

		switch res.status {
		case success:
			ctx.prompt = "\033[32m> \033[0m"
		case err:
			ctx.prompt = "\033[31m> \033[0m"
		case not_found:
			ctx.prompt = "\033[33m> \033[0m"
		}
		ctx.pending.value = append(ctx.pending.value, string(payloadBuf))
	}
}
