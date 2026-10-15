#!/usr/bin/env python3
"""Run the authorized full prose pipeline once and capture its observed exit."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import sys
import time
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / 'Data/narrative'
PARSER_SHA = '794f151703c3b8981cf67223a888bd30d4b46c98c1fc2883ff8c1ed74f3bbe26'
PIPELINE_SHA = '762531bda814e55b5789c13dcef7582c41e1f5d4a4547865e7a496e269037b7a'


def now():
    return datetime.now(timezone.utc).isoformat()


def read(path):
    return json.loads(path.read_text())


def save(path, value):
    temporary = path.with_name(path.name + '.monitor-tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def exit_details(return_code):
    return {'returnCode': return_code,
            'terminationSignal': signal.Signals(-return_code).name if return_code < 0 else None}


def verify_inputs():
    download = read(ROOT / 'Data/download-status.json')
    archive = Path(download['path']).resolve()
    info = archive.stat()
    assert archive == ROOT / 'Data/downloads/enwiki-20261001-pages-articles-multistream.xml.bz2'
    assert download['status'] == 'verified' and info.st_size == download['expectedBytes'] == 26917225724
    assert download['expectedSHA1'] == '992b5ca87b3404894f013e59a43efbb8b1bc012b'
    parser_sha = hashlib.sha256((ROOT / 'Tools/narrative.py').read_bytes()).hexdigest()
    pipeline_sha = hashlib.sha256((ROOT / 'Tools/narrative_pipeline.py').read_bytes()).hexdigest()
    assert parser_sha == PARSER_SHA and pipeline_sha == PIPELINE_SHA
    connection = sqlite3.connect(f'file:{DATA / "prose-stage.sqlite"}?mode=ro', uri=True, timeout=3)
    try:
        checkpoint = json.loads(connection.execute(
            "SELECT value FROM extraction_checkpoint WHERE key='progress'").fetchone()[0])
    finally:
        connection.close()
    assert checkpoint == read(DATA / 'extraction.json')
    assert checkpoint['complete'] is True and checkpoint['limited'] is False
    assert checkpoint['extractedMentions'] == 8173429
    assert json.loads(checkpoint['fingerprint']) == [str(archive), info.st_size, info.st_mtime_ns,
                                                   parser_sha, pipeline_sha, None]
    base = read(ROOT / 'Data/ingest-status.json')
    assert base['status'] == 'complete' and base['validation'] == 'passed'
    assert read(ROOT / 'Data/validation-status.json')['status'] == 'passed'
    for pattern in ('[n]arrative_pipeline.py', '[n]arrative_resume_pipeline.py',
                    '[s]wift.*Chronoscope/Tools/embed.swift',
                    '[f]ull-embedding-input.jsonl'):
        result = subprocess.run(['/usr/bin/pgrep', '-fl', pattern], capture_output=True,
                                text=True, timeout=10)
        assert result.returncode == 1, (pattern, result.stdout, result.stderr)
    with (DATA / 'pipeline.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(lock, fcntl.LOCK_UN)


def main():
    with (DATA / 'worker-monitor.lock').open('a') as monitor_lock:
        fcntl.flock(monitor_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        verify_inputs()
        command = ['/usr/sbin/taskpolicy', '-d', 'throttle',
                   '/usr/bin/nice', '-n', '19', sys.executable, '-u',
                   str(ROOT / 'Tools/narrative_resume_pipeline.py'), 'build']
        environment = os.environ.copy()
        environment['PATH'] = '/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin'
        environment['DEVELOPER_DIR'] = '/Applications/Xcode-beta.app/Contents/Developer'
        with (DATA / 'pipeline.log').open('ab', buffering=0) as log:
            log.write(('\nWorker monitor ' + now() + ': starting resumable derived preparation runtime at '
                       'nice19 CPU priority and throttled disk I/O; saved data preserved; '
                       'no automatic retries.\n').encode())
            launch_requested_at = now()
            worker = subprocess.Popen(command, cwd=ROOT, env=environment, stdin=subprocess.DEVNULL,
                                      stdout=log, stderr=log, start_new_session=True, close_fds=True)
            state = {'status': 'launching', 'startedAt': launch_requested_at, 'monitorPID': os.getpid(),
                     'workerPID': worker.pid, 'command': command, 'automaticRetries': False,
                     'schedulingPolicy': 'throttled disk I/O; nice19 CPU scheduling priority'}
            save(DATA / 'worker-monitor-status.json', state)
            while worker.poll() is None:
                try:
                    snapshot = read(ROOT / 'Data/narrative-status.json')
                    snapshot_started_at = snapshot.get('startedAt')
                    if (snapshot.get('pid') == worker.pid and snapshot.get('status') == 'running'
                            and isinstance(snapshot_started_at, str)
                            and datetime.fromisoformat(snapshot_started_at)
                            >= datetime.fromisoformat(launch_requested_at)):
                        state.update(status='running', launchVerifiedAt=now())
                        save(DATA / 'worker-monitor-status.json', state)
                        break
                except (OSError, ValueError):
                    pass
                time.sleep(1)
            return_code = worker.wait()
            result = {**state, 'status': 'exited', 'exitedAt': now(), **exit_details(return_code)}
            try:
                snapshot = read(ROOT / 'Data/narrative-status.json')
                result['pipelineSnapshot'] = snapshot
                result['pipelineSnapshotMatchesWorker'] = snapshot.get('pid') == worker.pid
            except (OSError, ValueError) as error:
                result['snapshotReadError'] = str(error)
            save(DATA / 'worker-last-exit.json', result)
            save(DATA / 'worker-monitor-status.json', result)
            log.write(('\nWorker monitor exit: ' + json.dumps({key: result[key] for key in
                       ('workerPID', 'exitedAt', 'returnCode', 'terminationSignal')}) + '\n').encode())


if __name__ == '__main__':
    main()
