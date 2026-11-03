#!/usr/bin/env python3
"""Behavioral regression tests for the CI-only streaming capture wrapper."""
import os
import random
import signal
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

CAPTURE = Path(__file__).resolve().with_name("ci_capture.py")
ZIG_CAPTURE = os.environ.get("COREX_CAPTURE_BIN")
WRAPPER = [str(Path(ZIG_CAPTURE).resolve(strict=True))] if ZIG_CAPTURE else [sys.executable, str(CAPTURE)]
TAIL_BYTES = 16 * 1024


def env_for(actions=False):
    env = os.environ.copy()
    env["GITHUB_ACTIONS"] = "true" if actions else "false"
    env["PYTHONIOENCODING"] = "utf-8"
    env.pop("COREX_CI_CAPTURE_TIMEOUT_MS", None)
    return env


def command(code):
    return [*WRAPPER, sys.executable, "-c", code]


class CaptureTests(unittest.TestCase):
    def run_capture(self, args, actions=False, env=None, cwd=None):
        return subprocess.run(
            [*WRAPPER, *args],
            capture_output=True, env=env if env is not None else env_for(actions),
            cwd=cwd, timeout=20,
        )

    def test_missing_command_and_launch_failure(self):
        result = self.run_capture([])
        self.assertEqual(result.returncode, 2)
        self.assertIn(b"usage:", result.stderr)
        with tempfile.TemporaryDirectory(prefix="ci captura ") as temporary:
            result = self.run_capture([str(Path(temporary) / "missing-command")], True)
        self.assertEqual(result.returncode, 127)
        self.assertIn(b"could not launch CI command", result.stderr)
        self.assertNotIn(b"::error", result.stdout)

    def test_raw_output_and_merged_order(self):
        code = "import os; os.write(1, b'out\\xff'); os.write(2, b'err\\x00'); os.write(1, b'end')"
        for actions in (False, True):
            with self.subTest(actions=actions):
                result = self.run_capture([sys.executable, "-c", code], actions)
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b"out\xfferr\x00end")
                self.assertEqual(result.stderr, b"")

    def test_exit_code_without_github_annotation(self):
        result = self.run_capture([sys.executable, "-c", "import sys; print('failed'); sys.exit(7)"])
        self.assertEqual(result.returncode, 7)
        self.assertEqual(result.stdout, b"failed\n")
        self.assertNotIn(b"::error", result.stdout)

    def test_annotation_is_on_its_own_line_with_bounded_escaped_tail(self):
        code = "import os, sys; os.write(1, b'PREFIX:' + b'x' * 16382 + b'\\xff%\\r\\n?'); sys.exit(7)"
        payload = b"PREFIX:" + b"x" * 16382 + b"\xff%\r\n?"
        tail = payload[-TAIL_BYTES:].decode("utf-8", errors="replace")
        escaped = tail.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        annotation = ("::error title=CI command failed::exit 7: " + escaped + "\n").encode()
        result = self.run_capture([sys.executable, "-c", code], True)
        self.assertEqual(result.returncode, 7)
        self.assertEqual(result.stdout, payload + b"\n" + annotation)
        self.assertEqual(result.stderr, b"")

    def test_utf8_sequence_split_by_tail_boundary_is_replaced(self):
        code = "import os, sys; os.write(1, b'\\xe2\\x82\\xac' + b'x' * 16383); sys.exit(4)"
        payload = b"\xe2\x82\xac" + b"x" * 16383
        tail = payload[-TAIL_BYTES:].decode("utf-8", errors="replace")
        result = self.run_capture([sys.executable, "-c", code], True)
        self.assertEqual(result.returncode, 4)
        expected = ("::error title=CI command failed::exit 4: " + tail + "\n").encode()
        self.assertEqual(result.stdout, payload + b"\n" + expected)

    def test_annotation_matches_utf8_replacement_for_deterministic_bytes(self):
        rng = random.Random(7315)
        samples = [b"\xe0\x80\x80", b"\xf0\x9f\x92", b"\xf4\x90\x80\x80", b"\xed\xa0\x80"]
        samples += [rng.randbytes(160) for _ in range(24)]
        for payload in samples:
            with self.subTest(payload=payload.hex()):
                code = f"import os, sys; os.write(1, bytes.fromhex('{payload.hex()}')); sys.exit(9)"
                tail = payload.decode("utf-8", errors="replace")
                escaped = tail.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
                prefix = payload + (b"\n" if payload and not payload.endswith(b"\n") else b"")
                expected = prefix + ("::error title=CI command failed::exit 9: " + escaped + "\n").encode()
                result = self.run_capture([sys.executable, "-c", code], True)
                self.assertEqual(result.returncode, 9)
                self.assertEqual(result.stdout, expected)

    @unittest.skipUnless(sys.platform.startswith("linux"), "Linux PATH executable")
    def test_path_lookup_cwd_and_arguments_without_shell(self):
        with tempfile.TemporaryDirectory(prefix="ci comando ação ") as temporary:
            root = Path(temporary)
            executable = root / "corex-test-command"
            executable.write_text(f"#!{sys.executable}\nimport json, os, sys\nprint(json.dumps([os.getcwd(), *sys.argv[1:]], ensure_ascii=False))\n", encoding="utf-8")
            executable.chmod(0o700)
            env = env_for()
            env["PATH"] = str(root) + os.pathsep + env.get("PATH", "")
            result = self.run_capture([executable.name, "two words", "ação", "$(not a shell)"], env=env, cwd=root)
            self.assertEqual(result.returncode, 0, result.stderr)
            import json
            self.assertEqual(json.loads(result.stdout), [str(root), "two words", "ação", "$(not a shell)"])

    def test_worst_case_annotation_expansion(self):
        code = "import os, sys; os.write(1, b'%' * 16384); sys.exit(2)"
        result = self.run_capture([sys.executable, "-c", code], True)
        self.assertEqual(result.returncode, 2)
        expected = b"%" * TAIL_BYTES + b"\n::error title=CI command failed::exit 2: " + b"%25" * TAIL_BYTES + b"\n"
        self.assertEqual(result.stdout, expected)

    def test_actions_flag_is_case_sensitive(self):
        for value in (None, "True", "1", ""):
            with self.subTest(value=value):
                env = env_for()
                if value is None:
                    env.pop("GITHUB_ACTIONS", None)
                else:
                    env["GITHUB_ACTIONS"] = value
                result = self.run_capture([sys.executable, "-c", "import sys; print('fail'); sys.exit(3)"], env=env)
                self.assertEqual(result.returncode, 3)
                self.assertEqual(result.stdout, b"fail\n")

    def test_annotation_at_line_boundary_for_empty_and_newline_output(self):
        for payload in (b"", b"already\n", b"carriage\r"):
            with self.subTest(payload=payload):
                code = f"import os, sys; os.write(1, {payload!r}); sys.exit(3)"
                result = self.run_capture([sys.executable, "-c", code], True)
                escaped = payload.decode().replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
                prefix = payload + (b"\n" if payload and not payload.endswith(b"\n") else b"")
                self.assertEqual(result.returncode, 3)
                self.assertEqual(result.stdout, prefix + f"::error title=CI command failed::exit 3: {escaped}\n".encode())

    @unittest.skipUnless(os.name == "posix", "POSIX signal termination semantics")
    def test_signal_termination_is_nonzero(self):
        result = self.run_capture([sys.executable, "-c", "import os, signal; os.kill(os.getpid(), signal.SIGTERM)"], True)
        self.assertEqual(result.returncode, 128 + signal.SIGTERM)
        self.assertIn(f"::error title=CI command failed::exit {-int(signal.SIGTERM)}: ".encode(), result.stdout)

    def test_large_combined_output_remains_complete_with_bounded_tail(self):
        pattern = (b"A" * 1024 + b"B" * 1024) * 1024
        code = "import os\nfor _ in range(1024):\n os.write(1, b'A' * 1024)\n os.write(2, b'B' * 1024)\nraise SystemExit(3)"
        result = self.run_capture([sys.executable, "-c", code], True)
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertEqual(result.stdout, pattern + b"\n::error title=CI command failed::exit 3: " + pattern[-TAIL_BYTES:] + b"\n")

    def run_group(self, code, env, *args):
        process = subprocess.Popen([*command(code), *args], stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, env=env, start_new_session=True)
        try:
            stdout, stderr = process.communicate(timeout=8)
            return process.returncode, stdout, stderr
        finally:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            if process.poll() is None:
                process.communicate(timeout=5)

    @unittest.skipUnless(sys.platform.startswith("linux") and ZIG_CAPTURE, "Linux Zig prototype only")
    def test_timeout_invalid_values_fail_before_spawn(self):
        with tempfile.TemporaryDirectory(prefix="ci prazo ") as temporary:
            marker = Path(temporary) / "started"
            code = f"from pathlib import Path; Path({str(marker)!r}).touch()"
            for value in ("", "0", "-1", "+1", " 1", "86400001", "999999999999"):
                with self.subTest(value=value):
                    env = env_for()
                    env["COREX_CI_CAPTURE_TIMEOUT_MS"] = value
                    result = self.run_capture([sys.executable, "-c", code], env=env)
                    self.assertEqual(result.returncode, 1)
                    self.assertIn(b"InvalidTimeout", result.stderr)
                    self.assertFalse(marker.exists())

    @unittest.skipUnless(sys.platform.startswith("linux") and ZIG_CAPTURE, "Linux Zig prototype only")
    def test_timeout_terminates_and_reaps_silent_and_early_closed_pipe(self):
        for close_pipe in (False, True):
            with self.subTest(close_pipe=close_pipe), tempfile.TemporaryDirectory(prefix="ci prazo ") as temporary:
                pidfile = Path(temporary) / "pid"
                close = "os.close(1); os.close(2); " if close_pipe else "os.write(1, b'started%'); "
                code = ("import os, pathlib, signal, sys, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                        "pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); " + close + "time.sleep(30)")
                env = env_for(True)
                env["COREX_CI_CAPTURE_TIMEOUT_MS"] = "1200"
                status, stdout, stderr = self.run_group(code, env, str(pidfile))
                self.assertEqual(status, 124, stderr)
                self.assertIn(b"timed out after 1200 ms", stderr)
                self.assertIn(b"::error title=CI command failed::exit 124:", stdout)
                if not close_pipe:
                    self.assertTrue(stdout.startswith(b"started%\n"))
                    self.assertIn(b"started%25", stdout)
                with self.assertRaises(ProcessLookupError):
                    os.kill(int(pidfile.read_text()), 0)

    @unittest.skipUnless(sys.platform.startswith("linux") and ZIG_CAPTURE, "Linux Zig prototype only")
    def test_timeout_when_descendant_keeps_pipe_open(self):
        code = ("import subprocess, sys; "
                "subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)']); "
                "print('parent exited', flush=True)")
        env = env_for(True)
        env["COREX_CI_CAPTURE_TIMEOUT_MS"] = "1200"
        status, stdout, stderr = self.run_group(code, env)
        self.assertEqual(status, 124, stderr)
        self.assertIn(b"parent exited\n", stdout)
        self.assertIn(b"::error title=CI command failed::exit 124:", stdout)

    @unittest.skipUnless(sys.platform.startswith("linux") and ZIG_CAPTURE, "Linux Zig prototype only")
    def test_timeout_allows_fast_exit_and_stops_continuous_output(self):
        env = env_for(True)
        env["COREX_CI_CAPTURE_TIMEOUT_MS"] = "1200"
        result = self.run_capture([sys.executable, "-c", "print('ok')"], env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"ok\n")
        # EOF can precede process exit; this exercises the timed wait path.
        result = self.run_capture([sys.executable, "-c", "import os, time; os.close(1); os.close(2); time.sleep(0.1)"], env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"")
        result = self.run_capture([sys.executable, "-c", "raise SystemExit(124)"], env=env)
        self.assertEqual(result.returncode, 124)
        self.assertNotIn(b"timed out", result.stderr)
        code = "import os, time\nwhile True:\n os.write(1, b'x' * 4096)\n time.sleep(0.01)"
        status, stdout, stderr = self.run_group(code, env)
        self.assertEqual(status, 124, (stderr, stdout[-1024:]))
        self.assertGreater(len(stdout), TAIL_BYTES)
        self.assertTrue(stdout.endswith(b"x" * TAIL_BYTES + b"\n"))
        self.assertIn(b"::error title=CI command failed::exit 124:", stdout)

    @unittest.skipUnless(sys.platform.startswith("linux") and ZIG_CAPTURE, "Linux Zig prototype only")
    def test_timeout_with_blocked_stdout_reaps_child(self):
        with tempfile.TemporaryDirectory(prefix="ci stdout bloqueado ") as temporary:
            pidfile = Path(temporary) / "pid"
            code = ("import os, pathlib, signal, sys; "
                    "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                    "pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); "
                    "exec(\"while True:\\n os.write(1, b'x' * 4096)\")")
            env = env_for(True)
            env["COREX_CI_CAPTURE_TIMEOUT_MS"] = "1200"
            process = subprocess.Popen([*command(code), str(pidfile)], stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, env=env, start_new_session=True)
            try:
                # Intentionally do not read stdout. Its pipe fills and should
                # not prevent the configured timeout from reaping the child.
                process.wait(timeout=6)
                stdout, stderr = process.communicate(timeout=2)
                self.assertEqual(process.returncode, 124, (stderr, stdout[-1024:]))
                self.assertIn(b"timed out after 1200 ms", stderr)
                self.assertGreater(len(stdout), 0)
                with self.assertRaises(ProcessLookupError):
                    os.kill(int(pidfile.read_text()), 0)
            finally:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                if process.poll() is None:
                    process.communicate(timeout=5)
                process.stdout.close()
                process.stderr.close()

    @unittest.skipUnless(sys.platform.startswith("linux") and ZIG_CAPTURE, "Linux Zig prototype only")
    def test_annotation_deadline_with_blocked_stdout(self):
        import fcntl

        # Keep the child waiting while reducing the outer pipe capacity, so the
        # 4 KiB payload fits but its escaped failure annotation cannot fit.
        code = "import os, sys; os.read(0, 1); os.write(1, b'%' * 4000); sys.exit(7)"
        env = env_for(True)
        env["COREX_CI_CAPTURE_TIMEOUT_MS"] = "1200"
        process = subprocess.Popen(command(code), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, env=env, start_new_session=True)
        try:
            fcntl.fcntl(process.stdout.fileno(), fcntl.F_SETPIPE_SZ, 4096)
            process.stdin.write(b"x")
            process.stdin.flush()
            # Not consuming stdout should not hang in annotation emission.
            process.wait(timeout=6)
            stdout, stderr = process.communicate(timeout=2)
            self.assertEqual(process.returncode, 124, (stderr, stdout[-1024:]))
            self.assertTrue(stdout.startswith(b"%" * 4000))
            self.assertIn(b"timed out after 1200 ms", stderr)
            self.assertIn(b"could not complete its annotation", stderr)
        finally:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            if process.poll() is None:
                process.communicate(timeout=5)
            process.stdin.close()
            process.stdout.close()
            process.stderr.close()

    @unittest.skipUnless(sys.platform.startswith("linux") and ZIG_CAPTURE, "Linux Zig prototype only")
    def test_stdout_backpressure_recovers_without_losing_bytes(self):
        import time

        code = "import os\nfor _ in range(64):\n os.write(1, b'x' * 4096)"
        env = env_for()
        env["COREX_CI_CAPTURE_TIMEOUT_MS"] = "5000"
        process = subprocess.Popen(command(code), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   env=env, start_new_session=True)
        try:
            time.sleep(0.2)
            stdout, stderr = process.communicate(timeout=7)
            self.assertEqual(process.returncode, 0, stderr)
            self.assertEqual(stdout, b"x" * (64 * 4096))
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate(timeout=5)

    @unittest.skipUnless(sys.platform.startswith("linux") and ZIG_CAPTURE, "Linux Zig prototype only")
    def test_stdout_file_status_flags_are_not_mutated(self):
        import fcntl

        read_fd, write_fd = os.pipe()
        try:
            flags = fcntl.fcntl(write_fd, fcntl.F_GETFL)
            env = env_for()
            env["COREX_CI_CAPTURE_TIMEOUT_MS"] = "5000"
            result = subprocess.run(command("print('ok')"), stdout=write_fd,
                                    stderr=subprocess.PIPE, env=env, timeout=7)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(fcntl.fcntl(write_fd, fcntl.F_GETFL), flags)
            os.close(write_fd)
            write_fd = None
            self.assertEqual(os.read(read_fd, 3), b"ok\n")
        finally:
            os.close(read_fd)
            if write_fd is not None:
                os.close(write_fd)

    @unittest.skipUnless(sys.platform.startswith("linux") and ZIG_CAPTURE, "Linux Zig prototype only")
    def test_closed_standard_output_fails_without_starting_child(self):
        with tempfile.TemporaryDirectory(prefix="ci closed fd ") as temporary:
            marker = Path(temporary) / "started"
            code = f"from pathlib import Path; Path({str(marker)!r}).touch()"
            result = subprocess.run([*WRAPPER, sys.executable, "-c", code],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    env=env_for(), timeout=5, preexec_fn=lambda: os.close(1))
            self.assertEqual(result.returncode, 1)
            self.assertIn(b"StandardStreamClosed", result.stderr)
            self.assertFalse(marker.exists())

    @unittest.skipUnless(sys.platform.startswith("linux"), "Linux subprocess/pipe test")
    def test_output_is_streamed_before_child_exits(self):
        import select

        code = "import os; os.write(1, b'A'); os.read(0, 1); os.write(2, b'B')"
        process = subprocess.Popen(command(code), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, env=env_for(), start_new_session=True)
        try:
            ready, _, _ = select.select([process.stdout], [], [], 5)
            self.assertTrue(ready, "child output was buffered until exit")
            self.assertEqual(os.read(process.stdout.fileno(), 1), b"A")
            self.assertIsNone(process.poll())
            process.stdin.write(b"x")
            process.stdin.flush()
            stdout, stderr = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 0, stderr)
            self.assertEqual(stdout, b"B")
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate(timeout=5)

    @unittest.skipUnless(sys.platform.startswith("linux"), "Linux subprocess/pipe test")
    def test_broken_output_pipe_reaps_immediate_child(self):
        import select

        with tempfile.TemporaryDirectory(prefix="ci captura ") as temporary:
            pidfile = Path(temporary) / "child.pid"
            code = ("import os, pathlib, signal, sys, time; "
                    "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                    "pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); "
                    "os.write(1, b'A'); os.read(0, 1); os.write(1, b'B'); time.sleep(30)")
            process = subprocess.Popen([*command(code), str(pidfile)], stdin=subprocess.PIPE,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       env=env_for(), start_new_session=True)
            try:
                ready, _, _ = select.select([process.stdout], [], [], 5)
                self.assertTrue(ready, "child did not start")
                self.assertEqual(os.read(process.stdout.fileno(), 1), b"A")
                child_pid = int(pidfile.read_text())
                process.stdout.close()
                process.stdin.write(b"x")
                process.stdin.flush()
                process.wait(timeout=5)
                self.assertNotEqual(process.returncode, 0)
                with self.assertRaises(ProcessLookupError):
                    os.kill(child_pid, 0)
            finally:
                # Kill the group even if the wrapper exited but failed to reap
                # its child, so a regression cannot leave a sleeping orphan.
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                if process.poll() is None:
                    process.wait(timeout=5)
                process.stdin.close()
                process.stdout.close()
                process.stderr.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
