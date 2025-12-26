#!/usr/bin/env python3
import argparse
import json
import subprocess
import sys
import os
import time


def run_client(client_path, args):
    cmd = [sys.executable, client_path] + args
    result = subprocess.run(cmd, check=False, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "client failed")
    return json.loads(result.stdout)


def wait_for(predicate, timeout_s, interval_s):
    start = time.time()
    while time.time() - start < timeout_s:
        if predicate():
            return True
        time.sleep(interval_s)
    return False


def banner(title):
    print(f"\n== {title} ==")


def show(label, payload):
    print(f"{label}:")
    print(json.dumps(payload, indent=2))


def assert_true(ok, msg, failures):
    if ok:
        print(f"[OK] {msg}")
    else:
        print(f"[FAIL] {msg}")
        failures.append(msg)


def read_file(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return fh.read()
    except FileNotFoundError:
        return ""


def file_contains(path, needle):
    return needle in read_file(path)


def main():
    parser = argparse.ArgumentParser(description="Taskmaster REST integration test")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--client", default="scripts/tm_client.py")
    parser.add_argument("--timeout", type=float, default=10.0)
    parser.add_argument("--config", default="config.json")
    args = parser.parse_args()

    with open(args.config, "r", encoding="utf-8") as fh:
        config = json.load(fh)

    programs = list(config.get("programs", {}).keys())
    if not programs:
        print("No programs found in config, nothing to test.", file=sys.stderr)
        return 1

    base_args = ["--host", args.host, "--port", str(args.port)]
    failures = []

    def status_all():
        return run_client(args.client, base_args + ["status"])

    def status_program(name):
        response = run_client(args.client, base_args + ["program", name, "status"])
        return response.get("program", response)

    def start_program(name):
        return run_client(args.client, base_args + ["program", name, "start"])

    def stop_program(name):
        return run_client(args.client, base_args + ["program", name, "stop"])

    def restart_program(name):
        return run_client(args.client, base_args + ["program", name, "restart"])

    def reload_config():
        return run_client(args.client, base_args + ["reload"])

    banner("Feature: /status lists programs")
    payload = status_all()
    show("response", payload)
    assert_true("programs" in payload, "/status returns programs", failures)
    if "programs" in payload:
        names = [p.get("name") for p in payload["programs"]]
        for name in programs:
            assert_true(name in names, f"/status contains {name}", failures)

    banner("Feature: program status fields")
    for name in programs:
        payload = status_program(name)
        show(f"{name} status", payload)
        for key in ("name", "running", "alive", "total", "uptime_seconds", "fatal_count"):
            assert_true(key in payload, f"{name} status has {key}", failures)

    banner("Feature: numprocs")
    start_program("feature_numprocs")
    def numprocs_ok():
        p = status_program("feature_numprocs")
        return p.get("running", 0) == 2 and p.get("alive", 0) == 2 and p.get("total", 0) == 2
    assert_true(wait_for(numprocs_ok, args.timeout, 0.2), "feature_numprocs runs 2 processes", failures)
    stop_program("feature_numprocs")

    banner("Feature: stdout redirection")
    start_program("feature_stdout")
    assert_true(wait_for(lambda: file_contains("/tmp/feature_stdout.log", "feature_stdout: ok"), args.timeout, 0.2),
                "feature_stdout produced output", failures)
    stop_program("feature_stdout")
    out = read_file("/tmp/feature_stdout.log")
    show("feature_stdout.log", {"content": out.strip()})
    assert_true("feature_stdout: ok" in out, "stdout redirected to file", failures)

    banner("Feature: stderr redirection")
    start_program("feature_stderr")
    assert_true(wait_for(lambda: file_contains("/tmp/feature_stderr.err", "feature_stderr: ok"), args.timeout, 0.2),
                "feature_stderr produced output", failures)
    stop_program("feature_stderr")
    err = read_file("/tmp/feature_stderr.err")
    show("feature_stderr.err", {"content": err.strip()})
    assert_true("feature_stderr: ok" in err, "stderr redirected to file", failures)

    banner("Feature: env propagation")
    start_program("feature_env")
    assert_true(wait_for(lambda: file_contains("/tmp/feature_env.log", "feature_env: ok"), args.timeout, 0.2),
                "feature_env produced output", failures)
    out = read_file("/tmp/feature_env.log")
    show("feature_env.log", {"content": out.strip()})
    assert_true("feature_env: ok" in out, "env var visible to program", failures)

    banner("Feature: working directory")
    start_program("feature_workdir")
    assert_true(wait_for(lambda: "/tmp" in read_file("/tmp/feature_workdir.log"), args.timeout, 0.2),
                "feature_workdir produced output", failures)
    out = read_file("/tmp/feature_workdir.log")
    show("feature_workdir.log", {"content": out.strip()})
    assert_true("/tmp" in out, "working directory set", failures)

    banner("Feature: umask")
    start_program("feature_umask")
    assert_true(wait_for(lambda: "mode=644" in read_file("/tmp/feature_umask.log"), args.timeout, 0.2),
                "feature_umask produced output", failures)
    out = read_file("/tmp/feature_umask.log")
    show("feature_umask.log", {"content": out.strip()})
    assert_true("mode=644" in out, "umask applied (022 -> 644)", failures)

    banner("Feature: startsecs")
    start_program("feature_startsecs")
    assert_true(wait_for(lambda: "feature_startsecs: done" in read_file("/tmp/feature_startsecs.log"),
                         args.timeout, 0.2), "feature_startsecs produced output", failures)
    stop_program("feature_startsecs")
    out = read_file("/tmp/feature_startsecs.log")
    show("feature_startsecs.log", {"content": out.strip()})
    assert_true("feature_startsecs: done" in out, "program ran past startsecs", failures)

    banner("Feature: exitcodes expected")
    start_program("feature_exitcode")
    time.sleep(0.5)
    p = status_program("feature_exitcode")
    show("feature_exitcode status", p)
    assert_true(p.get("alive", 0) == 0, "feature_exitcode not kept running", failures)

    banner("Feature: autorestart unexpected")
    start_program("feature_autorestart")
    def autorestart_fatal():
        p = status_program("feature_autorestart")
        return p.get("fatal_count", 0) >= 1
    assert_true(wait_for(autorestart_fatal, args.timeout, 0.2),
                "unexpected exit triggers retries/fatal", failures)
    p = status_program("feature_autorestart")
    show("feature_autorestart status", p)

    banner("Feature: stopsignal")
    start_program("feature_stopsignal")
    time.sleep(0.2)
    stop_program("feature_stopsignal")
    ok = wait_for(lambda: os.path.exists("/tmp/feature_stopsignal.ok"), args.timeout, 0.2)
    assert_true(ok, "program handled stop signal", failures)

    banner("Feature: stoptime")
    start_program("feature_stoptime")
    time.sleep(0.2)
    stop_program("feature_stoptime")
    def stoptime_ok():
        p = status_program("feature_stoptime")
        return p.get("alive", 0) == 0 and p.get("running", 0) == 0
    assert_true(wait_for(stoptime_ok, args.timeout, 0.2), "program stopped after stoptime", failures)

    banner("Feature: restart endpoint")
    start_program("feature_stdout")
    payload = restart_program("feature_stdout")
    show("restart response", payload)
    assert_true(payload.get("success", False), "/programs/:name/restart works", failures)
    stop_program("feature_stdout")

    banner("Feature: reload endpoint")
    payload = reload_config()
    show("reload", payload)
    assert_true(payload.get("success", False), "/reload returns success", failures)

    if failures:
        print("\nRESULT: FAIL")
        print("Failures:")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("\nRESULT: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
