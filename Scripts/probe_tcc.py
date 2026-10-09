#!/usr/bin/env python3
"""Give the disposable CI Flux app AX access, then restore its prior grant."""

import argparse
from contextlib import closing, contextmanager
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import sys
import time


DATABASE = "/Library/Application Support/com.apple.TCC/TCC.db"
SERVICE = "kTCCServiceAccessibility"
CLIENT = "com.flux.menubar"
DONOR = "com.apple.dt.Xcode-Helper"
ROW_FILTER = "service=? AND client=? AND client_type=0 AND indirect_object_identifier='UNUSED'"


def _require_ci():
    if sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true":
        raise RuntimeError("AX grants are allowed only on a disposable GitHub macOS runner")


def _pack(value):
    return {"bytes": value.hex()} if isinstance(value, bytes) else value


def _unpack(value):
    return bytes.fromhex(value["bytes"]) if isinstance(value, dict) else value


def _apply(action, request):
    _require_ci()
    client = request.get("client", "")
    if not isinstance(client, str) or not client.startswith("com.flux."):
        raise RuntimeError("The AX test grant must use a com.flux. bundle identifier")
    # Open an existing database. Never create one if the CI image changes its path.
    with closing(sqlite3.connect(f"file:{DATABASE}?mode=rw", uri=True, timeout=5)) as database, database:
        database.execute("BEGIN IMMEDIATE")
        columns = [row[1] for row in database.execute("PRAGMA table_info(access)")]
        required = {"service", "client", "client_type", "auth_value", "csreq",
                    "indirect_object_identifier"}
        if not required.issubset(columns):
            raise RuntimeError("The runner's TCC schema lacks the required AX columns")
        quoted = ",".join('"' + name.replace('"', '""') + '"' for name in columns)
        insert = f"INSERT INTO access ({quoted}) VALUES ({','.join('?' for _ in columns)})"
        own_rows = database.execute(
            f"SELECT {quoted} FROM access WHERE {ROW_FILTER}", (SERVICE, client)
        ).fetchall()
        if len(own_rows) > 1:
            raise RuntimeError("The runner has more than one matching Flux AX row")

        snapshot = {"client": client, "columns": columns,
                    "rows": [[_pack(value) for value in row] for row in own_rows]}
        if action == "snapshot":
            return snapshot
        if action == "grant":
            if request.get("snapshot") != snapshot:
                raise RuntimeError("The app's AX row changed before the test grant")
            donor = database.execute(
                f"SELECT {quoted} FROM access WHERE {ROW_FILTER} AND auth_value=2",
                (SERVICE, DONOR),
            ).fetchone()
            if donor is None:
                raise RuntimeError("The runner has no allowed Xcode Helper AX row to copy")
            grant = dict(zip(columns, donor))
            grant["client"] = client
            # A null requirement tests clicks. An explicit blob tests signed updates.
            grant["csreq"] = _unpack(request.get("csreq"))
            for name in ("last_modified", "last_reminded"):
                if name in grant:
                    grant[name] = int(time.time())
            rows = [tuple(grant[name] for name in columns)]
        else:
            snapshot = request
            if action != "restore":
                raise RuntimeError("A restore needs the original Flux AX snapshot")
            if snapshot.get("columns") != columns or len(snapshot.get("rows", [])) > 1:
                raise RuntimeError("The Flux AX snapshot does not match the runner's TCC schema")
            rows = [tuple(_unpack(value) for value in row) for row in snapshot["rows"]]
            for row in rows:
                values = dict(zip(columns, row))
                if len(row) != len(columns) or any(values.get(name) != expected for name, expected in
                        (("service", SERVICE), ("client", client), ("client_type", 0),
                         ("indirect_object_identifier", "UNUSED"))):
                    raise RuntimeError("The snapshot contains a row outside Flux's AX grant")

        database.execute(f"DELETE FROM access WHERE {ROW_FILTER}", (SERVICE, client))
        database.executemany(insert, rows)
        return snapshot


def _stop(process):
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        process.wait(timeout=5)
        return
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=5)


def _worker(action, request):
    command = ["sudo", "-n", "/usr/bin/env", "GITHUB_ACTIONS=true", sys.executable,
               str(Path(__file__).resolve()), "--worker", action]
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True, start_new_session=True)
    try:
        output, error = process.communicate(json.dumps(request), timeout=15)
    except subprocess.TimeoutExpired as error:
        _stop(process)
        detail = error.stderr or ""
        if isinstance(detail, bytes):
            detail = detail.decode(errors="replace")
        raise RuntimeError(f"TCC {action} reached its 15-second deadline: {detail.strip()}") from error
    except BaseException:
        _stop(process)
        raise
    if process.returncode:
        raise RuntimeError(f"TCC {action} failed: {error.strip() or output.strip()}")
    return json.loads(output)


@contextmanager
def accessibility_grant(bundle_id, csreq=None):
    """Stop the test app before leaving this context. Never use it on a user Mac."""
    _require_ci()
    if csreq is not None and not isinstance(csreq, bytes):
        raise TypeError("Pass the compiled signing requirement as bytes or None")
    previous_term = signal.getsignal(signal.SIGTERM)

    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, interrupted)
    snapshot = None
    try:
        snapshot = _worker("snapshot", {"client": bundle_id})
        _worker("grant", {"client": bundle_id, "snapshot": snapshot, "csreq": _pack(csreq)})
        print(f"CI: temporary AX grant installed for {bundle_id}", flush=True)
        yield snapshot
    finally:
        try:
            if snapshot is not None:
                _worker("restore", snapshot)
                print(f"CI: prior AX grant restored for {bundle_id}", flush=True)
        finally:
            signal.signal(signal.SIGTERM, previous_term)


def flux_accessibility_grant():
    return accessibility_grant(CLIENT)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--worker", choices=("snapshot", "grant", "restore"), help=argparse.SUPPRESS)
    parser.add_argument("--seconds", type=float, default=60)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    arguments = parser.parse_args()
    if arguments.worker:
        print(json.dumps(_apply(arguments.worker, json.load(sys.stdin))))
        return 0
    command = arguments.command
    if command and command[0] == "--":
        command = command[1:]
    if not command or not 0 < arguments.seconds <= 300:
        parser.error("Provide a command and a deadline from 1 to 300 seconds")
    with flux_accessibility_grant():
        process = subprocess.Popen(command, start_new_session=True)
        try:
            return process.wait(timeout=arguments.seconds)
        except subprocess.TimeoutExpired as error:
            raise RuntimeError("The CI AX test reached its deadline") from error
        finally:
            _stop(process)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, sqlite3.Error) as error:
        sys.exit(f"FAIL: {error}")
