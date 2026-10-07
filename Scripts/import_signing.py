#!/usr/bin/env python3
"""Import the release identity into one private GitHub runner keychain."""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import signal
import stat
import subprocess
import sys


SECURITY = "/usr/bin/security"
OPENSSL = "/usr/bin/openssl"
CERTIFICATE = Path(__file__).resolve().parents[1] / "Resources/FluxSigning.pem"
MARKER = "owner.json"
KEYCHAIN = "release.keychain-db"
ARCHIVE = "identity.p12"


class SigningError(Exception):
    pass


def run(stage, args, *, data=None, timeout=30):
    """Capture all output. Errors name the stage, never the secret input."""
    env = {key: value for key, value in os.environ.items()
           if key not in ("FLUX_SIGNING_P12", "FLUX_SIGNING_PASSWORD")}
    process = subprocess.Popen(args, stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               env=env, start_new_session=True)
    try:
        output, _ = process.communicate(data, timeout=timeout)
    except BaseException:
        try:
            os.killpg(process.pid, signal.SIGTERM)
            process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate(timeout=5)
        except ProcessLookupError:
            pass
        raise SigningError(f"{stage} stopped before completion") from None
    if process.returncode:
        raise SigningError(f"{stage} failed with exit code {process.returncode}")
    return output


def security_input(stage, args):
    # security's line parser supports quoted strings and backslash escapes.
    # A single piped command retains its exit status and does not echo input.
    tokens = []
    for arg in args:
        if any(char in str(arg) for char in "\x00\r\n"):
            raise SigningError(f"{stage} has an unsupported input character")
        tokens.append('"' + str(arg).replace("\\", "\\\\").replace('"', '\\"') + '"')
    command = (" ".join(tokens) + "\n").encode()
    if len(command) >= 4096 or len(tokens) > 32:
        raise SigningError(f"{stage} exceeds security's input limit")
    return run(stage, [SECURITY, "-i", "-q"], data=command)


def release_tag():
    return (os.environ.get("GITHUB_REF", "").startswith("refs/tags/v")
            or (os.environ.get("GITHUB_REF_TYPE") == "tag"
                and os.environ.get("GITHUB_REF_NAME", "").startswith("v")))


def runner_paths():
    if sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true":
        raise SigningError("Signing import and cleanup require a macOS GitHub runner")
    raw_root = os.environ.get("RUNNER_TEMP", "")
    if not raw_root or any(char in raw_root for char in "\x00\r\n"):
        raise SigningError("RUNNER_TEMP is missing or invalid")
    root = Path(raw_root)
    if not root.is_absolute():
        raise SigningError("RUNNER_TEMP must be an absolute path")
    root = root.resolve(strict=True)
    if root == Path("/") or not root.is_dir():
        raise SigningError("RUNNER_TEMP must be a runner directory")
    run_id = os.environ.get("GITHUB_RUN_ID", "")
    attempt = os.environ.get("GITHUB_RUN_ATTEMPT", "")
    job = os.environ.get("GITHUB_JOB", "")
    if not re.fullmatch(r"[0-9]+", run_id) or not re.fullmatch(r"[0-9]+", attempt):
        raise SigningError("GitHub run identity is missing or invalid")
    if not re.fullmatch(r"[A-Za-z0-9_-]+", job):
        raise SigningError("GitHub job identity is missing or invalid")
    directory = root / f"flux-signing-{run_id}-{attempt}-{job}"
    owner = {"kind": "flux-release-signing", "version": 1,
             "run": run_id, "attempt": attempt, "job": job}
    return root, directory, owner


def check_owned(path, *, directory=False):
    info = path.lstat()
    expected_type = stat.S_ISDIR if directory else stat.S_ISREG
    if info.st_uid != os.getuid() or not expected_type(info.st_mode):
        raise SigningError("Refusing an unowned or linked signing path")


def clean(directory, owner):
    if not directory.exists() and not directory.is_symlink():
        return
    check_owned(directory, directory=True)
    marker = directory / MARKER
    check_owned(marker)
    if json.loads(marker.read_text()) != owner:
        raise SigningError("Refusing cleanup of another signing run")
    known = {MARKER, KEYCHAIN, ARCHIVE}
    if any(path.name not in known for path in directory.iterdir()):
        raise SigningError("Refusing cleanup of unknown signing files")
    for path in directory.iterdir():
        check_owned(path)
    archive = directory / ARCHIVE
    archive.unlink(missing_ok=True)
    keychain = directory / KEYCHAIN
    if keychain.exists():
        run("Delete private signing keychain", [SECURITY, "delete-keychain", str(keychain)])
        if keychain.exists():
            raise SigningError("The private signing keychain was not deleted")
    marker.unlink()
    directory.rmdir()


def certificate_der(pem):
    return run("Read signing certificate", [OPENSSL, "x509", "-outform", "DER"],
               data=pem, timeout=10)


