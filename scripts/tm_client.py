#!/usr/bin/env python3
import argparse
import json
import sys
import urllib.error
import urllib.request


def build_url(host: str, port: int, path: str) -> str:
    return f"http://{host}:{port}{path}"


def request_json(url: str, method: str, timeout: float) -> dict:
    req = urllib.request.Request(url, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = resp.read().decode("utf-8")
            if not data:
                return {}
            return json.loads(data)
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8") if exc.fp else ""
        raise RuntimeError(f"{exc.code} {exc.reason} {body}".strip()) from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(str(exc.reason)) from exc


def main() -> int:
    parser = argparse.ArgumentParser(description="Tiny Taskmaster REST client")
    parser.add_argument("--host", default="127.0.0.1", help="Server host")
    parser.add_argument("--port", type=int, default=8080, help="Server port")
    parser.add_argument("--timeout", type=float, default=2.0, help="Request timeout (s)")

    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("status", help="Get all program statuses")

    prog = sub.add_parser("program", help="Program operations")
    prog.add_argument("name", help="Program name")
    prog.add_argument("action", choices=["status", "start", "stop", "restart"])

    sub.add_parser("reload", help="Reload configuration")

    args = parser.parse_args()
    base = f"{args.host}:{args.port}"

    try:
        if args.cmd == "status":
            payload = request_json(build_url(args.host, args.port, "/status"), "GET", args.timeout)
        elif args.cmd == "program":
            if args.action == "status":
                path = f"/programs/{args.name}"
                payload = request_json(build_url(args.host, args.port, path), "GET", args.timeout)
            else:
                path = f"/programs/{args.name}/{args.action}"
                payload = request_json(build_url(args.host, args.port, path), "POST", args.timeout)
        elif args.cmd == "reload":
            payload = request_json(build_url(args.host, args.port, "/reload"), "POST", args.timeout)
        else:
            raise RuntimeError(f"unknown command {args.cmd}")
    except RuntimeError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    print(json.dumps(payload, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
