#!/usr/bin/env python3
"""workflow用の安全境界をfixtureで検証します。"""

from __future__ import annotations

import json
import http.server
import os
import socketserver
import subprocess
import sys
import tarfile
import tempfile
import unittest
from shutil import which
from pathlib import Path


ROOT = Path(__file__).resolve().parent
EXTRACTOR = ROOT / "safe-extract.py"
RELEASE_STATE = ROOT / "read-release-state.sh"
EXTRACT_CERTIFICATE_CN = ROOT / "extract-certificate-cn.sh"
PUBLISH_SCRIPT = ROOT / "publish-release.sh"


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

    def test_windows_reserved_device_components_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="workflow-fixture-") as directory:
            root = Path(directory)
            names = ("CON.txt", "prn.", "Aux ", "NUL.log", "CoM1", "lpt9.foo", "CON .txt")
            for index, name in enumerate(names):
                archive = root / f"reserved-{index}.tar"
                member = tarfile.TarInfo(f"payload/{name}")
                create_archive(archive, [member], {member.name: b"x"})
                result = run_extract(archive, root / f"reserved-{index}-output", "windows")
                self.assertNotEqual(result.returncode, 0, name)

    def test_certificate_cn_allows_developer_id_subject_attributes(self) -> None:
        if which("openssl") is None:
            self.skipTest("opensslがありません")
        with tempfile.TemporaryDirectory(prefix="workflow-fixture-") as directory:
            root = Path(directory)
            certificate = root / "developer-id.pem"
            key = root / "developer-id.key"
            result = subprocess.run(
                [
                    "openssl",
                    "req",
                    "-x509",
                    "-newkey",
                    "rsa:2048",
                    "-nodes",
                    "-keyout",
                    str(key),
                    "-out",
                    str(certificate),
                    "-days",
                    "1",
                    "-subj",
                    "/C=US/O=Apple Inc./OU=ABCDE12345/CN=Developer ID Application: Fixture",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run(
                [str(EXTRACT_CERTIFICATE_CN), str(certificate)],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "Developer ID Application: Fixture")

    def test_publish_direct_200_download_fixture_keeps_body_separate(self) -> None:
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self) -> None:
                body = b"direct release asset\n"
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, _format: str, *_args: object) -> None:
                return

        try:
            server = socketserver.TCPServer(("127.0.0.1", 0), Handler)
        except PermissionError:
            self.skipTest("test環境でlocalhost listenerを作成できません")
        with server:
            port = server.server_address[1]
            with tempfile.TemporaryDirectory(prefix="workflow-fixture-") as directory:
                root = Path(directory)
                header = root / "headers"
                body = root / "body"
                process = subprocess.Popen(
                    [
                        "curl",
                        "--silent",
                        "--show-error",
                        "--dump-header",
                        str(header),
                        "--output",
                        str(body),
                        f"http://127.0.0.1:{port}/asset",
                    ],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    env={"PATH": os.environ.get("PATH", ""), "NO_PROXY": "127.0.0.1"},
                )
                server.handle_request()
                stdout, stderr = process.communicate(timeout=5)
                self.assertEqual(process.returncode, 0, stderr)
                self.assertEqual(stdout, "")
                self.assertEqual(body.read_bytes(), b"direct release asset\n")
                self.assertIn(b"--output \"$api_body_path\"", PUBLISH_SCRIPT.read_bytes())
                self.assertIn(b'if [[ "$HTTP_STATUS" == 200 ]]', PUBLISH_SCRIPT.read_bytes())

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
