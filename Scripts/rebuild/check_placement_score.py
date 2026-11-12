#!/usr/bin/env python3
"""Score physical chevron-side placement with the unchanged native suites."""
import re
import check_menu_window_score as runner
runner.OUTPUT = runner.ROOT / "build/placement-score"
runner.NEW_FILES.add("Scripts/rebuild/check_placement_score.py")
def score_logs(directory, conclusion):
    value = runner.read_log(directory, "FluxCoreTests")
    marks = re.findall(r"^PLACEMENT_FAILURES=([0-9]+)$", value, re.M)
    runner.require(len(marks) == 1, "missing placement score")
    score = int(marks[0])
    count, result, issues = runner.summary(value, "FluxCoreTests")
    expected = int(score != 0)
    runner.require(count >= 101 and issues == expected and result == ("failed" if score else "passed"),
                   "unexpected core failure")
    failed = re.findall(r"^.*?Test (?!run with )([^\n]+?) failed after [^\n]+with ([0-9]+) issues?\.", value, re.M)
    runner.require(len(failed) == expected and all(name == "perAppPlacementRequiresTheRequestedSideOfTheChevron()" and int(n) == 1 for name, n in failed), "unexpected failed test")
    if score:
        runner.require(conclusion == "failure", "expected regression failure")
        return score
    for suite, minimum in [("FluxPlatformTests", 53), ("FluxUITests", 25), ("FluxApplicationTests", 76)]:
        runner.passing(directory, suite, minimum)
    runner.require(conclusion == ("failure" if score else "success"), "wrong CI result")
    return score
runner.score_logs = score_logs
if __name__ == "__main__":
    runner.main()
