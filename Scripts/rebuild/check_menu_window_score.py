#!/usr/bin/env python3
"""Score native menu-window regressions on macOS without changing HEAD or index.

Run with an outer deadline: timeout --signal=TERM --kill-after=10s 720s
python3 Scripts/rebuild/check_menu_window_score.py. --guard reuses the last proof.
"""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time
import uuid


ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "build/menu-window-score"
NEW_FILES = {
    "Sources/FluxPlatform/MenuBar/StatusMenuWindowPreview.swift",
    "Tests/FluxPlatformTests/StatusMenuWindowPreviewTests.swift",
    "Scripts/rebuild/check_menu_window_score.py",
}
SUMMARY = re.compile(
    r"Test run with ([1-9][0-9]*) tests?(?: in [0-9]+ suites?)? "
    r"(passed|failed) after [0-9.]+ seconds(?: with ([0-9]+) issues?)?\."
)
BAD_OUTPUT = re.compile(
    r"(?:^|\n).*?(?:error:|fatal error|signal [0-9]+|crashed|"
    r"Segmentation fault|Abort trap|no such module|unexpectedly exited)", re.I
)
DEADLINE = time.monotonic() + 690


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(command, timeout=20, env=None, check=True, cleanup=False):
    seconds = timeout if cleanup else min(timeout, DEADLINE - time.monotonic())
    require(seconds > 0, "score command reached its total deadline")
    process = subprocess.Popen(
        command, cwd=ROOT, env={**os.environ, "GIT_TERMINAL_PROMPT": "0", **(env or {})},
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=seconds)
    except BaseException:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate(timeout=3)
        raise
    require(not check or process.returncode == 0,
            f"{command[0]} {command[1]} failed with exit {process.returncode}")
    return stdout.strip()


def git(*args, **kwargs):
    return run(["git", *args], **kwargs)


def gh(*args, **kwargs):
    return run(["gh", *args], **kwargs)


def snapshot():
    """Use the same complete source collection for the build and saved guard."""
    source = git("rev-parse", "HEAD")
    tracked = set(git("ls-files", "--cached", "-z").split("\0")) - {""}
    untracked = set(git("ls-files", "--others", "--exclude-standard", "-z").split("\0")) - {""}
    unexpected = untracked - NEW_FILES
    require(not unexpected, "untracked files outside the snapshot allowlist: " + ", ".join(sorted(unexpected)))
    with tempfile.TemporaryDirectory(prefix="flux-menu-window-index-") as temp:
        env = {"GIT_INDEX_FILE": str(Path(temp) / "index")}
        git("read-tree", source, env=env)
        git("add", "-u", env=env)
        additions = sorted(path for path in tracked | (untracked & NEW_FILES)
                           if (ROOT / path).exists())
        # Include staged additions too, using working file contents rather than
        # the normal index. Chunk argv so the snapshot works in larger trees.
        for offset in range(0, len(additions), 200):
            git("add", "--", *additions[offset:offset + 200], env=env)
        tree = git("write-tree", env=env)
    return source, tree


def read_log(directory, suite):
    paths = list(directory.rglob(suite + ".log"))
    require(len(paths) == 1, f"expected one {suite}.log, found {len(paths)}")
    value = paths[0].read_text(errors="replace")
    require(not BAD_OUTPUT.search(value), f"{suite} contains a crash, import or build error")
    return value


def summary(value, suite):
    matches = SUMMARY.findall(value)
    require(len(matches) == 1, f"{suite} needs exactly one completed Swift Testing run")
    count, result, issues = matches[0]
    return int(count), result, int(issues or 0)


def passing(directory, suite, minimum):
    value = read_log(directory, suite)
    count, result, issues = summary(value, suite)
    require(count >= minimum and result == "passed" and issues == 0,
            f"{suite} did not complete at least {minimum} passing tests")
    require("recorded an issue" not in value and "failed after" not in value,
            f"{suite} contains an unexpected failure")
    print(f"{suite}: {count} passed", flush=True)


def score_logs(directory, conclusion):
    passing(directory, "FluxCoreTests", 100)
    value = read_log(directory, "FluxPlatformTests")
    marks = re.findall(r"^MENU_WINDOW_FAILURES=([0-9]+)$", value, re.M)
    require(len(marks) == 1, "expected exactly one MENU_WINDOW_FAILURES score line")
    score = int(marks[0])
    count, result, issues = summary(value, "FluxPlatformTests")
    expected = 1 if score else 0
    require(count >= 52 and issues == expected and result == ("failed" if score else "passed"),
            "platform completion count, result or issue count does not match the score")
    failures = re.findall(r"^.*?Test (?!run with )([^\n]+?) failed after [^\n]+with ([0-9]+) issues?\.$", value, re.M)
    recorded = re.findall(r"^.*?Test ([^\n]+?) recorded an issue", value, re.M)
    require(len(failures) == expected and len(recorded) == expected,
            "unexpected number of failing tests or recorded issues")
    require(all(name == "menuWindowRegressionScenarios()" and int(n) == 1 for name, n in failures)
            and all(name == "menuWindowRegressionScenarios()" for name in recorded),
            "a platform test other than menuWindowRegressionScenarios failed")
    passed = set(re.findall(r"^.*?Test (?!run with )([^\n]+?) passed after ", value, re.M))
    require(len(passed) >= 51 + (not score), "the existing 51 platform tests did not all pass")
    print(f"FluxPlatformTests: {count} completed, {len(passed)} passed, {issues} issues", flush=True)
    if score == 0:
        require(conclusion == "success", "zero score requires a successful whole CI run")
        passing(directory, "FluxUITests", 25)
        passing(directory, "FluxApplicationTests", 74)
        rating = read_log(directory, "FluxRatingProbe")
        rows = [json.loads(line) for line in rating.splitlines()
                if line.startswith('{"nativeRatingScenariosPassed"')]
        require(len(rows) == 1 and rows[0].get("nativeRatingScenariosPassed") == 4
                and rows[0].get("nativeIdentityScenariosPassed") == 1,
                "native confirmation scenarios did not complete")
    else:
        require(conclusion == "failure", "nonzero regression score requires an ordinary CI failure")
    return score


