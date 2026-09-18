#!/usr/bin/env python3
"""検査済みのtar archiveだけを安全に展開します。"""

from __future__ import annotations

import argparse
import os
import re
import stat
import sys
import tarfile
from dataclasses import dataclass
from pathlib import Path


class ExtractionError(Exception):
    """安全でないarchiveを検出しました。"""


@dataclass(frozen=True)
class ArchiveEntry:
    member: tarfile.TarInfo
    name: str
    parts: tuple[str, ...]
    link_name: str | None


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="検査済みtar archiveを展開します")
    parser.add_argument("--archive", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--platform", choices=("linux", "macos", "windows"), required=True)
    return parser.parse_args()


def normalize_member_name(name: str, platform: str) -> tuple[str, tuple[str, ...]]:
    if not name or "\x00" in name or "\n" in name or "\r" in name:
        raise ExtractionError(f"archive pathが不正です: {name!r}")
    if (
        "\\" in name
        or name.startswith("/")
        or re.match(r"^[A-Za-z]:", name)
        or (platform == "windows" and ":" in name)
    ):
        raise ExtractionError(f"archive pathが不正です: {name!r}")
    parts: list[str] = []
    for part in name.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            raise ExtractionError(f"archive pathにparent traversalがあります: {name!r}")
        if platform == "windows":
            trimmed = part.rstrip(" .")
            device_name = trimmed.split(".", 1)[0].rstrip(" .").casefold()
            if device_name in {"con", "prn", "aux", "nul"} or re.fullmatch(r"(?:com|lpt)[1-9]", device_name):
                raise ExtractionError(f"Windows予約device名をarchive pathに使用できません: {name!r}")
        parts.append(part)
    normalized = "/".join(parts) if parts else "."
    return normalized, tuple(parts)


def normalize_link_target(parent: tuple[str, ...], target: str) -> str:
    if not target or "\x00" in target or "\n" in target or "\r" in target:
        raise ExtractionError(f"symlink targetが不正です: {target!r}")
    if "\\" in target or target.startswith("/") or re.match(r"^[A-Za-z]:", target):
        raise ExtractionError(f"symlink targetが不正です: {target!r}")
    parts = list(parent)
    target_has_forward_component = False
    for part in target.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            if target_has_forward_component:
                raise ExtractionError(f"symlink targetの中間pathを解決できません: {target!r}")
            if not parts:
                raise ExtractionError(f"symlink targetがarchive外です: {target!r}")
            parts.pop()
            continue
        parts.append(part)
        target_has_forward_component = True
    if not parts:
        raise ExtractionError(f"symlink targetが展開rootそのものです: {target!r}")
    return "/".join(parts)


def assert_safe_mode(member: tarfile.TarInfo) -> None:
    if member.mode & (stat.S_ISUID | stat.S_ISGID):
        raise ExtractionError(f"setuidまたはsetgidのarchive memberは許可されません: {member.name!r}")


def inspect_members(archive: tarfile.TarFile, platform: str) -> list[ArchiveEntry]:
    entries: list[ArchiveEntry] = []
    normalized: dict[str, ArchiveEntry] = {}
    for member in archive.getmembers():
        name, parts = normalize_member_name(member.name, platform)
        key = name.casefold() if platform in ("macos", "windows") else name
        if key in normalized:
            raise ExtractionError(f"normalized pathが重複しています: {member.name!r}")
        assert_safe_mode(member)
        if member.islnk() or member.isfifo() or member.isdev():
            raise ExtractionError(f"危険なarchive member typeです: {member.name!r}")
        if member.isdir():
            link_name = None
        elif member.isreg():
            if member.size < 0:
                raise ExtractionError(f"regular fileのsizeが不正です: {member.name!r}")
            link_name = None
        elif member.issym():
            if platform != "macos":
                raise ExtractionError(f"このplatformではsymlinkを許可しません: {member.name!r}")
            link_name = normalize_link_target(parts[:-1], member.linkname)
        else:
            raise ExtractionError(f"未対応のarchive member typeです: {member.name!r}")
        entry = ArchiveEntry(member, name, parts, link_name)
        entries.append(entry)
        normalized[key] = entry

    for entry in entries:
        for index in range(1, len(entry.parts)):
            parent = "/".join(entry.parts[:index])
            key = parent.casefold() if platform in ("macos", "windows") else parent
            parent_entry = normalized.get(key)
            if parent_entry is not None and not parent_entry.member.isdir():
                raise ExtractionError(f"archive memberのparentがdirectoryではありません: {entry.name!r}")
    return entries


def assert_no_symlink_parent(path: Path, output: Path) -> None:
    current = path.parent
    output_resolved = output.absolute()
    while True:
        if current == output_resolved:
            return
        try:
            information = current.lstat()
        except FileNotFoundError:
            current = current.parent
            continue
        if stat.S_ISLNK(information.st_mode) or not stat.S_ISDIR(information.st_mode):
            raise ExtractionError(f"展開先のparentが安全なdirectoryではありません: {current}")
        if current.parent == current:
            return
        current = current.parent


def ensure_directory(path: Path, output: Path, mode: int) -> None:
    assert_no_symlink_parent(path, output)
    try:
        information = path.lstat()
    except FileNotFoundError:
        ensure_parent_directories(path, output)
        path.mkdir(mode=0o755)
        return
    if stat.S_ISLNK(information.st_mode) or not stat.S_ISDIR(information.st_mode):
        raise ExtractionError(f"展開先のpathがdirectoryではありません: {path}")


def ensure_parent_directories(path: Path, output: Path) -> None:
    relative = path.relative_to(output)
    current = output
    for part in relative.parts[:-1]:
        current = current / part
        try:
            information = current.lstat()
        except FileNotFoundError:
            current.mkdir(mode=0o755)
            continue
        if stat.S_ISLNK(information.st_mode) or not stat.S_ISDIR(information.st_mode):
            raise ExtractionError(f"regular fileのparentが安全ではありません: {current}")


def write_regular_file(archive: tarfile.TarFile, entry: ArchiveEntry, output: Path) -> None:
    assert_no_symlink_parent(output, output.parent)
    ensure_parent_directories(output, output.parent)
    if os.path.lexists(output):
        raise ExtractionError(f"展開先pathが既に存在します: {entry.name!r}")
    source = archive.extractfile(entry.member)
    if source is None:
        raise ExtractionError(f"regular fileを読み込めません: {entry.name!r}")
    try:
        with source, output.open("xb") as destination:
            while True:
                chunk = source.read(1024 * 1024)
                if not chunk:
                    break
                destination.write(chunk)
        os.chmod(output, stat.S_IMODE(entry.member.mode))
    except OSError as error:
        raise ExtractionError(f"regular fileの展開に失敗しました: {entry.name!r}") from error


def create_symlink(entry: ArchiveEntry, output: Path) -> None:
    assert_no_symlink_parent(output, output.parent)
    ensure_parent_directories(output, output.parent)
    if os.path.lexists(output):
        raise ExtractionError(f"symlinkの展開先pathが既に存在します: {entry.name!r}")
    try:
        os.symlink(entry.member.linkname, output)
    except OSError as error:
        raise ExtractionError(f"symlinkの展開に失敗しました: {entry.name!r}") from error


def validate_symlink_graph(output: Path, symlinks: list[ArchiveEntry]) -> None:
    """展開後のsymlinkが存在するroot内の実体を指すことを検証します。"""
    root = Path(os.path.realpath(output))
    for entry in symlinks:
        link_path = output.joinpath(*entry.parts)
        try:
            link_path.resolve(strict=True)
            resolved = Path(os.path.realpath(link_path))
        except (FileNotFoundError, OSError, RuntimeError) as error:
            raise ExtractionError(f"symlink graphを安全に解決できません: {entry.name!r}") from error
        try:
            resolved.relative_to(root)
        except ValueError as error:
            raise ExtractionError(f"symlink targetが展開root外です: {entry.name!r}") from error
        if resolved == root:
            raise ExtractionError(f"symlink targetが展開rootそのものです: {entry.name!r}")


def extract(archive_path: Path, output_path: Path, platform: str) -> None:
    if sys.version_info < (3, 9):
        raise ExtractionError("Python 3.9以上が必要です")
    archive_path = archive_path.absolute()
    output_path = output_path.absolute()
    if not archive_path.is_file() or archive_path.is_symlink():
        raise ExtractionError("archiveが通常fileではありません")
    if os.path.lexists(output_path):
        raise ExtractionError("archiveの展開先は存在してはいけません")
    assert_no_symlink_parent(output_path, output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        with tarfile.open(archive_path, mode="r:*") as archive:
            entries = inspect_members(archive, platform)
            output_path.mkdir(mode=0o755)
            directories = [entry for entry in entries if entry.member.isdir()]
            regular_files = [entry for entry in entries if entry.member.isreg()]
            symlinks = [entry for entry in entries if entry.member.issym()]
            for entry in sorted(directories, key=lambda value: len(value.parts)):
                if entry.name == ".":
                    continue
                ensure_directory(output_path.joinpath(*entry.parts), output_path, entry.member.mode)
            for entry in regular_files:
                write_regular_file(archive, entry, output_path.joinpath(*entry.parts))
            for entry in symlinks:
                create_symlink(entry, output_path.joinpath(*entry.parts))
            for entry in sorted(directories, key=lambda value: len(value.parts), reverse=True):
                target = output_path if entry.name == "." else output_path.joinpath(*entry.parts)
                os.chmod(target, stat.S_IMODE(entry.member.mode))
            validate_symlink_graph(output_path, symlinks)
    except (tarfile.TarError, OSError) as error:
        raise ExtractionError("archiveの展開に失敗しました") from error


def main() -> int:
    arguments = parse_arguments()
    try:
        extract(Path(arguments.archive), Path(arguments.output), arguments.platform)
    except ExtractionError as error:
        print(f"{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
