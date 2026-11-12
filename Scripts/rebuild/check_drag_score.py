#!/usr/bin/env python3
"""Score the editor's reproduced centre-drop failure through native Swift tests."""
import re
import signal
import check_menu_window_score as runner
runner.OUTPUT = runner.ROOT / "build/drag-score"
runner.NEW_FILES.add("Scripts/rebuild/check_drag_score.py")
def score_logs(directory, conclusion):
    runner.passing(directory, "FluxCoreTests", 102)
    runner.passing(directory, "FluxPlatformTests", 53)
    value = runner.read_log(directory, "FluxUITests")
    marks = re.findall(r"^DRAG_DROP_FAILURES=([0-9]+)$", value, re.M)
    runner.require(len(marks) == 1, "missing drag score")
    score = int(marks[0])
    count, result, issues = runner.summary(value, "FluxUITests")
    expected = int(score != 0)
    runner.require(count >= 26 and issues == expected and result == ("failed" if score else "passed"), "unexpected UI failure")
    failed = re.findall(r"^.*?Test (?!run with )([^\n]+?) failed after [^\n]+with ([0-9]+) issues?\.", value, re.M)
    runner.require(len(failed) == expected and all(name == "centredDropsReorderInEitherDirection()" and int(n) == 1 for name, n in failed), "unexpected failed test")
    runner.require(conclusion == ("failure" if score else "success"), "wrong CI result")
    if not score:
        runner.passing(directory, "FluxApplicationTests", 81)
    return score
runner.score_logs = score_logs
if __name__ == "__main__":
    signal.signal(signal.SIGTERM, runner.interrupted)
    runner.main()