def find_run(branch, head, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        rows = json.loads(gh("run", "list", "--workflow", "ci.yml", "--branch", branch,
                             "--event", "workflow_dispatch", "--limit", "20", "--json",
                             "databaseId,headSha,headBranch,event", timeout=min(10, deadline - time.monotonic())))
        rows = [row for row in rows if row["headSha"] == head and row["headBranch"] == branch
                and row["event"] == "workflow_dispatch"]
        require(len(rows) <= 1, "more than one run matched the owned probe source")
        if rows:
            return str(rows[0]["databaseId"])
        time.sleep(min(2, max(0, deadline - time.monotonic())))
    raise RuntimeError("owned workflow run was not visible within 30 seconds")


def wait_run(run_id, branch, head):
    deadline = min(time.monotonic() + 600, DEADLINE - 45)
    while time.monotonic() < deadline:
        row = json.loads(gh("run", "view", run_id, "--json",
                            "status,conclusion,headSha,headBranch,event,url", timeout=15))
        require(row["headSha"] == head and row["headBranch"] == branch
                and row["event"] == "workflow_dispatch", "CI source no longer matches the owned probe")
        if row["status"] == "completed":
            return row
        time.sleep(min(5, max(0, deadline - time.monotonic())))
    raise RuntimeError("owned CI run did not finish within its bounded build deadline")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--guard", action="store_true")
    args = parser.parse_args()
    source, tree = snapshot()
    latest = OUTPUT / "latest.json"
    if args.guard:
        report = json.loads(latest.read_text())
        require(report.get("guard") is True and report.get("snapshotTree") == tree,
                "saved native guard is missing, failed, or belongs to different source")
        print(f"Native guard passed for tree {tree}, score {report['score']}")
        return
    OUTPUT.mkdir(parents=True, exist_ok=True)
    require(git("check-ignore", "build/menu-window-score/latest.json") != "",
            "score output must be ignored by Git")
    token = uuid.uuid4().hex
    branch = "probe/menu-window-score-" + token
    ref = "refs/heads/" + branch
    directory = OUTPUT / token
    directory.mkdir()
    report = dict(score=None, snapshotTree=tree, head=None, run=None,
                  originalSource=source, guard=False)
    pushed = False
    dispatched = False
    completed = False
    run_id = None
    failed = None
    try:
        head = git("commit-tree", tree, "-p", source, "-m", "Temporary menu-window native score")
        report["head"] = head
        pushed = True
        git("push", "origin", f"{head}:{ref}", timeout=25)
        dispatched = True
        gh("workflow", "run", "ci.yml", "--ref", branch, "-f", "native_core_only=true", timeout=20)
        run_id = find_run(branch, head)
        report["run"] = run_id
        print(f"Checking snapshot {head} in CI run {run_id}", flush=True)
        row = wait_run(run_id, branch, head)
        completed = True
        gh("run", "download", run_id, "--name", "native-test-logs", "--dir", str(directory), timeout=35)
        report["score"] = score_logs(directory, row["conclusion"])
        require(snapshot()[1] == tree, "source changed while CI was running")
        report["guard"] = True
        print(f"Native guard passed: {row['url']}", flush=True)
    except BaseException as error:
        failed = error
        report["error"] = str(error)
    finally:
        if dispatched and not run_id:
            try:
                run_id = find_run(branch, report["head"], timeout=8)
                report["run"] = run_id
            except BaseException:
                pass
        if run_id and not completed:
            try:
                state = json.loads(gh("run", "view", run_id, "--json",
                                      "status,headSha,headBranch", timeout=8, cleanup=True))
                require(state["headSha"] == report["head"] and state["headBranch"] == branch,
                        "refusing to cancel CI for another source")
                if state["status"] != "completed":
                    gh("run", "cancel", run_id, timeout=8, cleanup=True)
            except BaseException as error:
                report["guard"] = False
                failed = failed or error
                report["cleanupError"] = str(error)
        if pushed:
            try:
                remote = git("ls-remote", "origin", ref, timeout=8, cleanup=True)
                if remote:
                    require(remote.split()[0] == report["head"],
                            "owned remote probe changed; refusing deletion")
                    git("push", "origin", ":" + ref, timeout=10, cleanup=True)
            except BaseException as error:
                report["guard"] = False
                failed = failed or error
                report["cleanupError"] = str(error)
        encoded = json.dumps(report, indent=2) + "\n"
        (directory / "report.json").write_text(encoded)
        temporary = OUTPUT / (token + ".json")
        temporary.write_text(encoded)
        temporary.replace(latest)
    if failed:
        raise RuntimeError(str(failed)) from failed
    print(report["score"])


def interrupted(signum, frame):
    raise RuntimeError(f"score interrupted by signal {signum}")


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    try:
        main()
    except (RuntimeError, subprocess.TimeoutExpired, OSError, ValueError, KeyError) as error:
        print(f"Native score check failed: {error}", file=sys.stderr)
        sys.exit(1)
