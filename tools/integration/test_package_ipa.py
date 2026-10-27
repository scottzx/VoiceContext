#!/usr/bin/env python3
"""Test IPA replacement and cleanup on the macOS host, without building or installing."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import package_ipa


class PackageIPATests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="package-ipa-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        self.app = self.root / "VoiceContextAgent.app"
        self.app.mkdir()
        self.output = self.root / "distribution/development/public/app.ipa"
        self.bundle_id = "YiJie.speech-note.dev"
        self.info = {
            "CFBundleIdentifier": self.bundle_id,
            "CFBundleExecutable": "VoiceContextAgent",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "42",
        }
        (self.app / "Info.plist").write_bytes(plistlib.dumps(self.info))
        (self.app / "embedded.mobileprovision").write_bytes(b"test provisioning profile")
        self.executable = self.app / "VoiceContextAgent"
        self.executable.write_bytes(b"test executable\x00first")
        self.executable.chmod(0o755)
        self.real_run = subprocess.run
        self.codesign_commands = []

    def run_with_fake_codesign(self, command, *args, **kwargs):
        if command[0] == "codesign":
            self.codesign_commands.append(command)
            self.assertEqual(command[:-1], ["codesign", "--verify", "--deep", "--strict"])
            verified_app = Path(command[-1])
            self.assertEqual(verified_app.name, self.app.name)
            self.assertEqual(verified_app.parent.name, "Payload")
            self.assertIn(self.output.parent.parent, verified_app.parents)
            self.assertTrue(verified_app.is_dir())
            self.assertTrue(kwargs["check"])
            return subprocess.CompletedProcess(command, 0)
        return self.real_run(command, *args, **kwargs)

    def assert_no_staging(self):
        self.assertEqual(sorted(path.name for path in self.output.parent.parent.iterdir()), ["public"])
        self.assertEqual(sorted(path.name for path in self.output.parent.iterdir()), ["app.ipa"])

    def test_repeat_packaging_replaces_one_file_and_preserves_contents_and_permissions(self):
        with patch.object(package_ipa.subprocess, "run", side_effect=self.run_with_fake_codesign):
            first = package_ipa.package_ipa(self.app, self.output, self.bundle_id)
            self.assert_no_staging()
            self.executable.write_bytes(b"test executable\x00replacement")
            second = package_ipa.package_ipa(self.app, self.output, self.bundle_id)

        self.assert_no_staging()
        self.assertEqual(len(self.codesign_commands), 4)
        self.assertEqual(Path(self.codesign_commands[-1][-1]).parents[1].name, "extracted")
        self.assertNotEqual(first["sha256"], second["sha256"])
        self.assertEqual(second, {
            "ipa": str(self.output),
            "bundleIdentifier": self.bundle_id,
            "version": "1.2.3",
            "build": "42",
            "bytes": self.output.stat().st_size,
            "sha256": hashlib.sha256(self.output.read_bytes()).hexdigest(),
            "zipVerified": True,
        })
        with zipfile.ZipFile(self.output) as archive:
            prefix = f"Payload/{self.app.name}/"
            self.assertIsNone(archive.testzip())
            self.assertEqual(plistlib.loads(archive.read(prefix + "Info.plist")), self.info)
            self.assertEqual(archive.read(prefix + self.executable.name), self.executable.read_bytes())
            self.assertEqual(archive.getinfo(prefix + self.executable.name).external_attr >> 16 & 0o777, 0o755)
            self.assertEqual(archive.read(prefix + "embedded.mobileprovision"), b"test provisioning profile")
        self.assertEqual(self.executable.stat().st_mode & 0o777, 0o755)

    def test_corrupt_zip_preserves_old_ipa_and_cleans_staging(self):
        self.output.parent.mkdir(parents=True)
        self.output.write_bytes(b"previous IPA")

        def corrupt_archive(command, *args, **kwargs):
            result = self.run_with_fake_codesign(command, *args, **kwargs)
            if command[:2] == ["ditto", "-c"]:
                Path(command[-1]).write_bytes(b"broken ZIP")
            return result

        with patch.object(package_ipa.subprocess, "run", side_effect=corrupt_archive):
            with self.assertRaises(zipfile.BadZipFile):
                package_ipa.package_ipa(self.app, self.output, self.bundle_id)

        self.assertEqual(self.output.read_bytes(), b"previous IPA")
        self.assert_no_staging()

    def test_appledouble_zip_is_rejected_before_replacing_old_ipa(self):
        self.output.parent.mkdir(parents=True)
        self.output.write_bytes(b"previous IPA")

        def add_appledouble(command, *args, **kwargs):
            result = self.run_with_fake_codesign(command, *args, **kwargs)
            if command[:2] == ["ditto", "-c"]:
                with zipfile.ZipFile(command[-1], "a") as archive:
                    archive.writestr(f"Payload/{self.app.name}/._Info.plist", b"AppleDouble")
            return result

        with patch.object(package_ipa.subprocess, "run", side_effect=add_appledouble):
            with self.assertRaisesRegex(ValueError, "AppleDouble"):
                package_ipa.package_ipa(self.app, self.output, self.bundle_id)
        self.assertEqual(self.output.read_bytes(), b"previous IPA")
        self.assert_no_staging()

    def test_final_archive_signature_failure_preserves_old_ipa(self):
        self.output.parent.mkdir(parents=True)
        self.output.write_bytes(b"previous IPA")

        def reject_extracted_signature(command, *args, **kwargs):
            result = self.run_with_fake_codesign(command, *args, **kwargs)
            if command[0] == "codesign" and Path(command[-1]).parents[1].name == "extracted":
                raise subprocess.CalledProcessError(1, command)
            return result

        with patch.object(package_ipa.subprocess, "run", side_effect=reject_extracted_signature):
            with self.assertRaises(subprocess.CalledProcessError):
                package_ipa.package_ipa(self.app, self.output, self.bundle_id)
        self.assertEqual(self.output.read_bytes(), b"previous IPA")
        self.assert_no_staging()

    @unittest.skipUnless(sys.platform == "darwin", "Requires macOS code signing")
    def test_signed_app_with_extended_attributes_survives_plain_zip_extraction(self):
        # This is a host-only signature fixture; its executable is never run.
        shutil.copyfile("/usr/bin/true", self.executable)
        self.executable.chmod(0o755)
        subprocess.run(["codesign", "--force", "--sign", "-", str(self.app)],
                       check=True, capture_output=True)
        resource = self.app / "embedded.mobileprovision"
        attribute = "com.example.package-ipa"
        subprocess.run(["xattr", "-w", attribute, "metadata", str(resource)], check=True)
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(self.app)],
                       check=True, capture_output=True)

        # Reproduce the previous packager: valid source, invalid delivered ZIP contents.
        payload = self.root / "unsafe/Payload"
        payload.mkdir(parents=True)
        subprocess.run(["ditto", str(self.app), str(payload / self.app.name)], check=True)
        unsafe_ipa = self.root / "unsafe.ipa"
        subprocess.run(["ditto", "-c", "-k", "--keepParent", str(payload), str(unsafe_ipa)], check=True)
        extracted = self.root / "unsafe-extracted"
        with zipfile.ZipFile(unsafe_ipa) as archive:
            self.assertTrue(any(Path(name).name.startswith("._") for name in archive.namelist()))
            archive.extractall(extracted)
            for member in archive.infolist():
                (extracted / member.filename).chmod((member.external_attr >> 16) & 0o777)
        invalid = subprocess.run(["codesign", "--verify", "--deep", "--strict",
                                  str(extracted / "Payload" / self.app.name)], capture_output=True)
        self.assertNotEqual(invalid.returncode, 0)

        package_ipa.package_ipa(self.app, self.output, self.bundle_id)
        with zipfile.ZipFile(self.output) as archive:
            self.assertFalse(any(Path(name).name.startswith("._") for name in archive.namelist()))
        self.assertEqual(subprocess.run(["xattr", "-p", attribute, str(resource)],
                                        check=True, capture_output=True).stdout.strip(), b"metadata")
        self.assert_no_staging()

    def test_bundle_identity_mismatch_is_rejected_before_packaging(self):
        with patch.object(package_ipa.subprocess, "run") as run:
            with self.assertRaisesRegex(ValueError, "Expected .*production"):
                package_ipa.package_ipa(self.app, self.output, "example.production")
        run.assert_not_called()
        self.assertFalse(self.output.parent.parent.exists())

    def test_missing_provisioning_profile_is_rejected(self):
        (self.app / "embedded.mobileprovision").unlink()
        with patch.object(package_ipa.subprocess, "run") as run:
            with self.assertRaisesRegex(ValueError, "no provisioning profile"):
                package_ipa.package_ipa(self.app, self.output, self.bundle_id)
        run.assert_not_called()
        self.assertFalse(self.output.parent.parent.exists())

    def test_codesign_failure_preserves_old_ipa(self):
        self.output.parent.mkdir(parents=True)
        self.output.write_bytes(b"previous IPA")

        def reject_signature(command, *args, **kwargs):
            result = self.run_with_fake_codesign(command, *args, **kwargs)
            if command[0] == "codesign":
                raise subprocess.CalledProcessError(1, command)
            return result

        with patch.object(package_ipa.subprocess, "run", side_effect=reject_signature):
            with self.assertRaises(subprocess.CalledProcessError):
                package_ipa.package_ipa(self.app, self.output, self.bundle_id)
        self.assertEqual(self.output.read_bytes(), b"previous IPA")
        self.assert_no_staging()

    def test_missing_version_metadata_preserves_old_ipa_and_cleans_staging(self):
        self.output.parent.mkdir(parents=True)
        for key in ("CFBundleShortVersionString", "CFBundleVersion"):
            with self.subTest(missing=key):
                info = dict(self.info)
                del info[key]
                (self.app / "Info.plist").write_bytes(plistlib.dumps(info))
                self.output.write_bytes(b"previous IPA")
                with patch.object(package_ipa.subprocess, "run", side_effect=self.run_with_fake_codesign):
                    with self.assertRaises(KeyError):
                        package_ipa.package_ipa(self.app, self.output, self.bundle_id)
                self.assertEqual(self.output.read_bytes(), b"previous IPA")
                self.assert_no_staging()


class BuildDeviceRoutingTests(unittest.TestCase):
    def test_variant_and_signing_flags_without_building(self):
        with tempfile.TemporaryDirectory(prefix="build-device-routing-") as directory:
            work = Path(directory)
            log = work / "commands.jsonl"
            stub = (
                f"#!{sys.executable}\n"
                "import json, os, sys\n"
                'with open(os.environ["COMMAND_LOG"], "a") as log:\n'
                '    log.write(json.dumps([os.path.basename(sys.argv[0]), *sys.argv[1:]]) + "\\n")\n'
            )
            for command in ("python3", "xcodebuild"):
                executable = work / command
                executable.write_text(stub)
                executable.chmod(0o755)
            environment = dict(os.environ, PATH=f"{work}:{os.environ['PATH']}", COMMAND_LOG=str(log))
            script = Path(package_ipa.__file__).with_name("build_device.sh")
            for arguments, variant, signed in [
                ([], "development", False),
                (["production"], "production", False),
                (["--signed"], "development", True),
                (["production", "--signed"], "production", True),
            ]:
                with self.subTest(arguments=arguments):
                    log.write_text("")
                    subprocess.run(["bash", str(script), *arguments], env=environment, check=True)
                    commands = [json.loads(line) for line in log.read_text().splitlines()]
                    configuration, _ = package_ipa.VARIANTS[variant]
                    scheme = "VoiceContextAgentDev" if variant == "development" else "VoiceContextAgent"
                    signing = ["-allowProvisioningUpdates", "CODE_SIGN_STYLE=Automatic", "CODE_SIGNING_ALLOWED=YES"] if signed else ["CODE_SIGNING_ALLOWED=NO"]
                    self.assertEqual(commands, [
                        ["python3", "tools/integration/generate_project.py"],
                        ["xcodebuild", "-workspace", "VoiceContextAgent.xcworkspace", "-scheme", scheme,
                         "-configuration", configuration, "-destination", "generic/platform=iOS",
                         "-derivedDataPath", "build/VoiceContextAgent",
                         "-clonedSourcePackagesDirPath", "build/PhonePackages",
                         "-disableAutomaticPackageResolution", *signing, "build"],
                        ["python3", "tools/integration/verify_fusion.py", "--variant", variant,
                         "--products", f"build/VoiceContextAgent/Build/Products/{configuration}-iphoneos"],
                    ])


if __name__ == "__main__":
    unittest.main()
