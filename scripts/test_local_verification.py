#!/usr/bin/env python3
"""Shell-level tests for conservative quick-check receipt reuse."""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


class LocalVerificationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.repository = Path(self.temporary.name) / "repository"
        self.repository.mkdir()
        shutil.copytree(ROOT / "scripts", self.repository / "scripts",
                        ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
        # Python creates bytecode on a clean runner. It must not turn the clean
        # receipt fixture dirty or depend on the developer's global Git ignores.
        (self.repository / ".gitignore").write_text("__pycache__/\n*.pyc\n.build/\n", encoding="utf-8")
        shutil.copytree(ROOT / "config", self.repository / "config")
        (self.repository / ".githooks").mkdir()
        shutil.copy2(ROOT / ".githooks" / "pre-push", self.repository / ".githooks" / "pre-push")
        self.fake_bin = Path(self.temporary.name) / "bin"
        self.fake_bin.mkdir()
        self.log = Path(self.temporary.name) / "xcodebuild.log"
        self.write_fake_tools()
        self.git("init", "-q")
        self.git("config", "user.email", "test@example.com")
        self.git("config", "user.name", "Test")
        (self.repository / "Sources").mkdir()
        (self.repository / "Sources" / "fixture.swift").write_text("fixture\n", encoding="utf-8")
        self.commit("baseline")
        self.base = self.git("rev-parse", "HEAD").stdout.strip()
        release_notes = self.repository / "docs" / "releases"
        release_notes.mkdir(parents=True)
        (release_notes / "v9.9.9.md").write_text("fixture\n", encoding="utf-8")
        self.commit("release bookkeeping")
        self.head = self.git("rev-parse", "HEAD").stdout.strip()
        self.record_successful_receipt()

    def tearDown(self):
        self.temporary.cleanup()

    def git(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(["git", "-C", str(self.repository), *arguments], check=True, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def commit(self, message: str) -> None:
        self.git("add", ".")
        self.git("commit", "-qm", message)

    def write_fake_tools(self) -> None:
        # These tests exercise receipt reuse, not Xcode project generation or isolation.
        # Keep that boundary synthetic so a clean checkout needs no generated project
        # and never invokes the host's absolute /usr/bin/xcodebuild through the real gate.
        isolation = self.repository / "scripts" / "verify-test-isolation.sh"
        isolation.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        xcodebuild = self.fake_bin / "xcodebuild"
        xcodebuild.write_text(
            "#!/bin/sh\n"
            "case \" $* \" in\n"
            "  *' -version '*) printf 'Xcode 26.6\\nBuild version fixture\\n' ;;\n"
            "  *' WindowRangerCLI '*) printf '    SKIP_INSTALL = YES\\n' ;;\n"
            "  *' test '*) printf 'test\\n' >> \"$FAKE_XCODE_LOG\" ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        xcodegen = self.fake_bin / "xcodegen"
        xcodegen.write_text("#!/bin/sh\nprintf 'Version: fixture\\n'\n", encoding="utf-8")
        os.chmod(xcodebuild, 0o755)
        os.chmod(xcodegen, 0o755)

    def environment(self) -> dict[str, str]:
        environment = os.environ.copy()
        environment["PATH"] = f"{self.fake_bin}:{environment['PATH']}"
        environment["FAKE_XCODE_LOG"] = str(self.log)
        return environment

    def record_successful_receipt(self) -> None:
        common = self.git("rev-parse", "--git-common-dir").stdout.strip()
        common_directory = Path(common)
        if not common_directory.is_absolute():
            common_directory = self.repository / common_directory
        receipt = common_directory / "windowranger-quick-verification.json"
        self.receipt = receipt
        result = subprocess.run(
            ["python3", "scripts/verification-scope.py", "--repository-root", str(self.repository),
             "record-success", "--commit", self.head, "--receipt", str(receipt),
             "--verification-status", "passed"],
            cwd=self.repository,
            env=self.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def run_quick(self, head: str) -> subprocess.CompletedProcess[str]:
        self.log.unlink(missing_ok=True)
        return subprocess.run(
            ["zsh", "scripts/verify-local-ci.sh", "--quick", "--base", self.base, "--head", head],
            cwd=self.repository,
            env=self.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def test_clean_bookkeeping_reuses_matching_receipt(self):
        result = self.run_quick(self.head)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Reusing the matching successful", result.stdout)
        self.assertFalse(self.log.exists(), "clean receipt reuse must skip xcodebuild test")

    def test_dirty_checkout_never_reuses_or_records_receipt(self):
        (self.repository / "untracked.txt").write_text("dirty\n", encoding="utf-8")
        receipt_mtime = self.receipt.stat().st_mtime_ns
        result = self.run_quick(self.head)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("receipt reuse is disabled", result.stdout)
        self.assertEqual(self.log.read_text(encoding="utf-8"), "test\n")
        self.assertEqual(self.receipt.stat().st_mtime_ns, receipt_mtime)

    def test_mismatched_head_never_reuses_or_records_receipt(self):
        receipt_mtime = self.receipt.stat().st_mtime_ns
        result = self.run_quick(self.base)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("receipt reuse is disabled", result.stdout)
        self.assertEqual(self.log.read_text(encoding="utf-8"), "test\n")
        self.assertEqual(self.receipt.stat().st_mtime_ns, receipt_mtime)


if __name__ == "__main__":
    unittest.main(verbosity=2)
