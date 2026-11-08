#!/usr/bin/env python3
"""Build a matching-signed diagnostic bundle. It cannot launch the product UI."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]


def run(arguments, seconds=30):
    result = subprocess.run(arguments, cwd=ROOT, capture_output=True,
                            text=True, timeout=seconds)
    if result.returncode:
        raise RuntimeError(f"{arguments[0]} exited {result.returncode}: "
                           f"{result.stdout[-6000:]}\n{result.stderr[-6000:]}")
    return result.stdout.strip()


def main():
    layout = sys.argv[1:] == ["--layout"]
    if sys.argv[1:] and not layout:
        raise RuntimeError("Expected no arguments or --layout")
    product = "FluxMenuBarLayoutProbe" if layout else "FluxMenuCaptureProbe"
    identity = os.environ.get("CODESIGN_IDENTITY", "")
    keychain = os.environ.get("CODESIGN_KEYCHAIN", "")
    if not identity or identity == "-" or not keychain:
        raise RuntimeError("The existing Flux certificate identity is required")
    run(["swift", "build", "-c", "release", "--product", product], 180)
    binaries = Path(run(["swift", "build", "-c", "release", "--show-bin-path"]))
    output = ROOT / "build" / ("native-layout-probe" if layout else "native-capture-probe")
    output.mkdir(parents=True, exist_ok=False)
    bundle = output / "Flux.app"
    contents = bundle / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    shutil.copy2(binaries / product, contents / "MacOS" / "Flux")
    with (ROOT / "Resources" / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    revision = run(["git", "rev-parse", "HEAD"])
    info["FluxProbeOnly"] = True
    # The diagnostic must launch beside the product, never reuse its process.
    info["LSMultipleInstancesProhibited"] = False
    if layout:
        info["FluxLayoutProbeOnly"] = True
    info["FluxProbeSourceRevision"] = revision
    info.pop("CFBundleIconFile", None)
    with (contents / "Info.plist").open("wb") as stream:
        plistlib.dump(info, stream)
    (contents / "PkgInfo").write_text("APPL????")
    run(["codesign", "--force", "--sign", identity, "--keychain", keychain,
         "--identifier", "com.flux.menubar", str(bundle)])
    run(["codesign", "--verify", "--deep", "--strict", str(bundle)])
    prefix = output / "signer"
    run(["codesign", "--display", "--extract-certificates=" + str(prefix), str(bundle)])
    expected = subprocess.run(["openssl", "x509", "-in", str(ROOT / "Resources" / "FluxSigning.pem"),
                               "-outform", "DER"], check=True, capture_output=True, timeout=15).stdout
    leaf = Path(str(prefix) + "0").read_bytes()
    if leaf != expected:
        raise RuntimeError("Capture probe signing certificate differs from Flux")
    archive = output / ("FluxLayoutProbe.zip" if layout else "FluxCaptureProbe.zip")
    run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(bundle), str(archive)])
    report = {"sourceRevision": revision, "probeOnly": True, "layoutProbe": layout,
              "multipleInstancesProhibited": info["LSMultipleInstancesProhibited"], "bundleID": info["CFBundleIdentifier"],
              "leafSHA256": hashlib.sha256(leaf).hexdigest(), "sizeBytes": archive.stat().st_size,
              "sha256": hashlib.sha256(archive.read_bytes()).hexdigest()}
    (output / "artifact.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))


if __name__ == "__main__":
    main()
