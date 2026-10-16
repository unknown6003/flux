#!/usr/bin/env python3
"""Reuse measured evidence only when product and benchmark inputs match."""

import json
import os
from pathlib import Path
import re
from probe_update import run as bounded_run


def run(*args, seconds=25):
    return bounded_run(list(args), seconds=seconds).stdout


def main():
    run_id = os.environ['FLUX_PERFORMANCE_RUN']
    if not re.fullmatch(r'[0-9]+', run_id):
        raise ValueError('Performance run must be a numeric GitHub run ID')
    repository = os.environ['GITHUB_REPOSITORY']
    # This reviewed workflow bridge preserves the measured environment and guards.
    # Any later workflow edit needs fresh measurements.
    if run('git', 'hash-object', '.github/workflows/ci.yml').strip() != '36e731cd7c9a2cde2d684a82feec5448fe8815d2':
        raise ValueError('Workflow changed; run fresh measurements')
    record = json.loads(run('gh', 'api', f'repos/{repository}/actions/runs/{run_id}'))
    measured = record['head_sha']
    if (record['event'] != 'workflow_dispatch' or record['path'] != '.github/workflows/ci.yml'
            or record['status'] != 'completed' or not re.fullmatch(r'[0-9a-f]{40}', measured)):
        raise ValueError('Evidence must come from this completed manual CI workflow')
    if run('git', 'rev-parse', measured + ':.github/workflows/ci.yml').strip() != 'b8c7d5ff6a63e19fcf89825001b16fc7776a8d26':
        raise ValueError('Measured workflow differs from the reviewed environment')
    jobs = json.loads(run('gh', 'api', f'repos/{repository}/actions/runs/{run_id}/jobs'))['jobs']
    steps = {s['name']: s['conclusion'] for job in jobs for s in job['steps']}
    required = ['Measure clipboard image decoding', 'Compare baseline and current runtime work',
                'Measure full app idle and Settings workloads', 'Check disabled feature startup IO']
    if not all(steps.get(name) == 'success' for name in required):
        raise ValueError('Every reused performance step must have succeeded')
    changed = set(run('git', 'diff', '--name-only', measured, '--', 'Sources',
                      'Resources', 'Package.swift', 'Package.resolved', 'Scripts').splitlines())
    if run('git', 'ls-files', '--others', '--exclude-standard', '--', 'Sources',
           'Resources', 'Scripts').strip():
        raise ValueError('Untracked product or benchmark inputs exist')
    # The measured commands omit --suite, so they do not call these native fixtures.
    if changed - {'Scripts/probe_icons.py', 'Scripts/probe_settings_reopen.py',
                  'Scripts/reuse_performance.py'}:
        raise ValueError('Product, build or benchmark inputs changed: ' + ', '.join(sorted(changed)))
    workflow = Path('.github/workflows/ci.yml').read_text()
    previous = run('git', 'show', measured + ':.github/workflows/ci.yml')
    commands = lambda text: [line.strip() for line in text.splitlines()
                             if line.strip().startswith('run: python3 Scripts/probe_')
                             and any('/' + name + '.py ' in line for name in
                                     ['probe_clipboard_images', 'probe_performance',
                                      'probe_app_performance', 'probe_idle_resources'])]
    if commands(previous) != commands(workflow) or len(commands(workflow)) != 4:
        raise ValueError('Measured command flags changed')
    output = Path('build/performance')
    run('gh', 'run', 'download', run_id, '--repo', repository, '--name',
        'performance', '--dir', str(output), seconds=60)
    for path, state in [('app/results.json', 'measured'),
                        ('clipboard-images/result.json', 'pass'),
                        ('paired/results.json', 'pass within recorded proof boundaries'),
                        ('feature-off/results.json', 'pass')]:
        data = json.loads((output / path).read_text())
        if data.get('candidate', data.get('candidate_head')) != measured or data['status'] != state:
            raise ValueError('Wrong source or failed measurement in ' + path)
    receipt = {'measured_run': run_id, 'measured_source': measured,
               'checked_source': run('git', 'rev-parse', 'HEAD').strip(),
               'product_tree': run('git', 'rev-parse', 'HEAD:Sources/Flux').strip(),
               'performance_steps': {name: steps[name] for name in required},
               'boundary': 'Reused measurements; byte-identical product, build and benchmark inputs. '
                           'Native correctness checks run again on the checked source.'}
    (output / 'reuse.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    main()
