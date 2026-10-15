#!/usr/bin/env python3
"""Finish the current one-off corpus build without changing a running Simulator."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import time


def now():
    return datetime.now(timezone.utc).isoformat()


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--simulator", default="9AC0979F-7162-42A7-A2BD-FB3CC1D6439D")
    parser.add_argument("--wait-hours", type=float, default=24)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    data = root / "Data"
    data.mkdir(exist_ok=True)
    status_path = data / "native-refresh-status.json"
    state = {"status": "waitingForFullIngest", "startedAt": now(), "pid": os.getpid()}

    def update(**fields):
        state.update(fields, updatedAt=now())
        temporary = status_path.with_suffix(".json.tmp")
        temporary.write_text(json.dumps(state, indent=2))
        temporary.replace(status_path)

    update()
    print("Waiting for the verified full Wikipedia index; progress is in Data/native-refresh-status.json.", flush=True)
    deadline = time.monotonic() + args.wait_hours * 3600
    while time.monotonic() < deadline:
        download = read_json(data / "download-status.json")
        ingest = read_json(data / "ingest-status.json")
        expected = Path(download.get("path", ""))
        actual = Path(ingest.get("path", ""))
        if not actual.is_absolute():
            actual = root / actual
        same_archive = bool(download.get("path") and ingest.get("path")) and expected.resolve() == actual.resolve()
        if download.get("status") in {"failed", "error", "checksum-failed"} or (same_archive and ingest.get("status") in {"failed", "error"}):
            update(status="corpusFailed", detail="The corpus job reported an error. Resume it before rebuilding.")
            return 1
        if download.get("status") == "verified" and ingest.get("status") == "complete" and ingest.get("validation") == "passed":
            if expected.is_file() and same_archive:
                break
        update(downloadedBytes=download.get("downloadedBytes"), downloadStatus=download.get("status"),
               corpusStatus=ingest.get("status") if same_archive else "notStarted",
               corpusPhase=ingest.get("phase") if same_archive else None,
               scannedPages=ingest.get("scannedPages") if same_archive else None)
        time.sleep(30)
    else:
        update(status="waitExpired", detail="No completed full ingestion observed within the time limit.")
        return 1

    catalog = read_json(data / "catalog-status.json")
    update(status="validatingBundle", fullEvents=catalog.get("events"), bundledEvents=catalog.get("bundledEvents"))
    with (data / "native-refresh.log").open("w") as log:
        commands = [
            ["python3", "Tools/validate_catalog.py", "App/Resources/catalog.json"],
            ["swift", "test", "--package-path", "Core"],
            ["python3", "scripts/build-native.py", "--simulator", args.simulator],
        ]
        for command in commands:
            stage = "buildingNative" if command[1:2] == ["scripts/build-native.py"] else "validatingBundle"
            update(status=stage, command=command)
            result = subprocess.run(command, cwd=root, stdout=log, stderr=subprocess.STDOUT)
            log.flush()
            if result.returncode:
                update(status="failed", exitCode=result.returncode, detail="See Data/native-refresh.log.")
                return result.returncode
    update(status="complete", command=None,
           appPath="/private/tmp/chronoscope-native-build/Build/Products/Debug-iphonesimulator/Chronoscope.app",
           detail="Native build completed with the newly extracted bounded bundle. Running apps were left in place; import Data/atlas.sqlite for the full extracted index.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
