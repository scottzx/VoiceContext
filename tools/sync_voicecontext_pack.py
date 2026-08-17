#!/usr/bin/env python3
from __future__ import annotations
from pathlib import Path
import shutil
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "tools" / "VoiceContext"
APP = ROOT / "speech_note" / "speech_note"
ZIP_PATH = APP / "VoiceContextPack.zip"
STAGE = APP / ".VoiceContextPack.staging"
SUPPORT = ROOT / "speech_note" / "Supporting" / "VoiceContextPack"


def main() -> None:
    if STAGE.exists():
        shutil.rmtree(STAGE)
    (STAGE / "Skill").mkdir(parents=True)
    (STAGE / "Templates").mkdir(parents=True)
    subprocess.check_call(
        [
            "rsync",
            "-a",
            "--delete",
            "--exclude",
            "__pycache__",
            "--exclude",
            "*.pyc",
            "--exclude",
            ".DS_Store",
            "--exclude",
            "fixtures",
            f"{SRC}/Skill/",
            f"{STAGE}/Skill/",
        ]
    )
    subprocess.check_call(
        [
            "rsync",
            "-a",
            "--delete",
            "--exclude",
            ".DS_Store",
            f"{SRC}/Templates/",
            f"{STAGE}/Templates/",
        ]
    )
    if ZIP_PATH.exists():
        ZIP_PATH.unlink()
    with zipfile.ZipFile(ZIP_PATH, "w", compression=zipfile.ZIP_STORED) as zf:
        for path in sorted(STAGE.rglob("*")):
            if path.is_file():
                zf.write(path, path.relative_to(STAGE).as_posix())
    shutil.rmtree(STAGE)
    if SUPPORT.exists():
        shutil.rmtree(SUPPORT)
    SUPPORT.mkdir(parents=True)
    with zipfile.ZipFile(ZIP_PATH) as zf:
        zf.extractall(SUPPORT)
    loose = APP / "VoiceContextPack"
    if loose.exists():
        shutil.rmtree(loose)
    print(f"Wrote {ZIP_PATH} ({ZIP_PATH.stat().st_size} bytes)")
    print(f"Staged {SUPPORT}")


if __name__ == "__main__":
    main()
