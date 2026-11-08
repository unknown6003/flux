#!/usr/bin/env python3
"""Run the rewritten policy, transaction and real status-item checks serially."""

import argparse
import json
import os
from pathlib import Path
import sys
import time
from probe_update import run

ROOT = Path(__file__).resolve().parents[1]

CASES = [
    ("assessment", "probe_assessment.py", [], None),
    ("visibility-policy", "probe_visibility_policy.py", [], None),
    ("arrangement", "probe_arrangement.py", [], None),
    ("settings", "probe_icons.py", ["--case", "settings"], None),
    ("narrow-reorder", "probe_icons.py", ["--case", "narrow-reorder"], None),
    ("wide-reorder", "probe_icons.py", ["--case", "wide-reorder"], None),
    ("drag-insertion", "probe_icons.py", ["--case", "drag-insertion"], None),
    ("live-title", "probe_icons.py", ["--case", "live-title"], None),
    ("identity-replacement", "probe_icons.py", ["--case", "identity-replacement"], None),
    ("covered-reorder", "probe_icons.py", ["--case", "covered-reorder"], None),
]

ALIASES = {
    "insertion": "narrow-reorder",
    "wide-insertion": "wide-reorder",
    "saved-section-insertion": "wide-reorder",
    "saved-section-arrow": "wide-reorder",
    "drag-context": "drag-insertion",
}


def select_cases(selected, include_baselines):
    selected = {ALIASES.get(name, name) for name in selected}
    unknown = selected - {case[0] for case in CASES}
    if unknown:
        raise ValueError("Unknown native icon case: " + ", ".join(sorted(unknown)))
    selection = []
    for case in CASES:
        if selected:
            reason = None if case[0] in selected else "not selected"
        else:
            reason = None
        selection.append((case, reason))
    return selection


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
               "Current product checks run serially. Old manager-internal cases are retired.", "",
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
    if options.include_baselines:
        print("Historical manager cases are retired; run the separate visibility-policy control explicitly.")
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