def preferences():
    return (run("Read keychain search list", [SECURITY, "list-keychains", "-d", "user"]),
            run("Read default keychain", [SECURITY, "default-keychain", "-d", "user"]))


def export_identity(root, fingerprint, keychain):
    raw_file = os.environ.get("GITHUB_ENV", "")
    if not raw_file or any(char in raw_file for char in "\x00\r\n"):
        raise SigningError("GITHUB_ENV is missing or invalid")
    env_file = Path(raw_file)
    if not env_file.is_absolute() or env_file.is_symlink():
        raise SigningError("GITHUB_ENV must be a regular runner file")
    env_file = env_file.resolve(strict=True)
    if not env_file.is_relative_to(root):
        raise SigningError("GITHUB_ENV must be inside RUNNER_TEMP")
    check_owned(env_file)
    descriptor = os.open(env_file, os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "a") as stream:
        stream.write(f"CODESIGN_IDENTITY={fingerprint}\nCODESIGN_KEYCHAIN={keychain}\n")


def import_identity(encoded, password):
    root, directory, owner = runner_paths()
    if any(char in password for char in "\x00\r\n"):
        raise SigningError("FLUX_SIGNING_PASSWORD must be one line")
    try:
        archive_bytes = base64.b64decode("".join(encoded.split()), validate=True)
    except (ValueError, UnicodeEncodeError):
        raise SigningError("FLUX_SIGNING_P12 is not valid base64") from None
    if not archive_bytes or len(archive_bytes) > 1_048_576:
        raise SigningError("FLUX_SIGNING_P12 is empty or too large")
    expected_der = certificate_der(CERTIFICATE.read_bytes())
    fingerprint = hashlib.sha1(expected_der).hexdigest().upper()
    before = preferences()
    directory.mkdir(mode=0o700)
    (directory / MARKER).write_text(json.dumps(owner))
    (directory / MARKER).chmod(0o600)
    archive = directory / ARCHIVE
    keychain = directory / KEYCHAIN
    try:
        descriptor = os.open(archive, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(archive_bytes)
        keychain_password = secrets.token_urlsafe(32)
        security_input("Create private signing keychain",
                       ["create-keychain", "-p", keychain_password, keychain])
        run("Set private keychain timeout",
            [SECURITY, "set-keychain-settings", "-lut", "1800", str(keychain)])
        security_input("Unlock private signing keychain",
                       ["unlock-keychain", "-p", keychain_password, keychain])
        security_input("Import release identity",
                       ["import", archive, "-k", keychain, "-P", password,
                        "-T", "/usr/bin/codesign"])
        archive.unlink()
        security_input("Allow Apple signing tools",
                       ["set-key-partition-list", "-S", "apple-tool:,apple:",
                        "-s", "-k", keychain_password, keychain])
        certificates = run("Check imported certificate",
                           [SECURITY, "find-certificate", "-a", "-p", str(keychain)])
        blocks = re.findall(rb"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----",
                            certificates, re.DOTALL)
        if not any(certificate_der(block) == expected_der for block in blocks):
            raise SigningError("Imported certificate does not match Resources/FluxSigning.pem")
        identities = run("Check imported signing identity",
                         [SECURITY, "find-identity", "-p", "codesigning", str(keychain)])
        if fingerprint.encode() not in identities.upper():
            raise SigningError("The matching certificate has no signing private key")
        if preferences() != before:
            raise SigningError("Private import changed the keychain preferences")
        export_identity(root, fingerprint, keychain)
        print("Release signing identity imported and checked")
    except BaseException:
        clean(directory, owner)
        raise
    finally:
        archive.unlink(missing_ok=True)


def main():
    def stop(_signal, _frame):
        raise SigningError("Signing setup was stopped")

    signal.signal(signal.SIGTERM, stop)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cleanup", action="store_true")
    options = parser.parse_args()
    if options.cleanup:
        _, directory, owner = runner_paths()
        clean(directory, owner)
        print("Private signing keychain cleanup complete")
        return
    encoded = os.environ.get("FLUX_SIGNING_P12", "")
    password = os.environ.get("FLUX_SIGNING_PASSWORD", "")
    if bool(encoded) != bool(password):
        raise SigningError("Both FLUX_SIGNING_P12 and FLUX_SIGNING_PASSWORD are required")
    if not encoded:
        if release_tag():
            raise SigningError("Release tags require the persistent signing identity")
        print("No signing secrets configured. This development build uses ad-hoc signing")
        return
    import_identity(encoded, password)


if __name__ == "__main__":
    try:
        main()
    except (SigningError, OSError, ValueError) as error:
        # Library exceptions can include input paths, but never secret values.
        print(f"Signing setup failed: {error}", file=sys.stderr)
        sys.exit(1)
