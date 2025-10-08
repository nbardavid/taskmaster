package main

import (
	"github.com/nbardavid/taskmaster/internals/client"
)

func main () {
	var state = client.DisconnectedFromServer
	ctx := client.Context{}

	for state != nil {
		state = state(&ctx)
	}
}
