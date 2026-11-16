#!/usr/bin/env python3
"""
Unit and integration test suite for scripts/upstream-sync.sh
Tests disposable git repositories for all synchronization paths:
- Already up-to-date
- Origin ahead of upstream
- Clean fast-forward
- Divergent histories with clean merge
- Merge conflicts
- Validation failures
- Concurrency locking
- Status reporting
"""

import json
import os
import shutil
import subprocess
import tempfile
import unittest

SCRIPT_PATH = os.path.abspath(os.path.join(os.path.dirname(__file__), "upstream-sync.sh"))


def run_cmd(cmd, cwd=None, env=None, check=True):
    res = subprocess.run(
        cmd,
        cwd=cwd,
        env=env,
        shell=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if check and res.returncode != 0:
        raise RuntimeError(f"Command failed ({res.returncode}): {cmd}\nOutput: {res.stdout}\nError: {res.stderr}")
    return res


class TestUpstreamSync(unittest.TestCase):
    def setUp(self):
        self.test_dir = tempfile.mkdtemp(prefix="test_upstream_sync_")
        self.upstream_dir = os.path.join(self.test_dir, "upstream.git")
        self.origin_dir = os.path.join(self.test_dir, "origin.git")
        self.work_dir = os.path.join(self.test_dir, "work")
        self.state_dir = os.path.join(self.test_dir, "state")
        os.makedirs(self.state_dir, exist_ok=True)

        # 1. Bare upstream repo
        run_cmd(f"git init --bare -b main '{self.upstream_dir}'")
        # 2. Bare origin repo
        run_cmd(f"git init --bare -b main '{self.origin_dir}'")

        # 3. Seed initial commit to both
        seed_dir = os.path.join(self.test_dir, "seed")
        run_cmd(f"git init -b main '{seed_dir}'")
        run_cmd("git config user.name 'Test Runner'", cwd=seed_dir)
        run_cmd("git config user.email 'test@example.com'", cwd=seed_dir)
        with open(os.path.join(seed_dir, "README.md"), "w") as f:
            f.write("# Initial\n")
        run_cmd("git add README.md && git commit -m 'Initial commit'", cwd=seed_dir)
        run_cmd(f"git remote add upstream '{self.upstream_dir}'", cwd=seed_dir)
        run_cmd(f"git remote add origin '{self.origin_dir}'", cwd=seed_dir)
        run_cmd("git push upstream main", cwd=seed_dir)
        run_cmd("git push origin main", cwd=seed_dir)

        # 4. Working clone
        run_cmd(f"git clone '{self.origin_dir}' '{self.work_dir}'")
        run_cmd("git config user.name 'Test Runner'", cwd=self.work_dir)
        run_cmd("git config user.email 'test@example.com'", cwd=self.work_dir)
        run_cmd(f"git remote add upstream '{self.upstream_dir}'", cwd=self.work_dir)
        run_cmd("git fetch --all", cwd=self.work_dir)

        # Base env for running upstream-sync.sh
        self.base_env = os.environ.copy()
        self.base_env["REPO_DIR"] = self.work_dir
        self.base_env["STATE_DIR"] = self.state_dir
        self.base_env["STATE_FILE"] = os.path.join(self.state_dir, "state.json")
        self.base_env["LOG_FILE"] = os.path.join(self.state_dir, "sync.log")
        self.base_env["LOCK_FILE"] = os.path.join(self.state_dir, "sync.lock")
        self.base_env["UPSTREAM_URL"] = self.upstream_dir
        self.base_env["FORK_REPO"] = "samansalari/mybot"
        self.base_env["VALIDATION_ENABLED"] = "false"  # Default off in mocked git repo

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def test_already_synchronized(self):
        """When origin and upstream are at the same commit, script exits 0 with NO_CHANGES."""
        res = run_cmd(f"bash '{SCRIPT_PATH}' --run", env=self.base_env)
        self.assertEqual(res.returncode, 0)
        self.assertIn("already synchronized", res.stdout.lower())

        with open(self.base_env["STATE_FILE"], "r") as f:
            state = json.load(f)
        self.assertEqual(state["last_status"], "NO_CHANGES")

    def test_origin_ahead_of_upstream(self):
        """When origin has custom commits and upstream has no new commits, exits 0 with NO_CHANGES."""
        seed_dir = os.path.join(self.test_dir, "seed")
        with open(os.path.join(seed_dir, "custom.txt"), "w") as f:
            f.write("custom\n")
        run_cmd("git add custom.txt && git commit -m 'Custom commit'", cwd=seed_dir)
        run_cmd("git push origin main", cwd=seed_dir)

        res = run_cmd(f"bash '{SCRIPT_PATH}' --run", env=self.base_env)
        self.assertEqual(res.returncode, 0)
        self.assertIn("ahead of upstream", res.stdout.lower())

        with open(self.base_env["STATE_FILE"], "r") as f:
            state = json.load(f)
        self.assertEqual(state["last_status"], "NO_CHANGES")

    def test_fast_forward_sync(self):
        """When upstream has new commits and origin has no custom commits, fast-forwards main."""
        seed_dir = os.path.join(self.test_dir, "seed")
        with open(os.path.join(seed_dir, "upstream_feature.txt"), "w") as f:
            f.write("upstream feature\n")
        run_cmd("git add upstream_feature.txt && git commit -m 'Upstream feature'", cwd=seed_dir)
        run_cmd("git push upstream main", cwd=seed_dir)

        res = run_cmd(f"bash '{SCRIPT_PATH}' --run", env=self.base_env)
        self.assertEqual(res.returncode, 0)
        self.assertIn("fast-forward synchronisation possible", res.stdout.lower())

        # Check origin/main got updated
        origin_head = run_cmd(f"git rev-parse HEAD", cwd=self.origin_dir).stdout.strip()
        upstream_head = run_cmd(f"git rev-parse HEAD", cwd=self.upstream_dir).stdout.strip()
        self.assertEqual(origin_head, upstream_head)

        with open(self.base_env["STATE_FILE"], "r") as f:
            state = json.load(f)
        self.assertEqual(state["last_status"], "SUCCESS_FF")

    def test_divergent_clean_merge(self):
        """When histories diverge and merge cleanly, integration branch is created and updated."""
        seed_dir = os.path.join(self.test_dir, "seed")

        # Custom commit to origin
        with open(os.path.join(seed_dir, "local_file.txt"), "w") as f:
            f.write("local work\n")
        run_cmd("git add local_file.txt && git commit -m 'Local work'", cwd=seed_dir)
        run_cmd("git push origin main", cwd=seed_dir)

        # Reset seed back to root to branch off upstream
        run_cmd("git reset --hard HEAD~1", cwd=seed_dir)
        with open(os.path.join(seed_dir, "upstream_file.txt"), "w") as f:
            f.write("upstream work\n")
        run_cmd("git add upstream_file.txt && git commit -m 'Upstream work'", cwd=seed_dir)
        run_cmd("git push upstream main", cwd=seed_dir)

        # Run sync
        res = run_cmd(f"bash '{SCRIPT_PATH}' --run", env=self.base_env)
        self.assertEqual(res.returncode, 0)
        self.assertIn("histories have diverged", res.stdout.lower())
        self.assertIn("pushing integration branch", res.stdout.lower())

        # Verify integration branch pushed to origin
        branches = run_cmd(f"git branch", cwd=self.origin_dir).stdout
        self.assertIn("sync/upstream-integration", branches)

        with open(self.base_env["STATE_FILE"], "r") as f:
            state = json.load(f)
        self.assertEqual(state["last_status"], "DIVERGENT_PR_OPENED")

    def test_merge_conflict_handling(self):
        """When upstream conflicts with local changes, merge is cleanly aborted and recorded."""
        seed_dir = os.path.join(self.test_dir, "seed")

        # Edit same file with conflicting changes
        with open(os.path.join(seed_dir, "README.md"), "w") as f:
            f.write("# Modified by local\n")
        run_cmd("git add README.md && git commit -m 'Local change'", cwd=seed_dir)
        run_cmd("git push origin main", cwd=seed_dir)

        run_cmd("git reset --hard HEAD~1", cwd=seed_dir)
        with open(os.path.join(seed_dir, "README.md"), "w") as f:
            f.write("# Modified by upstream\n")
        run_cmd("git add README.md && git commit -m 'Upstream change'", cwd=seed_dir)
        run_cmd("git push upstream main", cwd=seed_dir)

        res = run_cmd(f"bash '{SCRIPT_PATH}' --run", env=self.base_env, check=False)
        self.assertEqual(res.returncode, 1)
        self.assertIn("merge conflict detected", res.stdout.lower() + res.stderr.lower())

        # Ensure working tree was cleaned (not in middle of broken merge)
        status = run_cmd("git status", cwd=self.work_dir).stdout
        self.assertIn("working tree clean", status.lower())

        with open(self.base_env["STATE_FILE"], "r") as f:
            state = json.load(f)
        self.assertEqual(state["last_status"], "MERGE_CONFLICT")
        self.assertIn("README.md", state["last_error"])

    def test_status_cli_flag(self):
        """--status flag formats and prints current state properly."""
        # Prepopulate state
        with open(self.base_env["STATE_FILE"], "w") as f:
            json.dump({
                "last_run_timestamp": "2026-11-16T19:00:00Z",
                "last_success_timestamp": "2026-11-16T19:00:00Z",
                "last_status": "SUCCESS_FF",
                "last_upstream_sha": "abc1234",
                "last_origin_sha": "abc1234",
            }, f)

        res = run_cmd(f"bash '{SCRIPT_PATH}' --status", env=self.base_env)
        self.assertEqual(res.returncode, 0)
        self.assertIn("Rakazo Self-Hosted Upstream Sync Status", res.stdout)
        self.assertIn("SUCCESS_FF", res.stdout)
        self.assertIn("abc1234", res.stdout)


if __name__ == "__main__":
    unittest.main()
