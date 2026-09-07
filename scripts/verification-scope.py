#!/usr/bin/env python3
"""Classify verification work and manage conservative local quick-check receipts.

Only release bookkeeping may avoid recompiling the app, and only when the exact
non-bookkeeping tree has already passed quick verification with this toolchain.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path


BOOKKEEPING_PATHS = {"TODO.md", "config/release-builds.tsv"}
BOOKKEEPING_PREFIX = "docs/releases/"


def run_git(repository: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(repository), *arguments],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )


def is_bookkeeping_path(path: str) -> bool:
    return path in BOOKKEEPING_PATHS or (path.startswith(BOOKKEEPING_PREFIX) and path.endswith(".md"))


def verification_scope(repository: Path, base: str, head: str) -> str:
    """Return bookkeeping only for additive/modifying allowlisted release records.

    A missing base, a deletion, rename, type change, or unfamiliar diff is always
    full verification. This intentionally makes the quick path fail closed.
    """
    result = run_git(repository, "diff", "--name-status", "-z", base, head)
    if result.returncode:
        print(f"verification scope: unable to compare {base} to {head}; using full verification", file=sys.stderr)
        return "full"
    entries = [entry for entry in result.stdout.split("\0") if entry]
    if not entries:
        return "full"
    index = 0
    while index < len(entries):
        status = entries[index]
        index += 1
        # Renames/copies contain two paths. Treat them conservatively even if both
        # paths happen to be in the allowlist.
        if status[:1] not in {"A", "M"} or index >= len(entries):
            return "full"
        path = entries[index]
        index += 1
        if not is_bookkeeping_path(path):
            return "full"
    return "bookkeeping"


def command_output(command: list[str]) -> str:
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False)
    if result.returncode:
        raise RuntimeError(f"{' '.join(command)} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def source_fingerprint(repository: Path, commit: str) -> str:
    result = run_git(repository, "ls-tree", "-r", "-z", "--format=%(objectmode) %(objecttype) %(objectname) %(path)", commit)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or f"cannot read tree for {commit}")
    digest = hashlib.sha256()
    for record in result.stdout.split("\0"):
        if not record:
            continue
        try:
            object_mode, object_type, object_id, path = record.split(" ", 3)
        except ValueError as error:
            raise RuntimeError(f"unexpected git tree record for {commit}") from error
        if is_bookkeeping_path(path):
            continue
        digest.update(object_mode.encode())
        digest.update(b"\0")
        digest.update(object_type.encode())
        digest.update(b"\0")
        digest.update(object_id.encode())
        digest.update(b"\0")
        digest.update(path.encode())
        digest.update(b"\0")
    return digest.hexdigest()


def receipt_key(repository: Path, commit: str, xcodebuild: str, xcodegen: str) -> str:
    material = {
        "schema": 1,
        "source_fingerprint": source_fingerprint(repository, commit),
        "xcodebuild": command_output([xcodebuild, "-version"]),
        "xcodegen": command_output([xcodegen, "--version"]),
    }
    return hashlib.sha256(json.dumps(material, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def receipt_is_valid(receipt: Path, key: str) -> bool:
    try:
        payload = json.loads(receipt.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return False
    return payload == {"schema": 1, "key": key}


def record_receipt(receipt: Path, key: str, status: str) -> None:
    if status != "passed":
        raise RuntimeError("only a passed quick verification may create a receipt")
    receipt.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=receipt.parent, delete=False) as temporary:
        json.dump({"schema": 1, "key": key}, temporary, sort_keys=True)
        temporary.write("\n")
        temporary_name = temporary.name
    os.replace(temporary_name, receipt)


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    root.add_argument("--repository-root", type=Path, default=Path.cwd())
    subcommands = root.add_subparsers(dest="command", required=True)
    scope = subcommands.add_parser("scope")
    scope.add_argument("--base", required=True)
    scope.add_argument("--head", required=True)
    for name in ("receipt-key", "receipt-valid", "record-success"):
        command = subcommands.add_parser(name)
        command.add_argument("--commit", required=True)
        command.add_argument("--xcodebuild", default="xcodebuild")
        command.add_argument("--xcodegen", default="xcodegen")
    valid = subcommands.choices["receipt-valid"]
    valid.add_argument("--receipt", type=Path, required=True)
    record = subcommands.choices["record-success"]
    record.add_argument("--receipt", type=Path, required=True)
    record.add_argument("--verification-status", required=True)
    return root


def main(arguments: list[str] | None = None) -> int:
    options = parser().parse_args(arguments)
    repository = options.repository_root.resolve()
    if options.command == "scope":
        print(verification_scope(repository, options.base, options.head))
        return 0
    try:
        key = receipt_key(repository, options.commit, options.xcodebuild, options.xcodegen)
        if options.command == "receipt-key":
            print(key)
            return 0
        if options.command == "receipt-valid":
            return 0 if receipt_is_valid(options.receipt, key) else 1
        record_receipt(options.receipt, key, options.verification_status)
        return 0
    except RuntimeError as error:
        print(f"verification scope: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
