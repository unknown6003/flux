#!/usr/bin/env python3
"""Build an unpublished native integration app with Flux's pinned signer."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def run(arguments, seconds=30):
    process = subprocess.Popen(arguments, cwd=ROOT, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, start_new_session=True)
    try:
        output = process.communicate(timeout=seconds)[0]
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate(timeout=5)
        raise RuntimeError(f"{arguments[0]} exceeded {seconds}s") from None
    if process.returncode:
        raise RuntimeError(f"{arguments[0]} exited {process.returncode}: "
                           + output[-8000:].decode(errors="replace"))
    return output.decode(errors="replace").strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--performance-trace", action="store_true")
    args = parser.parse_args()
    identity = os.environ.get("CODESIGN_IDENTITY", "")
    keychain = os.environ.get("CODESIGN_KEYCHAIN", "")
    if not identity or identity == "-" or not keychain:
        raise RuntimeError("The existing Flux signing identity is required")
    output = ROOT / ("build/native-performance-trace" if args.performance_trace else "build/native-candidate")
    output.mkdir(parents=True, exist_ok=False)
    flags = ["-Xswiftc", "-DFLUX_PERFORMANCE_TRACE"] if args.performance_trace else []
    run(["swift", "build", "-c", "release", "--product", "FluxNativeCandidate"] + flags, 240)
    binaries = Path(run(["swift", "build", "-c", "release", "--show-bin-path"]))
    vendor = ROOT / "Vendor/mediaremote-adapter"
    cmake = output / "mediaremote-build"
    run(["cmake", "-S", str(vendor), "-B", str(cmake), "-DCMAKE_BUILD_TYPE=Release"], 30)
    run(["cmake", "--build", str(cmake), "--target", "MediaRemoteAdapter", "--config", "Release"], 90)
    framework = cmake / "MediaRemoteAdapter.framework"
    if not framework.is_dir():
        raise RuntimeError("The native candidate requires its media adapter")
    bundle = output / "Flux.app"
    contents = bundle / "Contents"
    for name in ["MacOS", "Resources", "Frameworks"]:
        (contents / name).mkdir(parents=True, exist_ok=False)
    shutil.copy2(binaries / "FluxNativeCandidate", contents / "MacOS/Flux")
    shutil.copytree(framework, contents / "Frameworks/MediaRemoteAdapter.framework", symlinks=True)
    shutil.copy2(vendor / "bin/mediaremote-adapter.pl", contents / "Resources/mediaremote-adapter.pl")
    shutil.copy2(vendor / "LICENSE", contents / "Resources/MediaRemoteAdapter-LICENSE.txt")
    iconset = output / "AppIcon.iconset"
    run(["swift", str(ROOT / "Scripts/generate_icon.swift"), str(iconset)], 45)
    run(["iconutil", "-c", "icns", str(iconset), "-o", str(contents / "Resources/AppIcon.icns")])
    with (ROOT / "Resources/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    revision = run(["git", "rev-parse", "HEAD"])
    info.update(FluxNativeCandidate=True, FluxNativeSourceRevision=revision,
                FluxPerformanceTraceCandidate=args.performance_trace,
                CFBundleShortVersionString="0.22.0", CFBundleVersion="64")
    with (contents / "Info.plist").open("wb") as stream:
        plistlib.dump(info, stream)
    (contents / "PkgInfo").write_text("APPL????")
    signing = ["codesign", "--force", "--sign", identity, "--keychain", keychain]
    run(signing + [str(contents / "Frameworks/MediaRemoteAdapter.framework")])
    run(signing + ["--identifier", "com.flux.menubar", str(bundle)])
    run(["codesign", "--verify", "--deep", "--strict", str(bundle)])
    prefix = output / "signer"
    run(["codesign", "--display", "--extract-certificates=" + str(prefix), str(bundle)])
    expected = subprocess.run(["openssl", "x509", "-in", str(ROOT / "Resources/FluxSigning.pem"),
                               "-outform", "DER"], check=True, capture_output=True, timeout=15).stdout
    leaf = Path(str(prefix) + "0").read_bytes()
    if leaf != expected:
        raise RuntimeError("The native candidate signer differs from installed Flux")
    archive = output / ("FluxPerformanceTraceCandidate.zip" if args.performance_trace else "FluxNativeCandidate.zip")
    run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(bundle), str(archive)], 45)
    report = dict(sourceRevision=revision, candidateOnly=True, performanceTraceEnabled=args.performance_trace,
                  executableSHA256=hashlib.sha256((contents / "MacOS/Flux").read_bytes()).hexdigest(),
                  bundleID=info["CFBundleIdentifier"],
                  version=info["CFBundleShortVersionString"], build=info["CFBundleVersion"],
                  privateLockBridgeEnabled=False, positionHidingRequiresExplicitTrialFlag=True,
                  sameProcessMenuCaptureRequiresExplicitTemporaryDirectory=True,
                  leafSHA256=hashlib.sha256(leaf).hexdigest(), sizeBytes=archive.stat().st_size,
                  sha256=hashlib.sha256(archive.read_bytes()).hexdigest())
    (output / "artifact.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))


if __name__ == "__main__":
    main()
