#!/usr/bin/env python3
import json
import random
import signal
import time
import os
import argparse

AUTORESTART_CHOICES = ["always", "never", "unexpected"]
STOP_SIGNALS = ["TERM", "KILL", "USR1", "USR2", "INT", "HUP"]

def randomize_program(prog: dict) -> dict:
    prog["numprocs"] = random.randint(1, 5)
    prog["autostart"] = random.choice([True, False])
    prog["autorestart"] = random.choice(AUTORESTART_CHOICES)
    prog["exitcodes"] = random.sample(range(0, 5), random.randint(1, 3))
    prog["starttime"] = random.randint(1, 5)
    prog["startretries"] = random.randint(1, 5)
    prog["stopsignal"] = random.choice(STOP_SIGNALS)
    prog["stoptime"] = random.randint(1, 10)
    return prog

def stress_config(path: str, pid: int, interval: float = 2.0):
    while True:
        # Load
        with open(path, "r") as f:
            config = json.load(f)

        # Randomize each program
        for name, prog in config.get("programs", {}).items():
            config["programs"][name] = randomize_program(prog)

        # Save back
        with open(path, "w") as f:
            json.dump(config, f, indent=2)

        print(f"[+] Updated config {path}, sending SIGHUP to {pid}")
        os.kill(pid, signal.SIGHUP)

        time.sleep(interval)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Stress test Taskmaster config reloads")
    parser.add_argument("config", help="Path to Taskmaster JSON config")
    parser.add_argument("pid", type=int, help="PID of running Taskmaster server")
    parser.add_argument("--interval", type=float, default=2.0, help="Seconds between updates")
    args = parser.parse_args()

    stress_config(args.config, args.pid, args.interval)

