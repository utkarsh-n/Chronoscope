#!/usr/bin/env python3
"""Build an exact source mirror outside iCloud's file-coordination path."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--simulator', default='9AC0979F-7162-42A7-A2BD-FB3CC1D6439D')
parser.add_argument('--prepare-only', action='store_true', help='Prepare the verified mirror for XcodeBuildMCP or Xcode without building.')
args = parser.parse_args()
source = Path(__file__).resolve().parents[1]
mirror = Path('/private/tmp/chronoscope-native-source')
mirror.mkdir(parents=True, exist_ok=True)
for name in ('App', 'Core'):
    target = mirror / name
    if target.exists(): shutil.rmtree(target)
    shutil.copytree(source / name, target, ignore=shutil.ignore_patterns('.build', '.swiftpm', '__pycache__', '.DS_Store'))
shutil.copy2(source / 'project.yml', mirror / 'project.yml')
hashes = {}
for path in mirror.rglob('*'):
    if path.is_file() and path.parts[len(mirror.parts)] in ('App', 'Core', 'project.yml'):
        relative = path.relative_to(mirror)
        original = source / relative
        if not original.is_file(): continue
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != hashlib.sha256(original.read_bytes()).hexdigest(): raise RuntimeError(f'Source mismatch: {relative}')
        hashes[str(relative)] = digest
(mirror / 'source-hashes.json').write_text(json.dumps(hashes, indent=2))
subprocess.run(['xcodegen', 'generate'], cwd=mirror, check=True)
if args.prepare_only:
    print(f'Verified {len(hashes)} files in {mirror}')
    raise SystemExit(0)
command = ['xcodebuild', '-project', 'Chronoscope.xcodeproj', '-scheme', 'Chronoscope', '-destination', f'platform=iOS Simulator,id={args.simulator}', '-derivedDataPath', '/private/tmp/chronoscope-native-build', 'CODE_SIGNING_ALLOWED=NO', 'build']
raise SystemExit(subprocess.run(command, cwd=mirror).returncode)
