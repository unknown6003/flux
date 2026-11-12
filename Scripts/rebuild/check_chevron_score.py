#!/usr/bin/env python3
"""Run the native chevron regression and all existing native guards."""
import re
from pathlib import Path
import check_menu_window_score as runner

original_score_logs = runner.score_logs

runner.OUTPUT = runner.ROOT / "build/chevron-score"
runner.NEW_FILES.add("Scripts/rebuild/check_chevron_score.py")

def score_logs(directory, conclusion):
    runner.passing(directory, "FluxCoreTests", 100)
    runner.passing(directory, "FluxPlatformTests", 53)
    runner.passing(directory, "FluxUITests", 25)
    value = runner.read_log(directory, "FluxApplicationTests")
    marks = re.findall(r"^CHEVRON_FAILURES=([0-9]+)$", value, re.M)
    runner.require(len(marks) == 1, "expected exactly one chevron score")
    score = int(marks[0])
    count, result, issues = runner.summary(value, "FluxApplicationTests")
    expected = 1 if score else 0
    runner.require(count >= 76 and issues == expected and result == ("failed" if score else "passed"),
                   "unexpected application completion or failure count")
    failures = re.findall(r"^.*?Test (?!run with )([^\n]+?) failed after [^\n]+with ([0-9]+) issues?\.$", value, re.M)
    recorded = re.findall(r"^.*?Test ([^\n]+?) recorded an issue", value, re.M)
    runner.require(len(failures) == expected and len(recorded) == expected,
                   "unexpected failing test or issue")
    runner.require(all(name == "chevronEditorClickScenarios()" and int(n) == 1 for name, n in failures)
                   and all(name == "chevronEditorClickScenarios()" for name in recorded),
                   "a test outside the chevron scenarios failed")
    runner.require(conclusion == ("failure" if score else "success"), "CI conclusion contradicts score")
    if not score:
        runner.passing(directory, "FluxApplicationTests", 76)
        original_score_logs(directory, conclusion)
    return score

runner.score_logs = score_logs
if __name__ == "__main__":
    runner.main()
