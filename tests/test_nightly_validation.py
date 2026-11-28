"""Exercise workflow shell and verdict handling without a cluster or GitHub writes."""

import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = yaml.safe_load(
    (ROOT / ".github/workflows/reusable-ci-nightly-benchmark.yaml").read_text()
)
STEPS = {s["id"]: s for s in WORKFLOW["jobs"]["benchmark"]["steps"] if "id" in s}


def expression(source, values, cancelled=False):
    """Evaluate the small boolean subset used by these step conditions."""
    source = source.removeprefix("${{").removesuffix("}}").strip()
    source = source.replace("always()", "True").replace("cancelled()", str(cancelled))
    source = re.sub(
        r"\b(?:steps|inputs)\.[a-zA-Z0-9_.]+",
        lambda m: repr(values.get(m[0], "")),
        source,
    )
    source = source.replace("&&", " and ").replace("||", " or ")
    source = re.sub(r"!(?!=)", " not ", source)
    return eval(source, {"__builtins__": {}}, {})


def render(source, values):
    return re.sub(r"\$\{\{\s*(.*?)\s*\}\}", lambda m: values.get(m[1], ""), source)


class WorkflowTests(unittest.TestCase):
    def test_disabled_defaults(self):
        inputs = WORKFLOW[True]["workflow_call"]["inputs"]
        self.assertEqual(inputs["llmdv_version"]["default"], "")
        self.assertEqual(inputs["llmdv_blocking"]["default"], "false")

    def test_start_guards(self):
        values = {
            "steps.guide_standup.outcome": "success",
            "inputs.standup_method": "kustomize",
            "inputs.llmdv_version": "0.1.4",
            "inputs.dry_run": "false",
        }
        condition = STEPS["prepare_llmdv"]["if"]
        self.assertTrue(expression(condition, values))
        self.assertFalse(expression(condition, values, cancelled=True))
        for key, value in [
            ("steps.guide_standup.outcome", "failure"),
            ("inputs.standup_method", "standalone"),
            ("inputs.llmdv_version", ""),
            ("inputs.dry_run", "true"),
        ]:
            with self.subTest(key=key):
                self.assertFalse(expression(condition, {**values, key: value}))

    def test_only_recorded_failure_gates_regardless_of_upload(self):
        condition = STEPS["gate_llmdv"]["if"]
        for blocking in ("true", "false"):
            for code in ("", "0", "1", "2", "3", "4", "5", "6"):
                for upload in ("success", "failure"):
                    with self.subTest(blocking=blocking, code=code, upload=upload):
                        values = {
                            "inputs.llmdv_blocking": blocking,
                            "steps.validate_llmdv.outputs.verification_exit": code,
                            "steps.upload_llmdv.outcome": upload,
                        }
                        self.assertEqual(
                            expression(condition, values),
                            blocking == "true" and code == "1",
                        )
        self.assertEqual(
            subprocess.run(["bash", "-e", "-c", STEPS["gate_llmdv"]["run"]]).returncode,
            1,
        )

    def test_order_and_tolerated_delivery(self):
        order = list(STEPS)
        self.assertLess(order.index("benchmark_run"), order.index("prepare_llmdv"))
        self.assertLess(
            order.index("prepare_llmdv"), order.index("guide_teardown_again")
        )
        self.assertLess(
            order.index("infra_upload_results_to_gcs"), order.index("gate_llmdv")
        )
        self.assertLess(order.index("gate_llmdv"), order.index("detect_failure"))
        self.assertLess(order.index("finalize_llmdv"), order.index("guide_teardown_again"))
        self.assertLess(order.index("guide_teardown_again"), order.index("upload_llmdv"))
        self.assertEqual(STEPS["guide_teardown_again"]["if"], "always()")
        for name in (
            "prepare_llmdv",
            "validate_llmdv",
            "finalize_llmdv",
            "upload_llmdv",
        ):
            self.assertTrue(STEPS[name]["continue-on-error"])
            self.assertGreater(STEPS[name]["timeout-minutes"], 0)
        self.assertTrue(
            expression(
                STEPS["upload_llmdv"]["if"],
                {"steps.prepare_llmdv.outputs.runs_dir": "/tmp/partial"},
                cancelled=True,
            )
        )
        self.assertFalse(expression(STEPS["upload_llmdv"]["if"], {}))

    def test_warnings_distinguish_setup_from_verdict(self):
        step = next(
            s
            for s in WORKFLOW["jobs"]["benchmark"]["steps"]
            if s["name"] == "Report validation integration or upload problems"
        )
        for code, upload, expected in [
            ("", "success", True),
            ("1", "success", False),
            ("1", "failure", True),
        ]:
            values = {
                "steps.validate_llmdv.outcome": "failure",
                "steps.validate_llmdv.outputs.verification_exit": code,
                "steps.upload_llmdv.outcome": upload,
            }
            self.assertEqual(expression(step["if"], values), expected)
        self.assertTrue(step["continue-on-error"])

    def test_finalize_runs_after_cancel_and_preserves_recovered_failure(self):
        self.assertTrue(
            expression(
                STEPS["finalize_llmdv"]["if"],
                {"steps.prepare_llmdv.outputs.work_dir": "/tmp/state"},
                cancelled=True,
            )
        )
        self.assertTrue(
            expression(
                STEPS["gate_llmdv"]["if"],
                {
                    "inputs.llmdv_blocking": "true",
                    "steps.finalize_llmdv.outputs.verification_exit": "1",
                },
            )
        )
        self.assertFalse(
            expression(
                STEPS["validate_llmdv"]["if"],
                {"steps.prepare_llmdv.outputs.status": "prepared"},
                cancelled=True,
            )
        )
        self.assertIn("exec bash", STEPS["validate_llmdv"]["run"])
        # Keep the admission reserve aligned with all bounded validation phases.
        minutes = (
            sum(
                STEPS[s]["timeout-minutes"]
                for s in (
                    "prepare_llmdv",
                    "validate_llmdv",
                    "finalize_llmdv",
                    "upload_llmdv",
                )
            )
            + 20
        )
        self.assertIn(f"(240 - {minutes}) * 60", STEPS["prepare_llmdv"]["run"])

    def test_failure_categories(self):
        for benchmark, gate, expected in [
            ("success", "failure", "validation"),
            ("failure", "failure", "benchmark"),
            ("failure", "skipped", "benchmark"),
        ]:
            with (
                self.subTest(benchmark=benchmark, gate=gate),
                tempfile.TemporaryDirectory() as tmp,
            ):
                output = Path(tmp) / "output"
                values = {
                    "steps.benchmark_run.outcome": benchmark,
                    "steps.gate_llmdv.outcome": gate,
                }
                result = subprocess.run(
                    [
                        "bash",
                        "-e",
                        "-c",
                        render(STEPS["detect_failure"]["run"], values),
                    ],
                    env={**os.environ, "GITHUB_OUTPUT": str(output)},
                    capture_output=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    output.read_text().strip(), f"failure_category={expected}"
                )

    def test_validation_badge(self):
        workflow = yaml.safe_load(
            (ROOT / ".github/workflows/reusable-update-badge.yaml").read_text()
        )
        script = next(
            s["run"]
            for job in workflow["jobs"].values()
            for s in job["steps"]
            if 'case "${{ inputs.failure_category }}"' in s.get("run", "")
        )
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "output"
            # Find the result input by reading the existing badge workflow expression.
            values = {
                "inputs.failure_category": "validation",
                "inputs.result": "failure",
            }
            result = subprocess.run(
                ["bash", "-e", "-c", render(script, values)],
                env={**os.environ, "GITHUB_OUTPUT": str(output)},
                capture_output=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("message=validation-error", output.read_text())


class SetupTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.command(
            "timeout", '#!/bin/bash\n[[ "$1" == -k && "$2" == 5 && "$3" == 120 ]] || exit 99\nshift 3\nexec "$@"\n'
        )
        self.command(
            "git",
            """#!/bin/bash
if [[ "$1" != clone ]]; then
  [[ -z "${FAKE_GIT_LOG:-}" ]] || printf '%s\n' "$@" >> "$FAKE_GIT_LOG"
  if [[ "$1" == init ]]; then mkdir -p "${!#}"; fi
  if [[ "$*" == *"checkout -q --detach FETCH_HEAD"* ]]; then
    mkdir -p "$2/deploy/llm-d-nightly"
    echo 'touch "$POISON_FILE"' > "$2/deploy/llm-d-nightly/smoke-step.sh"
  fi
  exit 0
fi
[[ "$*" == *"--branch v0.1.4"* ]] || exit 98
[[ "$*" == *"https://github.com/llm-d-incubation/llm-d-validate.git"* ]] || exit 97
[[ "${FAKE_CLONE_FAIL:-0}" == 0 ]] || exit 128
destination="${!#}"
mkdir -p "$destination/deploy/llm-d-nightly"
cat > "$destination/deploy/llm-d-nightly/smoke-step.sh" <<'SH'
[[ "$LLMDV_VERSION" == 0.1.4 && "$1" == prepare ]] || exit 96
mkdir -p "$RUNNER_TEMP/llmdv-runs"
echo 'status=prepared' >> "$GITHUB_OUTPUT"
echo "profile_root=$LLMDV_PROFILE_ROOT" >> "$GITHUB_OUTPUT"
echo '{"status":"prepared"}' > "$RUNNER_TEMP/llmdv-runs/integration.json"
echo "verification_exit=${FAKE_VERDICT:-0}" >> "$GITHUB_OUTPUT"
exit "${FAKE_VERDICT:-0}"
SH
""",
        )

    def command(self, name, content):
        path = self.bin / name
        path.write_text(content)
        path.chmod(0o755)

    def run_setup(self, **extra):
        output = self.root / "output"
        output.write_text("")
        env = {
            **os.environ,
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "RUNNER_TEMP": str(self.root),
            "GITHUB_OUTPUT": str(output),
            "GITHUB_RUN_ID": "123",
            "GITHUB_RUN_ATTEMPT": "1",
            "LLMDV_VERSION": "0.1.4",
            "LLMDV_JOB_STARTED_AT": str(int(time.time())),
            "LLMDV_PROFILE_REPOSITORY": "llm-d-incubation/llm-d-validate",
            "LLMDV_PROFILE_REF": "",
            "LLMDV_PROFILE": "",
            "GITHUB_STEP_SUMMARY": str(self.root / "summary"),
            **extra,
        }
        result = subprocess.run(
            ["bash", "-e", "-o", "pipefail", "-c", STEPS["prepare_llmdv"]["run"]],
            env=env,
            text=True,
            capture_output=True,
        )
        values = dict(line.split("=", 1) for line in output.read_text().splitlines())
        return result, values

    def test_release_and_outputs(self):
        result, values = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(values["verification_exit"], "0")
        self.assertTrue((Path(values["runs_dir"]) / "integration.json").is_file())

    def test_repeated_calls_are_isolated(self):
        _, first = self.run_setup()
        _, second = self.run_setup()
        self.assertNotEqual(first["runs_dir"], second["runs_dir"])
        self.assertNotEqual(first["artifact_name"], second["artifact_name"])

    def test_verdict_survives_wrapper_failure(self):
        result, values = self.run_setup(FAKE_VERDICT="1")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(values["verification_exit"], "1")

    def test_clone_failure_has_no_verdict(self):
        result, values = self.run_setup(FAKE_CLONE_FAIL="1")
        self.assertEqual(result.returncode, 128)
        self.assertNotIn("verification_exit", values)
        self.assertTrue(Path(values["runs_dir"]).is_dir())

    def test_profile_fork_and_commit_do_not_execute_profile_scripts(self):
        log = self.root / "git-log"
        poison = self.root / "executed-profile-code"
        commit = "a" * 40
        result, values = self.run_setup(
            LLMDV_PROFILE_REPOSITORY="example/profiles",
            LLMDV_PROFILE_REF=commit,
            LLMDV_PROFILE="profiles/custom.yaml",
            FAKE_GIT_LOG=str(log),
            POISON_FILE=str(poison),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("https://github.com/example/profiles.git", log.read_text())
        self.assertIn(commit, log.read_text())
        self.assertTrue(values["profile_root"].endswith("/profiles"))
        self.assertFalse(poison.exists())

    def test_low_budget_skips_before_checkout(self):
        result, values = self.run_setup(LLMDV_JOB_STARTED_AT="1")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(values, {})
        self.assertIn("reserving time", (self.root / "summary").read_text())

    def test_missing_clock_skips(self):
        result, values = self.run_setup(LLMDV_JOB_STARTED_AT="")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(values, {})

    def test_invalid_repository_or_ref_cannot_execute(self):
        for overrides in (
            {"LLMDV_PROFILE_REPOSITORY": "https://bad/path"},
            {"LLMDV_PROFILE_REF": "--upload-pack=bad"},
        ):
            result, values = self.run_setup(**overrides)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(values, {})

    def test_invalid_versions_do_not_clone(self):
        for version in ("v0.1.4", "--help", "0.1.4;exit 0", "main", ""):
            with self.subTest(version=version):
                result, values = self.run_setup(LLMDV_VERSION=version)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(values, {})


if __name__ == "__main__":
    unittest.main()
