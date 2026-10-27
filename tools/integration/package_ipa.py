#!/usr/bin/env python3
"""Package an existing signed iPhone app, replacing one IPA without retaining Payload."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import stat
import subprocess
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parents[2]
VARIANTS = {
    "development": ("Debug-Dev", "YiJie.speech-note.dev"),
    "production": ("Debug", "YiJie.speech-note"),
}


def package_ipa(app: Path, output: Path, bundle_id: str) -> dict:
    app = app.resolve()
    output = output.resolve()
    if app.suffix != ".app" or not app.is_dir():
        raise ValueError(f"App directory not found: {app}")
    if output.suffix != ".ipa" or app in output.parents:
        raise ValueError("IPA output must end in .ipa and be outside the source app")
    with (app / "Info.plist").open("rb") as source:
        info = plistlib.load(source)
    if info["CFBundleIdentifier"] != bundle_id:
        raise ValueError(f"Expected {bundle_id}, got {info['CFBundleIdentifier']}")
    if not (app / "embedded.mobileprovision").is_file():
        raise ValueError("App has no provisioning profile; build a signed iPhone app first")
    output.parent.mkdir(parents=True, exist_ok=True)
    # Keep the temporary IPA on the same filesystem for an atomic replacement.
    with tempfile.TemporaryDirectory(prefix=".package-", dir=output.parent.parent) as directory:
        work = Path(directory)
        payload = work / "Payload"
        payload.mkdir()
        staged_app = payload / app.name
        subprocess.run(["ditto", "--norsrc", "--noextattr", str(app), str(staged_app)], check=True)
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(staged_app)], check=True)
        temporary_ipa = work / "app.ipa"
        subprocess.run(
            ["ditto", "-c", "-k", "--norsrc", "--noextattr", "--keepParent", str(payload), str(temporary_ipa)],
            check=True,
        )
        with zipfile.ZipFile(temporary_ipa) as archive:
            for member in archive.infolist():
                if any(part.startswith("._") or part == "__MACOSX" for part in member.filename.split("/")):
                    raise ValueError(f"IPA contains AppleDouble metadata: {member.filename}")
            bad_file = archive.testzip()
            if bad_file:
                raise ValueError(f"IPA CRC check failed: {bad_file}")
            prefix = f"Payload/{app.name}/"
            if plistlib.loads(archive.read(prefix + "Info.plist")) != info:
                raise ValueError("Packaged Info.plist does not match source app")
            executable = archive.getinfo(prefix + info["CFBundleExecutable"])
            if not (executable.external_attr >> 16) & stat.S_IXUSR:
                raise ValueError("Packaged app executable lost its execute permission")
            # Ordinary ZIP extraction exposes extra files that ditto may consume as metadata.
            extracted = work / "extracted"
            archive.extractall(extracted)
            for member in archive.infolist():
                mode = member.external_attr >> 16
                if mode:
                    (extracted / member.filename).chmod(stat.S_IMODE(mode))
        subprocess.run(
            ["codesign", "--verify", "--deep", "--strict", str(extracted / "Payload" / app.name)],
            check=True,
        )
        digest = hashlib.sha256()
        with temporary_ipa.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
        result = {
            "ipa": str(output),
            "bundleIdentifier": info["CFBundleIdentifier"],
            "version": info["CFBundleShortVersionString"],
            "build": info["CFBundleVersion"],
            "bytes": temporary_ipa.stat().st_size,
            "sha256": digest.hexdigest(),
            "zipVerified": True,
        }
        temporary_ipa.replace(output)

    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("variant", nargs="?", choices=VARIANTS, default="development")
    parser.add_argument("--app", type=Path, help="Existing signed .app; no build or install is performed")
    parser.add_argument("--output", type=Path, help="IPA to replace after validation succeeds")
    args = parser.parse_args()
    configuration, bundle_id = VARIANTS[args.variant]
    app = args.app or ROOT / f"build/VoiceContextAgent/Build/Products/{configuration}-iphoneos/VoiceContextAgent.app"
    output = args.output or ROOT / f"build/distribution/{args.variant}/public/app.ipa"
    try:
        result = package_ipa(app, output, bundle_id)
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        parser.exit(1, f"Packaging failed: {error}\n")
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
