package main

import (
	"github.com/nbardavid/taskmaster/client"
)

func main () {
	var state = client.DisconnectedFromServer
	ctx := client.Context{}

	for {
		state = state(&ctx)
	}
}
