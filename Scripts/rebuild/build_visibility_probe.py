"""Package the diagnostic CLI and its tested finite restore supervisor."""
import hashlib
import json
from pathlib import Path
import subprocess
import zipfile


def run(command, seconds=120):
    return subprocess.run(command, check=True, capture_output=True, text=True, timeout=seconds).stdout.strip()


run(['python3', '-m', 'unittest', 'discover', '-s', 'Scripts/rebuild', '-p', 'test_visibility_guard.py'], 45)
run(['swift', 'build', '-c', 'release', '--product', 'FluxVisibilityProbe'], 180)
binary = Path(run(['swift', 'build', '-c', 'release', '--show-bin-path'], 20)) / 'FluxVisibilityProbe'
destination = Path('build/native-visibility-probe')
destination.mkdir(parents=True, exist_ok=True)
archive = destination / 'FluxVisibilityProbe.zip'
with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as output:
    output.write(binary, 'FluxVisibilityProbe')
    for name in ('visibility_guard.py', 'test_visibility_guard.py'):
        output.write(Path('Scripts/rebuild') / name, name)
    output.write('docs/rebuild/NATIVE-VISIBILITY-PROBE.md', 'README.md')
metadata = {'sourceRevision': run(['git', 'rev-parse', 'HEAD'], 10),
            'sha256': hashlib.sha256(archive.read_bytes()).hexdigest(),
            'bytes': archive.stat().st_size, 'diagnosticOnly': True}
(destination / 'artifact.json').write_text(json.dumps(metadata, indent=2) + '\n')
print(json.dumps(metadata))
