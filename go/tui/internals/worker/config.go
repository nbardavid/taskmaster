package worker

import (
	"encoding/json"
	// message "github.com/nbardavid/taskmaster-tui/internals/ui/msg"
)

type MsgConfigUpdated struct{ Config Config }

type Program struct {
	Cmd          string            `json:"cmd"`
	NumProcs     int               `json:"numprocs"`
	AutoStart    bool              `json:"autostart"`
	AutoRestart  string            `json:"autorestart"`
	ExitCodes    []int             `json:"exitcodes"`
	StartTime    int               `json:"starttime"`
	StartRetries int               `json:"startretries"`
	StopSignal   string            `json:"stopsignal"`
	StopTime     int               `json:"stoptime"`
	Stdout       string            `json:"stdout"`
	Stderr       string            `json:"stderr"`
	Env          map[string]string `json:"env,omitempty"`
	WorkingDir   string            `json:"workingdir,omitempty"`
	Umask        string            `json:"umask,omitempty"`
}

type Config struct {
	Programs map[string]Program    `json:"programs"`
}

func (w *Worker) UpdateConfig(payload string) {
    var c Config
    if err := json.Unmarshal([]byte(payload), &c); err != nil {
		//TODO:
        return
    }
	
	w.wctx.config = c
	w.p.Send(MsgConfigUpdated{c})
}
