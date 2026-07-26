#!/usr/bin/env python3
"""Побайтовая подготовка и атомарная активация текстовых конфигураций."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import sys


PRIVATE_CREATE_MODE = 0o600
CANDIDATE_MODE = 0o644


class AtomicConfigError(RuntimeError):
    """Нарушение контракта атомарной конфигурации."""


def normalize_terminal_lf(payload: bytes) -> bytes:
    """Нормализовать переносы и оставить ровно один завершающий LF."""

    if not payload:
        raise AtomicConfigError("configuration payload is empty")
    normalized = payload.replace(b"\r\n", b"\n").replace(b"\r", b"\n")
    normalized = normalized.rstrip(b"\n")
    if not normalized:
        raise AtomicConfigError("configuration payload contains no data")
    if normalized.endswith(b"\\n"):
        raise AtomicConfigError("configuration has a literal backslash-n suffix")
    normalized.decode("utf-8", errors="strict")
    return normalized + b"\n"


def inspect_payload(payload: bytes) -> dict[str, object]:
    """Проверить byte-level контракт и вернуть только безопасные метаданные."""

    if not payload.endswith(b"\n") or payload.endswith(b"\n\n"):
        raise AtomicConfigError("configuration must end with exactly one LF")
    body = payload[:-1]
    if body.endswith(b"\\n"):
        raise AtomicConfigError("configuration has a literal backslash-n suffix")
    if b"\r" in payload:
        raise AtomicConfigError("configuration contains CR bytes")
    payload.decode("utf-8", errors="strict")
    return {
        "sha256": hashlib.sha256(payload).hexdigest(),
        "size": len(payload),
    }


def _fsync_directory(path: Path) -> None:
    if os.name == "nt":
        return
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def inspect_regular_file(
    path: Path,
    expected_mode: int,
) -> dict[str, object]:
    """Проверить обычный файл, точный режим и byte-level контракт."""

    file_stat = path.lstat()
    if not stat.S_ISREG(file_stat.st_mode):
        raise AtomicConfigError("configuration path is not a regular file")
    actual_mode = stat.S_IMODE(file_stat.st_mode)
    if actual_mode != expected_mode:
        raise AtomicConfigError(
            f"configuration mode is {actual_mode:04o}, expected {expected_mode:04o}"
        )
    return inspect_payload(path.read_bytes())


def prepare_candidate(path: Path, payload: bytes) -> dict[str, object]:
    """Закрыто записать candidate и открыть готовый файл для HAProxy."""

    normalized = normalize_terminal_lf(payload)
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(
        path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL,
        PRIVATE_CREATE_MODE,
    )
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(normalized)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(path, CANDIDATE_MODE)
        _fsync_directory(path.parent)
    except BaseException:
        path.unlink(missing_ok=True)
        raise
    return inspect_regular_file(path, CANDIDATE_MODE)


def activate_candidate(
    candidate: Path,
    target: Path,
    expected_sha256: str,
    mode: int = 0o644,
) -> dict[str, object]:
    """Проверить candidate и атомарно заменить production target."""

    if candidate.parent.resolve() != target.parent.resolve():
        raise AtomicConfigError("candidate and target must share a directory")
    metadata = inspect_regular_file(candidate, CANDIDATE_MODE)
    if metadata["sha256"] != expected_sha256:
        raise AtomicConfigError("candidate checksum differs from accepted contract")
    os.replace(candidate, target)
    os.chmod(target, mode)
    with target.open("rb") as handle:
        os.fsync(handle.fileno())
    _fsync_directory(target.parent)
    accepted = inspect_regular_file(target, mode)
    if accepted != metadata:
        raise AtomicConfigError("activated target differs from candidate")
    return accepted


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="action", required=True)
    prepare = subparsers.add_parser("prepare")
    prepare.add_argument("--candidate", type=Path, required=True)
    activate = subparsers.add_parser("activate")
    activate.add_argument("--candidate", type=Path, required=True)
    activate.add_argument("--target", type=Path, required=True)
    activate.add_argument("--expected-sha256", required=True)
    activate.add_argument("--mode", default="0644")
    inspect = subparsers.add_parser("inspect")
    inspect.add_argument("--path", type=Path, required=True)
    return parser


def main() -> int:
    args = _parser().parse_args()
    try:
        if args.action == "prepare":
            result = prepare_candidate(args.candidate, sys.stdin.buffer.read())
        elif args.action == "activate":
            result = activate_candidate(
                args.candidate,
                args.target,
                args.expected_sha256,
                int(args.mode, 8),
            )
        else:
            result = inspect_payload(args.path.read_bytes())
    except (AtomicConfigError, OSError, UnicodeError, ValueError) as exc:
        print(f"atomic config error: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
