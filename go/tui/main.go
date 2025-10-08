package main

import (
	"context"
	"fmt"
	"os"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/nbardavid/taskmaster-tui/internals/ui"
	"github.com/nbardavid/taskmaster-tui/internals/worker"
)


func main() {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	rootModel := ui.InitRootscreens(cancel)
	p := tea.NewProgram(&rootModel, tea.WithAltScreen())
	go worker.WorkerStart(ctx, p);
	// for {
	//
	// }
    if _, err := p.Run(); err != nil {
        fmt.Printf("Alas, there's been an error: %v", err)
        os.Exit(1)
    }
}

