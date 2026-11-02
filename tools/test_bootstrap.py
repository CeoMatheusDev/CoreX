#!/usr/bin/env python3
"""Real executable contracts. Validation subprocess != graphical Play.

Build editor/ and runtime/ first. No extra Python dependencies or shell execution.
Synthetic child probes run only on POSIX and live in temporary test directories.
"""
import argparse
import copy
import datetime
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
SUFFIX = ".exe" if os.name == "nt" else ""
EDITOR = ROOT / "editor/zig-out/bin" / ("CoreXEditor" + SUFFIX)
RUNTIME = ROOT / "runtime/zig-out/bin" / ("CoreXRuntime" + SUFFIX)
STAMP = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$")
PROBE_PREFIX = '''import json, os, sys, time, signal

def emit(seq=1, session="probe", event="probe.event", fields=None, level="info", stream=None):
    record = dict(log_version=1, timestamp="2026-11-01T12:00:00.000Z",
                  level=level, source="runtime", event=event, message="probe",
                  session_id=session, seq=seq, tick=None, fields=fields or {})
    (stream or sys.stdout).write(json.dumps(record) + "\\n")
    (stream or sys.stdout).flush()
'''


class BootstrapContracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="corex-bootstrap-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name) / "Jogo ação"
        self.directory.mkdir()
        self.path = self.directory / "My Game.proj"
        self.base = json.loads((ROOT / "docs/examples/EmptyGame.proj").read_text(encoding="utf-8"))
        self.write(self.base)

    def write(self, value):
        self.path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    def run_app(self, executable, *arguments, expected=0, cwd=None, timeout=20):
        before = (self.path.read_bytes(), self.path.stat().st_mtime_ns)
        result = subprocess.run([str(executable), *map(str, arguments)], cwd=cwd,
                                stdin=subprocess.DEVNULL, capture_output=True,
                                timeout=timeout, check=False)
        self.assertEqual(result.returncode, expected, result.stderr.decode("utf-8", errors="replace"))
        self.assertEqual(before, (self.path.read_bytes(), self.path.stat().st_mtime_ns), "process changed project bytes/mtime")
        records = []
        for stream, output in (("stdout", result.stdout), ("stderr", result.stderr)):
            if output:
                self.assertTrue(output.endswith(b"\n"), "official writer omitted LF")
            for line in output.split(b"\n")[:-1]:
                self.assertLessEqual(len(line) + 1, 65536)
                record = json.loads(line.decode("utf-8"))
                self.assertEqual(record["log_version"], 1)
                self.assertRegex(record["timestamp"], STAMP)
                datetime.datetime.fromisoformat(record["timestamp"].replace("Z", "+00:00"))
                self.assertEqual(stream, "stderr" if record["level"] in ("warn", "error") else "stdout")
                self.assertIsInstance(record["fields"], dict)
                self.assertIsNone(record["tick"])
                self.assertNotEqual(record["event"], "runtime.ready")
                records.append(record)
        self.assertTrue(records, "missing structured diagnostics")
        self.assertEqual(len({r["session_id"] for r in records}), 1)
        self.assertEqual(sorted(r["seq"] for r in records), list(range(1, len(records) + 1)))
        return records

    @staticmethod
    def event(records, name):
        matches = [r for r in records if r["event"] == name]
        if len(matches) != 1:
            raise AssertionError(f"expected one {name}, got {len(matches)}")
        return matches[0]["fields"]

    def validate(self, executable=RUNTIME, *extra, expected=0, **kwargs):
        return self.run_app(executable, "--project", self.path, "--headless", "--validate-only", *extra, expected=expected, **kwargs)

    def check(self, executable, expected=5, **kwargs):
        return self.validate(EDITOR, "--check-runtime", executable, expected=expected, **kwargs)

    def fake(self, body):
        if os.name != "posix" or any(c.isspace() for c in sys.executable):
            self.skipTest("POSIX shebang probes require an interpreter path without whitespace")
        path = self.directory / "Explicit child probe"
        path.write_text(f"#!{sys.executable}\n" + PROBE_PREFIX + body + "\n", encoding="utf-8")
        path.chmod(0o755)
        return path

    def copy_distribution(self):
        prefix = self.directory / "Moved distribution"
        (prefix / "bin").mkdir(parents=True)
        destination = prefix / "bin" / RUNTIME.name
        shutil.copy2(RUNTIME, destination)
        shutil.copytree(RUNTIME.parent.parent / "share", prefix / "share")
        return prefix, destination

    def test_runtime_validation_is_not_game_execution(self):
        records = self.validate()
        complete = self.event(records, "runtime.validation_complete")
        self.assertEqual(complete["scope"], "document_and_presets")
        self.assertFalse(complete["resources_loaded"])
        self.assertFalse(complete["core_linked"])
        self.assertFalse(complete["core_abi_checked"])
        self.assertFalse(self.event(records, "graphics.config_resolved")["gpu_created"])
        self.assertEqual(self.event(records, "project.engine_compatibility")["compatibility"], "same_version")

    def test_compiled_product_identity_is_exposed_without_opening_a_project(self):
        for executable in (EDITOR, RUNTIME):
            records = self.run_app(executable, "--version")
            fields = self.event(records, "application.version")
            self.assertEqual(fields["engine_version"], "0.1.0a1")
            self.assertEqual(fields["project_engine_version"], "0.1.0-alpha.1")
            self.assertFalse(fields["core_abi_checked"])

    def test_editor_launches_real_runtime_and_compares_full_fingerprint(self):
        records = self.check(RUNTIME, expected=0)
        own = self.event(records, "editor.validation_complete")
        checked = self.event(records, "runtime.check_complete")
        self.assertEqual(own["fingerprint"], checked["fingerprint"])
        self.assertFalse(checked["play_started"])
        child = [r["fields"]["record"] for r in records if r["event"] == "runtime.output"]
        self.assertEqual(self.event(child, "runtime.validation_complete")["fingerprint"], own["fingerprint"])
        self.assertNotEqual(child[0]["session_id"], records[0]["session_id"])
        self.assertEqual(self.event(child, "graphics.config_resolved")["parameters"], self.event(records, "graphics.config_resolved")["parameters"])

        # JSONL is framed by LF only, not Unicode line/paragraph separators.
        self.path = self.directory / "Line\u2028break\u0085project.proj"
        self.write(self.base)
        records = self.check(RUNTIME, expected=0)
        self.assertIn("Line\u2028break\u0085project.proj", self.event(records, "project.document_validated")["path"])

        if sys.platform == "linux":
            # A UTF-8 CLI symlink may resolve to a non-UTF8 POSIX filename.
            target = os.fsencode(self.directory) + b"/invalid-\xff.proj"
            with open(target, "wb") as output:
                output.write(self.path.read_bytes())
            self.path = self.directory / "UTF8 symlink.proj"
            os.symlink(target, os.fsencode(self.path))
            fields = self.event(self.validate(expected=3), "project.read_failed")
            self.assertEqual(fields["code"], "UnsupportedProjectPathEncoding")

    def test_v2_backends_and_host_policy_are_not_gpu_claims(self):
        for backend in ("vulkan", "opengl", "d3d11", "d3d12"):
            value = copy.deepcopy(self.base)
            value["schema_version"] = 2
            value["engine"]["graphics_backend"] = backend
            self.write(value)
            records = self.check(RUNTIME, expected=0)
            policy = self.event(records, "application.target_policy")
            self.assertEqual(policy["authoring_domains"], ["scene_3d", "ui_canvas"])
            self.assertFalse(policy["scene_2d_supported"])
            self.assertFalse(policy["renderer_linked"])
            expected = "backend_not_on_platform" if sys.platform.startswith("linux") and backend.startswith("d3d") else "allowed"
            self.assertEqual(policy["decision"], expected)
            normal = self.run_app(RUNTIME, "--project", self.path, expected=4)
            self.event(normal, "application.backend_unsupported" if expected != "allowed" else "application.core_unavailable")

    def test_legacy_removed_backends_are_inspectable_but_not_executable(self):
        for backend in ("metal", "webgpu"):
            value = copy.deepcopy(self.base)
            value["engine"]["graphics_backend"] = backend
            self.write(value)
            self.assertEqual(self.event(self.validate(), "application.target_policy")["decision"], "backend_out_of_scope")
            self.event(self.run_app(RUNTIME,"--project",self.path,expected=4),"application.backend_unsupported")
            value["schema_version"] = 2
            self.write(value)
            self.assertEqual(self.event(self.validate(expected=3),"project.invalid")["pointer"],"/engine/graphics_backend")

    def test_low_medium_high_and_false_zero_overrides(self):
        identities = set()
        for preset, samples, map_size in (("low", 1, 512), ("medium", 2, 2048), ("high", 4, 4096)):
            value = copy.deepcopy(self.base)
            value["renderer"]["graphics_preset"] = preset
            self.write(value)
            records = self.validate()
            params = self.event(records, "graphics.config_resolved")["parameters"]
            self.assertEqual(params["msaa_samples"], samples)
            self.assertEqual(params["shadow_map_size"], map_size)
            self.assertEqual(len(params), 27)
            identities.add(self.event(records, "runtime.validation_complete")["fingerprint"])
        self.assertEqual(len(identities), 3)
        value["renderer"]["overrides"] = dict(shadows_enabled=False, texture_mip_bias=0, tone_mapping="none", msaa_samples=1)
        self.write(value)
        params = self.event(self.check(RUNTIME, expected=0), "graphics.config_resolved")["parameters"]
        self.assertFalse(params["shadows_enabled"])
        self.assertEqual(params["texture_mip_bias"], 0)
        self.assertEqual(params["tone_mapping"], "none")
        self.assertEqual(params["msaa_samples"], 1)

    def test_cli_help_missing_unknown_duplicate(self):
        for executable in (EDITOR, RUNTIME):
            self.event(self.run_app(executable, "--help"), "cli.help")
            for args in ((), ("--headless",), ("--wat",), ("--project",), ("--headless", "--headless")):
                self.event(self.run_app(executable, *args, expected=2), "cli.invalid")

    def test_future_missing_and_string_schema_version(self):
        for version, reason in ((3, "UnsupportedSchemaVersion"), ("1", "InvalidField"), (None, "MissingSchemaVersion")):
            value = copy.deepcopy(self.base)
            if version is None:
                del value["schema_version"]
            else:
                value["schema_version"] = version
            self.write(value)
            for executable in (EDITOR, RUNTIME):
                fields = self.event(self.validate(executable, expected=3), "project.invalid")
                self.assertEqual(fields["code"], reason)
                self.assertEqual(fields["pointer"], "/schema_version")

    def test_duplicate_keys_and_invalid_override(self):
        self.path.write_text('{"schema_version":1,"schema_version":1}', encoding="utf-8")
        self.assertEqual(self.event(self.validate(expected=3), "project.invalid")["code"], "DuplicateField")
        value = copy.deepcopy(self.base)
        value["renderer"]["overrides"] = {"draw_distance_m": 1}
        self.write(value)
        self.event(self.validate(expected=3), "presets.invalid_configuration")

    def test_normal_and_headless_execution_fail_instead_of_faking_core(self):
        for executable in (EDITOR, RUNTIME):
            for flags in ((), ("--headless",)):
                records = self.run_app(executable, "--project", self.path, *flags, expected=4)
                self.event(records, "application.core_unavailable")
                self.assertFalse(any(r["event"].endswith("validation_complete") for r in records))

    def test_engine_identity_mismatch(self):
        value = copy.deepcopy(self.base)
        value["engine"]["version"] = "99.0.0"
        self.write(value)
        fields = self.event(self.validate(expected=4), "project.engine_incompatible")
        self.assertEqual(fields["compatibility"], "incompatible")

    def test_missing_and_oversized_project(self):
        self.event(self.run_app(RUNTIME, "--project", self.directory / "missing.proj", "--validate-only", expected=3), "project.read_failed")
        self.path.write_bytes(b" " * (1024 * 1024 + 1))
        records = self.validate(expected=3)
        self.assertTrue(any(r["event"] in ("project.invalid", "project.read_failed") for r in records))

    def test_distribution_relocation_and_different_cwd(self):
        _, runtime = self.copy_distribution()
        records = self.validate(runtime, cwd=self.directory)
        self.event(records, "runtime.validation_complete")

    def test_missing_resources_do_not_fall_back_to_cwd(self):
        prefix, runtime = self.copy_distribution()
        (prefix / "share/corex/presets.zon").unlink()
        shutil.copy2(ROOT / "docs/examples/presets.zon", self.directory / "presets.zon")
        self.event(self.validate(runtime, expected=4, cwd=self.directory), "distribution.invalid")

    def test_tampered_table_and_manifest_are_rejected(self):
        prefix, runtime = self.copy_distribution()
        table = prefix / "share/corex/presets.zon"
        original = table.read_bytes()
        table.write_bytes(original.replace(b"250.0", b"251.0"))
        self.assertEqual(self.event(self.validate(runtime, expected=4), "distribution.invalid")["code"], "DistributionInvalid")
        table.write_bytes(original)
        (prefix / "share/corex/distribution.json").write_text("{}", encoding="utf-8")
        self.assertEqual(self.event(self.validate(runtime, expected=4), "distribution.manifest_corrupted")["code"], "ManifestCorrupted")

    def test_missing_or_relative_child_is_not_path_searched(self):
        self.event(self.check(self.directory / "missing runtime"), "runtime.check_failed")
        fields = self.event(self.check("CoreXRuntime"), "runtime.check_failed")
        self.assertEqual(fields["code"], "AbsolutePathRequired")

    def test_child_failure_is_propagated_from_real_runtime(self):
        prefix, runtime = self.copy_distribution()
        (prefix / "share/corex/distribution.json").unlink()
        records = self.check(runtime)
        self.assertEqual(self.event(records, "runtime.check_failed")["exit_code"], 4)
        children = [r["fields"]["record"] for r in records if r["event"] == "runtime.output"]
        self.event(children, "distribution.invalid")

    def test_exit_zero_without_protocol_is_not_success(self):
        records = self.check(self.fake("pass"))
        self.assertEqual(self.event(records, "runtime.check_failed")["matching_completions"], 0)

    def test_invalid_fragmented_and_unterminated_output_is_diagnostic(self):
        body = "os.write(1,b'not json\\n{bad'); os.write(1,b'}\\n'); os.write(2,b'last without LF')"
        records = self.check(self.fake(body))
        invalid = [r for r in records if r["event"] == "runtime.output_invalid"]
        self.assertEqual(len(invalid), 3)

    def test_wrong_fingerprint_is_not_a_handshake(self):
        body = "emit(event='runtime.validation_complete',fields={'fingerprint':'f'*64,'scope':'document_and_presets'})"
        records = self.check(self.fake(body))
        self.assertTrue(self.event(records, "runtime.check_failed")["protocol_mismatch"])

    def test_session_and_sequence_mismatches(self):
        for body in ("emit(1,'a'); emit(2,'b')", "emit(2); emit(1)"):
            records = self.check(self.fake(body))
            self.assertTrue(self.event(records, "runtime.check_failed")["protocol_mismatch"])

    def test_duplicate_sequence_across_pipes_is_rejected(self):
        records = self.check(self.fake("emit(1); emit(1,level='error',stream=sys.stderr)"))
        self.assertTrue(self.event(records, "runtime.check_failed")["protocol_mismatch"])

    def test_raw_library_output_does_not_hide_valid_runtime_confirmation(self):
        runtime = str(RUNTIME)
        body = f"os.write(2,b'library warning\\n')\nos.execv({runtime!r},[{runtime!r}]+sys.argv[1:])"
        records = self.check(self.fake(body), expected=0)
        self.event(records, "runtime.output_invalid")
        self.event(records, "runtime.check_complete")

    def test_two_pipes_are_drained_without_deadlock(self):
        body = "\nfor i in range(16):\n    os.write(1,b'x'*8192)\n    os.write(2,b'y'*8192)\n"
        records = self.check(self.fake(body))
        invalid = [r for r in records if r["event"] == "runtime.output_invalid"]
        self.assertEqual(len(invalid), 2)
        self.assertTrue(all(r["fields"]["code"] == "LineTooLong" for r in invalid))

    def test_capture_overflow_kills_and_reaps_child(self):
        pidfile = self.directory / "probe.pid"
        self.addCleanup(self.cleanup_probe, pidfile)
        body = f"open({str(pidfile)!r},'w').write(str(os.getpid()))\nwhile True: os.write(1,b'x'*8192)"
        records = self.check(self.fake(body))
        self.assertEqual(self.event(records, "runtime.check_failed")["code"], "StreamTooLong")
        self.assert_reaped(pidfile)

    def cleanup_probe(self, pidfile):
        if pidfile.exists():
            try:
                os.kill(int(pidfile.read_text()), signal.SIGKILL)
            except ProcessLookupError:
                pass

    def assert_reaped(self, pidfile):
        pid = int(pidfile.read_text())
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            pidfile.unlink()
            return
        # Do not leave a runaway helper behind if the regression ever returns.
        os.kill(pid, signal.SIGKILL)
        self.fail(f"child {pid} was not killed/reaped")

    def test_deadline_reaps_term_resistant_child_after_early_pipe_close(self):
        pidfile = self.directory / "probe.pid"
        self.addCleanup(self.cleanup_probe, pidfile)
        body = f"open({str(pidfile)!r},'w').write(str(os.getpid()))\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\nos.close(1)\nos.close(2)\ntime.sleep(60)"
        start = time.monotonic()
        records = self.check(self.fake(body), timeout=18)
        self.assertEqual(self.event(records, "runtime.check_failed")["code"], "Timeout")
        self.assertLess(time.monotonic() - start, 15)
        self.assert_reaped(pidfile)

    def test_invalid_line_flood_has_a_bounded_diagnostic_budget(self):
        records = self.check(self.fake("os.write(1,b'\\n'*5000)"))
        warnings = [r for r in records if r["event"] == "runtime.output_invalid"]
        self.assertEqual(len(warnings), 4097)
        self.assertEqual(warnings[-1]["fields"]["code"], "RecordBudgetExceeded")
        failed = self.event(records, "runtime.check_failed")
        self.assertEqual(failed["discarded_frames"], 904)
        self.assertTrue(failed["protocol_mismatch"])

    def test_wrapped_record_overflow_is_a_bounded_warning(self):
        records = self.check(self.fake("emit(fields={'payload':'x'*65100})"))
        fields = self.event(records, "log.record_too_large")
        self.assertTrue(fields["truncated"])
        self.assertEqual(fields["original_event"], "runtime.output")

    def test_broken_output_pipe_returns_controlled_nonzero_status(self):
        if os.name != "posix":
            self.skipTest("pipe-close timing probe is POSIX-only")
        process = subprocess.Popen([str(RUNTIME), "--project", str(self.path), "--validate-only"],
                                   stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            process.stdout.close()
            self.assertEqual(process.wait(timeout=10), 74)
            self.assertEqual(process.stderr.read(), b"")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            process.stderr.close()

    def test_nonzero_exit_is_not_silently_accepted(self):
        records = self.check(self.fake("emit(level='error',stream=sys.stderr); sys.exit(9)"))
        self.assertEqual(self.event(records, "runtime.check_failed")["exit_code"], 9)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--editor", type=Path, default=EDITOR)
    parser.add_argument("--runtime", type=Path, default=RUNTIME)
    args = parser.parse_args()
    EDITOR, RUNTIME = args.editor.resolve(), args.runtime.resolve()
    if not EDITOR.is_file() or not RUNTIME.is_file():
        parser.error("build editor/ and runtime/ before running integration tests")
    unittest.main(argv=[sys.argv[0]], verbosity=2)
