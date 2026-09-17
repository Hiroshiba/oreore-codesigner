#!/usr/bin/env python3
"""workflow用の安全境界をfixtureで検証します。"""

from __future__ import annotations

import json
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent
EXTRACTOR = ROOT / "safe-extract.py"
RELEASE_STATE = ROOT / "read-release-state.sh"


def create_archive(path: Path, members: list[tarfile.TarInfo], contents: dict[str, bytes]) -> None:
    with tarfile.open(path, "w") as archive:
        for member in members:
            data = contents.get(member.name)
            if data is not None:
                member.size = len(data)
                from io import BytesIO

                archive.addfile(member, BytesIO(data))
            else:
                archive.addfile(member)


def run_extract(archive: Path, output: Path, platform: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            str(EXTRACTOR),
            "--archive",
            str(archive),
            "--output",
            str(output),
            "--platform",
            platform,
        ],
        check=False,
        capture_output=True,
        text=True,
    )


class WorkflowFixtureTest(unittest.TestCase):
    def test_mac_relative_symlink_is_preserved(self) -> None:
        with tempfile.TemporaryDirectory(prefix="workflow-fixture-") as directory:
            root = Path(directory)
            archive = root / "safe.tar"
            output = root / "output"
            app = tarfile.TarInfo("app")
            app.type = tarfile.DIRTYPE
            app.mode = 0o755
            target = tarfile.TarInfo("app/target")
            target.mode = 0o640
            link = tarfile.TarInfo("app/link")
            link.type = tarfile.SYMTYPE
            link.linkname = "target"
            create_archive(archive, [app, target, link], {"app/target": b"ok"})
            result = run_extract(archive, output, "macos")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((output / "app/target").read_bytes(), b"ok")
            self.assertTrue((output / "app/link").is_symlink())
            self.assertEqual((output / "app/link").readlink(), Path("target"))
            self.assertEqual((output / "app/target").stat().st_mode & 0o777, 0o640)

    def test_escape_symlink_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="workflow-fixture-") as directory:
            root = Path(directory)
            archive = root / "escape.tar"
            output = root / "output"
            app = tarfile.TarInfo("app")
            app.type = tarfile.DIRTYPE
            link = tarfile.TarInfo("app/link")
            link.type = tarfile.SYMTYPE
            link.linkname = "../../outside"
            create_archive(archive, [app, link], {})
            result = run_extract(archive, output, "macos")
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())

    def test_mac_symlink_graph_rejects_root_cycle_and_intermediate_escape(self) -> None:
        with tempfile.TemporaryDirectory(prefix="workflow-fixture-") as directory:
            root = Path(directory)
            root_link_archive = root / "root-link.tar"
            app = tarfile.TarInfo("My.app")
            app.type = tarfile.DIRTYPE
            root_link = tarfile.TarInfo("My.app/foo")
            root_link.type = tarfile.SYMTYPE
            root_link.linkname = ".."
            create_archive(root_link_archive, [app, root_link], {})
            result = run_extract(root_link_archive, root / "root-link-output", "macos")
            self.assertNotEqual(result.returncode, 0)

            intermediate_archive = root / "intermediate.tar"
            app = tarfile.TarInfo("My.app")
            app.type = tarfile.DIRTYPE
            intermediate = tarfile.TarInfo("My.app/link")
            intermediate.type = tarfile.SYMTYPE
            intermediate.linkname = "foo/../signing.keychain-db"
            create_archive(intermediate_archive, [app, intermediate], {})
            result = run_extract(intermediate_archive, root / "intermediate-output", "macos")
            self.assertNotEqual(result.returncode, 0)

            cycle_archive = root / "cycle.tar"
            app = tarfile.TarInfo("My.app")
            app.type = tarfile.DIRTYPE
            first = tarfile.TarInfo("My.app/first")
            first.type = tarfile.SYMTYPE
            first.linkname = "second"
            second = tarfile.TarInfo("My.app/second")
            second.type = tarfile.SYMTYPE
            second.linkname = "first"
            create_archive(cycle_archive, [app, first, second], {})
            result = run_extract(cycle_archive, root / "cycle-output", "macos")
            self.assertNotEqual(result.returncode, 0)

    def test_mac_electron_framework_relative_symlinks_are_allowed(self) -> None:
        with tempfile.TemporaryDirectory(prefix="workflow-fixture-") as directory:
            root = Path(directory)
            archive = root / "framework.tar"
            directories: list[tarfile.TarInfo] = []
            for name in (
                "My.app",
                "My.app/Contents",
                "My.app/Contents/Frameworks",
                "My.app/Contents/Frameworks/Electron Framework.framework",
                "My.app/Contents/Frameworks/Electron Framework.framework/Versions",
                "My.app/Contents/Frameworks/Electron Framework.framework/Versions/A",
            ):
                member = tarfile.TarInfo(name)
                member.type = tarfile.DIRTYPE
                member.mode = 0o755
                directories.append(member)
            current = tarfile.TarInfo(
                "My.app/Contents/Frameworks/Electron Framework.framework/Versions/Current"
            )
            current.type = tarfile.SYMTYPE
            current.linkname = "A"
            framework = tarfile.TarInfo(
                "My.app/Contents/Frameworks/Electron Framework.framework/Electron Framework"
            )
            framework.type = tarfile.SYMTYPE
            framework.linkname = "Versions/Current/Electron Framework"
            binary = tarfile.TarInfo(
                "My.app/Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework"
            )
            create_archive(archive, [*directories, binary, current, framework], {binary.name: b"framework"})
            output = root / "output"
            result = run_extract(archive, output, "macos")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((output / framework.name).read_bytes(), b"framework")

    def test_hardlink_fifo_and_path_traversal_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="workflow-fixture-") as directory:
            root = Path(directory)
            cases: list[tuple[str, tarfile.TarInfo]] = []
            hardlink = tarfile.TarInfo("hardlink")
            hardlink.type = tarfile.LNKTYPE
            hardlink.linkname = "target"
            cases.append(("hardlink", hardlink))
            fifo = tarfile.TarInfo("fifo")
            fifo.type = tarfile.FIFOTYPE
            cases.append(("fifo", fifo))
            traversal = tarfile.TarInfo("../escape")
            cases.append(("traversal", traversal))
            for name, member in cases:
                archive = root / f"{name}.tar"
                output = root / f"{name}-output"
                create_archive(archive, [member], {})
                result = run_extract(archive, output, "linux")
                self.assertNotEqual(result.returncode, 0, name)
                self.assertFalse(output.exists(), name)

    def test_windows_symlink_and_normalized_duplicate_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="workflow-fixture-") as directory:
            root = Path(directory)
            symlink_archive = root / "windows-link.tar"
            link = tarfile.TarInfo("link")
            link.type = tarfile.SYMTYPE
            link.linkname = "target"
            create_archive(symlink_archive, [link], {})
            result = run_extract(symlink_archive, root / "windows-link-output", "windows")
            self.assertNotEqual(result.returncode, 0)

            duplicate_archive = root / "duplicate.tar"
            first = tarfile.TarInfo("./same")
            second = tarfile.TarInfo("same")
            create_archive(duplicate_archive, [first, second], {"./same": b"a", "same": b"b"})
            result = run_extract(duplicate_archive, root / "duplicate-output", "linux")
            self.assertNotEqual(result.returncode, 0)

    def test_special_modes_and_platform_paths_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="workflow-fixture-") as directory:
            root = Path(directory)
            setuid_archive = root / "setuid.tar"
            setuid_member = tarfile.TarInfo("setuid")
            setuid_member.mode = 0o4755
            create_archive(setuid_archive, [setuid_member], {"setuid": b"x"})
            result = run_extract(setuid_archive, root / "setuid-output", "linux")
            self.assertNotEqual(result.returncode, 0)

            backslash_archive = root / "backslash.tar"
            backslash_member = tarfile.TarInfo("dir\\file")
            create_archive(backslash_archive, [backslash_member], {"dir\\file": b"x"})
            result = run_extract(backslash_archive, root / "backslash-output", "windows")
            self.assertNotEqual(result.returncode, 0)

    def test_release_false_booleans_are_valid(self) -> None:
        with tempfile.TemporaryDirectory(prefix="workflow-fixture-") as directory:
            release = Path(directory) / "release.json"
            release.write_text(
                json.dumps({"draft": False, "prerelease": False, "immutable": False}),
                encoding="utf-8",
            )
            result = subprocess.run(
                [str(RELEASE_STATE), str(release)],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                json.loads(result.stdout),
                {"draft": "false", "prerelease": "false", "immutable": "false"},
            )

    def test_release_immutable_missing_or_null_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="workflow-fixture-") as directory:
            for index, value in enumerate((
                {"draft": False, "prerelease": False},
                {"draft": False, "prerelease": False, "immutable": None},
            )):
                release = Path(directory) / f"release-{index}.json"
                release.write_text(json.dumps(value), encoding="utf-8")
                result = subprocess.run(
                    [str(RELEASE_STATE), str(release)],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
