#!/usr/bin/env python3
"""Run current icon checks serially; historical broken versions are opt-in."""

import argparse
import json
import os
from pathlib import Path
import sys
import time
from probe_update import run

ROOT = Path(__file__).resolve().parents[1]

CASES = [
    ('assessment-baseline', 'probe_assessment.py', ['--baseline-ref',
        '08eafce418581e0e5f7e291cc6ffbcd73fdf8860'], 'late B completion must not install B'),
    ('assessment', 'probe_assessment.py', [], None),
    ('read-only-baseline', 'probe_layout_scan.py', ['--case', 'read-only', '--hider-ref',
        'ee22f6f176bfaba0d230c1afad5622e81cb5db9f'], 'read-only layout observer started hiding without apply'),
    ('read-only', 'probe_layout_scan.py', ['--case', 'read-only'], None),
    ('batch-read-baseline', 'probe_layout_scan.py', ['--case', 'batch', '--hider-ref',
        '7cdb20ae7e35312c7952b03aaf0195186b1a33a6'], 'an unreadable app discarded the readable app'),
    ('sibling-scan-baseline', 'probe_layout_scan.py', ['--case', 'batch', '--hider-ref',
        '11c235b714390c5ace3c55595ae6e16a48c144cb'], 'an incomplete sibling scan changed saved visibility'),
    ('batch', 'probe_layout_scan.py', ['--case', 'batch'], None),
    ('geometry-baseline', 'probe_icons.py', ['--native-geometry', '--manager-ref',
        '66dbf21690e7d0936162744822dea44abdf342aa'], 'AX position disagrees with the drawn fixture'),
    ('geometry', 'probe_icons.py', ['--native-geometry'], None),
    ('inventory-baseline', 'probe_icons.py', ['--native-refresh-retry', '--manager-ref',
        '11c235b714390c5ace3c55595ae6e16a48c144cb'], 'a transient inventory read discarded the completed native move'),
    ('inventory-retry', 'probe_icons.py', ['--native-refresh-retry'], None),
    ('programmatic-inventory-baseline', 'probe_icons.py', ['--move-refresh-retry', '--manager-ref',
        '94927b1cac66258b2bd694e1fce74edceb1265d5'], 'a transient programmatic inventory read lost the Shown assignment'),
    ('programmatic-inventory', 'probe_icons.py', ['--move-refresh-retry'], None),
    ('programmatic-inventory-failure', 'probe_icons.py', ['--move-refresh-failure'], None),
    ('position-save-baseline', 'probe_icons.py', ['--move-save-retry', '--manager-ref',
        '0b947b2914e64dbfdb1854bae457fc52a6ce46f9'], 'a transient position save lost the programmatic Shown assignment'),
    ('position-save-retry', 'probe_icons.py', ['--move-save-retry'], None),
    ('position-warning-baseline', 'probe_icons.py', ['--move-save-failure', '--manager-ref',
        'cb93553ab503bb5e20fb341ddb2a2c7a92c7afbf'], 'a successful retry retained the old save warning'),
    ('position-save-failure', 'probe_icons.py', ['--move-save-failure'], None),
    ('programmatic-overlap-baseline', 'probe_icons.py', ['--move-overlap', '--manager-ref',
        '11c235b714390c5ace3c55595ae6e16a48c144cb', '--hider-ref',
        '11c235b714390c5ace3c55595ae6e16a48c144cb'], 'programmatic verification saved an unfinished native sibling drag'),
    ('programmatic-overlap', 'probe_icons.py', ['--move-overlap'], None),
    ('retry-overlap-baseline', 'probe_icons.py', ['--move-retry-overlap', '--manager-ref',
        '6095919f8727b42def9ab2ed7f27e0d007f14010'], 'programmatic retry undid the later native move'),
    ('retry-overlap', 'probe_icons.py', ['--move-retry-overlap'], None),
    ('overlap', 'probe_icons.py', ['--native-overlap'], None),
    ('sibling-baseline', 'probe_icons.py', ['--native-sibling', '--manager-ref',
        '7cdb20ae7e35312c7952b03aaf0195186b1a33a6'], 'an unchanged first icon discarded the second icon'),
    ('sibling', 'probe_icons.py', ['--native-sibling'], None),
    ('move-close-baseline', 'probe_icons.py', ['--move-close', '--manager-ref',
        '195cb7063f614b878a3df82b9874b31849ac9738'],
        'closing management applied hiding before the pending move was verified'),
    ('move-close', 'probe_icons.py', ['--move-close'], None),
    ('native-close', 'probe_icons.py', ['--native-close'], None),
    ('settings', 'probe_icons.py', [], None),
    ('menu-context', 'probe_icons.py', ['--menu-context'], None),
    ('drag-context', 'probe_icons.py', ['--drag-context'], None),
    ('stale-section-baseline', 'probe_icons.py', ['--stale-frame', 'section', '--manager-ref',
        '0d92d35c73521707bf3a8408ec67b008dd43017e'], 'the real fixture did not move to'),
    ('stale-section', 'probe_icons.py', ['--stale-frame', 'section'], None),
    ('stale-arrow-baseline', 'probe_icons.py', ['--stale-frame', 'arrow', '--manager-ref',
        '0d92d35c73521707bf3a8408ec67b008dd43017e'], 'the Settings arrow did not change the real icon order'),
    ('stale-arrow', 'probe_icons.py', ['--stale-frame', 'arrow'], None),
    ('removed-row-baseline', 'probe_icons.py', ['--removed-row', '--manager-ref',
        '0e45a2291b9ac1b702d251c2c3d2c5badc4178dd'], 'a removed icon row started a move of its replacement'),
    ('removed-row', 'probe_icons.py', ['--removed-row'], None),
    ('settings-reopen-baseline', 'probe_settings_reopen.py', ['--controller-ref',
        '9ee29cac995b57a33381c5bbd74526be223aa869'], 'same-tab reopen: management reveal must be true'),
    ('settings-reopen', 'probe_settings_reopen.py', [], None),
    ('menu-wait-baseline', 'probe_icons.py', ['--menu-context', '--manager-ref',
        '4ac25a1abe27016202533d2369ed7b8a985782fe'], 'native move started before its menu window closed'),
    ('menu-expired-baseline', 'probe_icons.py', ['--menu-expired', '--manager-ref',
        'c691fe1c2b1f475eb22239e1a65662cfa7394aac'], 'an expired menu request posted native input'),
    ('menu-expired', 'probe_icons.py', ['--menu-expired'], None),
    ('insertion', 'probe_icons.py', ['--insertion'], None),
]


