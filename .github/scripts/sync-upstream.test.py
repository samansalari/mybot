"""Unit tests for sync-upstream.sh in disposable git repositories."""

import os
import pathlib
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).with_name("sync-upstream.sh").resolve()


def run_git(cwd, *args):
    return subprocess.check_output(["git", *args], cwd=cwd, text=True, stderr=subprocess.DEVNULL)


class SyncUpstreamTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp_dir.name)

        # Create upstream bare repo
        self.upstream_dir = self.root / "upstream.git"
        subprocess.check_call(["git", "init", "--bare", "-q", "-b", "main", str(self.upstream_dir)])

        # Create origin bare repo
        self.origin_dir = self.root / "origin.git"
        subprocess.check_call(["git", "init", "--bare", "-q", "-b", "main", str(self.origin_dir)])

        # Create working repo to seed initial commit
        seed_dir = self.root / "seed"
        seed_dir.mkdir()
        run_git(seed_dir, "init", "-q", "-b", "main")
        run_git(seed_dir, "config", "user.name", "Test")
        run_git(seed_dir, "config", "user.email", "test@example.com")
        run_git(seed_dir, "config", "commit.gpgsign", "false")
        (seed_dir / "README.md").write_text("# Initial\n")
        run_git(seed_dir, "add", "README.md")
        run_git(seed_dir, "commit", "-qm", "Initial commit")
        run_git(seed_dir, "remote", "add", "upstream", str(self.upstream_dir))
        run_git(seed_dir, "remote", "add", "origin", str(self.origin_dir))
        run_git(seed_dir, "push", "upstream", "main")
        run_git(seed_dir, "push", "origin", "main")

        # Create test workspace cloned from origin
        self.work_dir = self.root / "workspace"
        subprocess.check_call(["git", "clone", "-q", str(self.origin_dir), str(self.work_dir)])
        run_git(self.work_dir, "config", "user.name", "Test Runner")
        run_git(self.work_dir, "config", "user.email", "runner@example.com")
        run_git(self.work_dir, "config", "commit.gpgsign", "false")

    def tearDown(self):
        self.temp_dir.cleanup()

    def run_sync(self):
        env = os.environ.copy()
        output_file = self.root / "output.txt"
        env["GITHUB_OUTPUT"] = str(output_file)
        env["UPSTREAM_REPO"] = str(self.upstream_dir)
        env["UPSTREAM_BRANCH"] = "main"
        env["TARGET_BRANCH"] = "main"
        env["INTEGRATION_BRANCH"] = "sync/upstream-integration"
        # Mock gh command not present or disabled in tests
        env["GH_TOKEN"] = ""

        proc = subprocess.run(
            ["bash", str(SCRIPT)],
            cwd=self.work_dir,
            env=env,
            capture_output=True,
            text=True,
        )

        outputs = {}
        if output_file.exists():
            for line in output_file.read_text().splitlines():
                if "=" in line:
                    k, v = line.split("=", 1)
                    outputs[k] = v

        return proc, outputs

    def test_identical_repositories(self):
        proc, outputs = self.run_sync()
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(outputs.get("sync_status"), "identical")

    def test_local_ahead_of_upstream(self):
        # Add custom commit to local/origin
        (self.work_dir / "local-feature.txt").write_text("my feature")
        run_git(self.work_dir, "add", "local-feature.txt")
        run_git(self.work_dir, "commit", "-qm", "Local custom commit")
        run_git(self.work_dir, "push", "origin", "main")

        proc, outputs = self.run_sync()
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(outputs.get("sync_status"), "ahead")

    def test_fast_forward_upstream(self):
        # Add new commit to upstream
        upstream_clone = self.root / "upstream_work"
        subprocess.check_call(["git", "clone", "-q", str(self.upstream_dir), str(upstream_clone)])
        run_git(upstream_clone, "config", "user.name", "Upstream Dev")
        run_git(upstream_clone, "config", "user.email", "dev@example.com")
        run_git(upstream_clone, "config", "commit.gpgsign", "false")
        (upstream_clone / "upstream_file.txt").write_text("upstream changes")
        run_git(upstream_clone, "add", "upstream_file.txt")
        run_git(upstream_clone, "commit", "-qm", "Upstream commit")
        run_git(upstream_clone, "push", "origin", "main")

        proc, outputs = self.run_sync()
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(outputs.get("sync_status"), "fast-forward")

        # Verify origin received the upstream commit
        origin_log = run_git(self.work_dir, "log", "--oneline", "origin/main")
        self.assertIn("Upstream commit", origin_log)

    def test_diverged_clean_merge(self):
        # 1. Add upstream commit affecting file_a
        upstream_clone = self.root / "upstream_work"
        subprocess.check_call(["git", "clone", "-q", str(self.upstream_dir), str(upstream_clone)])
        run_git(upstream_clone, "config", "user.name", "Upstream Dev")
        run_git(upstream_clone, "config", "user.email", "dev@example.com")
        run_git(upstream_clone, "config", "commit.gpgsign", "false")
        (upstream_clone / "file_a.txt").write_text("upstream content")
        run_git(upstream_clone, "add", "file_a.txt")
        run_git(upstream_clone, "commit", "-qm", "Upstream change")
        run_git(upstream_clone, "push", "origin", "main")

        # 2. Add local commit affecting file_b (no overlap)
        (self.work_dir / "file_b.txt").write_text("local content")
        run_git(self.work_dir, "add", "file_b.txt")
        run_git(self.work_dir, "commit", "-qm", "Local change")
        run_git(self.work_dir, "push", "origin", "main")

        proc, outputs = self.run_sync()
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(outputs.get("sync_status"), "diverged")
        self.assertEqual(outputs.get("has_conflicts"), "false")
        self.assertEqual(outputs.get("need_validation"), "true")

    def test_diverged_with_conflicts(self):
        # 1. Upstream modifies README.md
        upstream_clone = self.root / "upstream_work"
        subprocess.check_call(["git", "clone", "-q", str(self.upstream_dir), str(upstream_clone)])
        run_git(upstream_clone, "config", "user.name", "Upstream Dev")
        run_git(upstream_clone, "config", "user.email", "dev@example.com")
        run_git(upstream_clone, "config", "commit.gpgsign", "false")
        (upstream_clone / "README.md").write_text("# Upstream Title\n")
        run_git(upstream_clone, "add", "README.md")
        run_git(upstream_clone, "commit", "-qm", "Upstream edits README")
        run_git(upstream_clone, "push", "origin", "main")

        # 2. Local modifies README.md differently
        (self.work_dir / "README.md").write_text("# Local Title\n")
        run_git(self.work_dir, "add", "README.md")
        run_git(self.work_dir, "commit", "-qm", "Local edits README")
        run_git(self.work_dir, "push", "origin", "main")

        proc, outputs = self.run_sync()
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(outputs.get("sync_status"), "diverged")
        self.assertEqual(outputs.get("has_conflicts"), "true")
        self.assertEqual(outputs.get("need_validation"), "false")


if __name__ == "__main__":
    unittest.main()
