#!/usr/bin/env python3
"""Deterministic tests for release-bookkeeping verification classification."""

from __future__ import annotations

import importlib.util
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("verification-scope.py")
SPEC = importlib.util.spec_from_file_location("verification_scope", SCRIPT)
assert SPEC and SPEC.loader
scope = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(scope)


class VerificationScopeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.repository = Path(self.temporary.name) / "repository"
        self.repository.mkdir()
        self.git("init", "-q")
        self.git("config", "user.email", "test@example.com")
        self.git("config", "user.name", "Test")
        self.write("Sources/Window.swift", "baseline\n")
        self.write("TODO.md", "baseline\n")
        self.write("docs/releases/v1.0.0.md", "baseline\n")
        self.write("config/release-builds.tsv", "1\t1.0.0\tpublished\tfixture\n")
        self.commit("baseline")
        self.base = self.git("rev-parse", "HEAD").stdout.strip()

    def tearDown(self):
        self.temporary.cleanup()

    def git(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(["git", "-C", str(self.repository), *arguments], check=True, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def write(self, relative: str, contents: str) -> None:
        path = self.repository / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents, encoding="utf-8")

    def commit(self, message: str) -> str:
        self.git("add", ".")
        self.git("commit", "-qm", message)
        return self.git("rev-parse", "HEAD").stdout.strip()

    def changed_commit(self, path: str, contents: str) -> str:
        self.write(path, contents)
        return self.commit(path)

    def test_release_docs_and_ledger_are_bookkeeping(self):
        head = self.changed_commit("docs/releases/v1.0.1.md", "notes\n")
        self.write("TODO.md", "recorded\n")
        self.write("config/release-builds.tsv", "1\t1.0.0\tpublished\tfixture\n2\t1.0.1\tallocated\tfixture\n")
        head = self.commit("release records")
        self.assertEqual(scope.verification_scope(self.repository, self.base, head), "bookkeeping")

    def test_source_changes_require_full_verification(self):
        head = self.changed_commit("Sources/Window.swift", "changed\n")
        self.assertEqual(scope.verification_scope(self.repository, self.base, head), "full")

    def test_scripts_and_ci_inputs_require_full_verification(self):
        for path in ("scripts/build-distribution.sh", ".github/workflows/ci.yml"):
            with self.subTest(path=path):
                head = self.changed_commit(path, "changed\n")
                self.assertEqual(scope.verification_scope(self.repository, self.base, head), "full")
                self.git("reset", "--hard", self.base)

    def test_deletions_require_full_verification(self):
        (self.repository / "docs/releases/v1.0.0.md").unlink()
        head = self.commit("remove release note")
        self.assertEqual(scope.verification_scope(self.repository, self.base, head), "full")

    def test_unknown_base_requires_full_verification(self):
        self.assertEqual(scope.verification_scope(self.repository, "does-not-exist", self.base), "full")

    def test_receipt_fingerprint_ignores_bookkeeping_but_tracks_source(self):
        base_key = scope.source_fingerprint(self.repository, self.base)
        docs_head = self.changed_commit("docs/releases/v1.0.1.md", "notes\n")
        self.assertEqual(scope.source_fingerprint(self.repository, docs_head), base_key)
        source_head = self.changed_commit("Sources/Window.swift", "changed\n")
        self.assertNotEqual(scope.source_fingerprint(self.repository, source_head), base_key)

    def test_receipt_fingerprint_tracks_git_file_modes(self):
        base_key = scope.source_fingerprint(self.repository, self.base)
        source = self.repository / "Sources/Window.swift"
        os.chmod(source, 0o755)
        mode_head = self.commit("make source executable")
        self.assertNotEqual(scope.source_fingerprint(self.repository, mode_head), base_key)

    def test_failed_verification_never_records_a_receipt(self):
        receipt = self.repository / "receipt.json"
        with self.assertRaisesRegex(RuntimeError, "passed quick verification"):
            scope.record_receipt(receipt, "fixture", "failed")
        self.assertFalse(receipt.exists())

    def test_receipt_cli_records_only_success_and_rejects_toolchain_mismatch(self):
        xcodebuild = self.repository / "xcodebuild"
        xcodegen = self.repository / "xcodegen"
        for tool, version in ((xcodebuild, "Xcode 26.6\nBuild version 17A1\n"), (xcodegen, "Version: 2.44\n")):
            tool.write_text(f"#!/bin/sh\nprintf '{version}'\n", encoding="utf-8")
            os.chmod(tool, 0o755)
        receipt = self.repository / "receipt.json"
        common = ["--repository-root", str(self.repository)]
        toolchain = ["--commit", self.base, "--xcodebuild", str(xcodebuild), "--xcodegen", str(xcodegen)]
        self.assertEqual(scope.main([*common, "record-success", *toolchain, "--receipt", str(receipt), "--verification-status", "passed"]), 0)
        self.assertTrue(receipt.exists())
        self.assertEqual(scope.main([*common, "receipt-valid", *toolchain, "--receipt", str(receipt)]), 0)
        xcodebuild.write_text("#!/bin/sh\nprintf 'Xcode 26.7\\nBuild version 17B1\\n'\n", encoding="utf-8")
        os.chmod(xcodebuild, 0o755)
        self.assertEqual(scope.main([*common, "receipt-valid", *toolchain, "--receipt", str(receipt)]), 1)
        failed_receipt = self.repository / "failed-receipt.json"
        self.assertEqual(scope.main([*common, "record-success", *toolchain, "--receipt", str(failed_receipt), "--verification-status", "failed"]), 2)
        self.assertFalse(failed_receipt.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