def select_cases(selected, include_baselines):
    unknown = selected - {case[0] for case in CASES}
    if unknown:
        raise ValueError("Unknown native icon case: " + ", ".join(sorted(unknown)))
    return [(case, None if (case[0] in selected if selected else
                           include_baselines or case[3] is None) else
             ("not selected" if selected else "historical baseline; opt in with --include-baselines"))
            for case in CASES]


def run_cases(selection, output):
    output.mkdir(parents=True, exist_ok=True)
    results = []
    started = time.monotonic()
    for (label, script, arguments, expected_failure), skip_reason in selection:
        seconds = None
        if skip_reason:
            status = "SKIP"
            log = skip_reason
        else:
            case_started = time.monotonic()
            try:
                result = run([sys.executable, str(ROOT / "Scripts" / script)] + arguments,
                             seconds=180, check=False, cwd=ROOT)
                log = result.stdout
                passed = (result.returncode == 1 and expected_failure in log
                          if expected_failure else result.returncode == 0)
            except (RuntimeError, OSError) as error:
                log, passed = str(error), False
            seconds = round(time.monotonic() - case_started, 3)
            status = "PASS" if passed else "FAIL"
            (output / (label + ".log")).write_text(log)
            if not passed:
                print(log, flush=True)
        results.append(dict(case=label, result=status, seconds=seconds,
                            reason=skip_reason, expected_failure=expected_failure))
        (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        detail = skip_reason if skip_reason else f"{seconds:.3f}s"
        print(f"{status}: {label} ({detail})", flush=True)
    elapsed = time.monotonic() - started
    summary = ["### Native icon cases", "",
               "Current checks run serially. Historical baselines require explicit opt-in.", "",
               "| Case | Result | Seconds / skip reason |", "| --- | --- | --- |"]
    for item in results:
        detail = item["reason"] if item["result"] == "SKIP" else f'{item["seconds"]:.3f}'
        summary.append(f'| {item["case"]} | {item["result"]} | {detail} |')
    summary += ["", f"Suite elapsed: {elapsed:.3f}s. Skipped checks are not passes.", ""]
    report = "\n".join(summary)
    (output / "summary.md").write_text(report)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as stream:
            stream.write(report)
    return any(item["result"] == "FAIL" for item in results)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cases", default=os.environ.get("FLUX_ICON_PROBE_CASES", ""),
                        help="Comma-separated diagnostic cases; explicit selection can include baselines")
    parser.add_argument("--include-baselines", action="store_true",
                        default=os.environ.get("FLUX_ICON_PROBE_BASELINES") == "true")
    parser.add_argument("--list", action="store_true", help="List selection without running native checks")
    options = parser.parse_args()
    selected = {value.strip() for value in options.cases.split(",") if value.strip()}
    try:
        selection = select_cases(selected, options.include_baselines)
    except ValueError as error:
        parser.error(str(error))
    if options.list:
        for case, reason in selection:
            print(f'{"SKIP" if reason else "RUN"}: {case[0]}' + (f" ({reason})" if reason else ""))
        return 0
    return int(run_cases(selection, ROOT / "build/icon-probe"))


if __name__ == "__main__":
    raise SystemExit(main())
