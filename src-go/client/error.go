package client

import "log"

func ReceivedInvalidCommand (ctx *Context) StateFunc {
	log.Printf("Invalid Command: %s\n", ctx.err.Error())
	return FetchInputs
}

func NeedsToDisconnect (ctx *Context) StateFunc {
	ctx.conn.Close()
	ctx.conn = nil
	return DisconnectedFromServer
}

func EncounteredFatalError (ctx *Context) StateFunc {
	log.Fatal("[FATAL] %s\n", ctx.err.Error())
	return nil
}

func SendToLongPayload (ctx *Context) StateFunc {
	log.Printf("Invalid Command: Too long argument (max 255)\n", ctx.err.Error())
	return FetchInputs
}
