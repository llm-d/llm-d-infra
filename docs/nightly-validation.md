# Router smoke validation in nightly benchmarks

The reusable benchmark workflow can run llmdv smoke tests against a guide's router
between the benchmark and teardown. Validation checks functional API behavior against
the selected profile; the benchmark continues to measure performance.

## What this enables

Enabling validation in a caller runs **router smoke checks** for that caller's deployment.
It does not enable other callers, run the full suite, or select gateway and engine ingresses.
The smoke set checks basic API behavior; passing it does not establish that a guide's
routing, caching, autoscaling, or performance goals have been met.

Automatic profile selection requires an exact scenario/overlay entry in the profile
checkout's [`deploy/llm-d-nightly/overlays.yaml`](https://github.com/llm-d-incubation/llm-d-validate/blob/main/deploy/llm-d-nightly/overlays.yaml).
The linked map shows main; the checked-out profile ref determines the map used by a run.
This integration runs only in the reusable benchmark workflow with
`standup_method: kustomize`. A mapped profile alone does not override that condition.

Agentic API, async multitenant, flow control, pod snapshot, and KEDA/EPP autoscaling
use separate nightly workflow steps. This PR does not add validation to those workflows;
they need their own integration even though llmdv profiles exist for them.

## Enable a first run

In an existing caller of `reusable-ci-nightly-benchmark.yaml`, add these entries to
its job's `with` mapping, keeping its existing deployment inputs:

```yaml
llmdv_version: '0.1.4'
llmdv_blocking: 'false'
```

Validation is disabled by default (`llmdv_version: ''`). Use a released version without
`v`; the wrapper, Python package, and image use that release. Profiles and their map
also use it unless you select a separate profile source below.
These examples use [llmdv 0.1.4](https://github.com/llm-d-incubation/llm-d-validate/releases/tag/v0.1.4),
published on PyPI and GHCR with separate prepare, verify, and finalize phases and
recovery fixes. Version 0.1.3 does not support this workflow.
The wrapper uses the job's existing Kubernetes access and reaches the router from
inside the cluster. No additional secrets or results bucket are required.

The step runs only for `kustomize`, after successful guide standup, outside dry-run
mode, and while the job is not cancelled. It can still run after a failed benchmark.
An unmapped scenario/overlay is reported as skipped. The versioned map owns coverage;
this workflow does not guess a profile for an unsupported configuration.

The prepare step validates the profile offline, creates the temporary ConfigMap and
pod, and waits for pod readiness. **Test requests begin when that pod starts.**
The verify step waits for its result; it does not start a second run. Both steps replace the outer shell with the wrapper,
so cancellation reaches its signal handler. State and any known verdict are saved before
collection or cleanup. A separate `always()` finalizer interrupts unfinished verification,
collects evidence, and removes the temporary objects. Collection keeps partial attempts.
Guide teardown runs before artifact upload. On cancellation, recovery uses a shorter
budget (about 80 seconds including cleanup) to leave time for that teardown.

The workflow records its start time before setup. It admits validation only with more than
66 minutes remaining in the existing 240-minute job: 20 for preparation, 16 for verification,
5 for recovery, 5 for upload, and a 20-minute reserve for existing cleanup and benchmark
uploads. When time is short or the clock is unavailable, validation is visibly skipped.
The wrapper's own deadlines finish before the Actions step limits; recovery reserves time
for cleanup. These are upper bounds, not expected smoke duration.

An abrupt runner loss, forced cancellation, or cleanup exceeding its reserve can still
prevent recovery. A pod deadline stops abandoned verification, but it does not replace
successful deletion of the pod and ConfigMap.

## Try profile changes without publishing a runtime

Keep the runtime release pinned and select a profile branch or commit independently:

```yaml
llmdv_version: '0.1.4'
llmdv_profile_repository: 'your-org/your-profiles'
llmdv_profile_ref: 'profile-experiment'
llmdv_profile: 'profiles/custom.yaml'
llmdv_blocking: 'false'
```

The optional repository must be public on GitHub. The default is
`llm-d-incubation/llm-d-validate`; an empty ref uses the runtime release tag. Branches,
tags, and full commit IDs are accepted. No PR or release is needed for profile edits,
but the branch must be pushed so the runner can fetch it.

The entire profile checkout is retained for `extends`. YAML inheritance must stay inside
that checkout, including through symlinks. Only the pinned runtime's scripts execute;
the profile checkout is data. `profile-source.json` records the repository, requested ref,
resolved commit, selected path, runtime version, and runtime commit.

With no explicit path, the profile checkout's `deploy/llm-d-nightly/overlays.yaml` selects
the profile and identity. An explicit path bypasses that mapping and its identity flags:
profile-derived identity is retained, but accelerator, provider, and flavor flags from
the map are not added. The profile must declare an ingress with `id: router`,
`kind: router`, and `base_url_env: LLMDV_ROUTER_URL`, with no inline `base_url`.
The installed runtime checks the built-in `smoke` selection offline before creating a pod.
Only that router ingress is selected for CI validation. Profiles using capabilities that
the pinned runtime does not recognize report a setup error instead of starting tests.

## Find and interpret the results

Open the job summary, then download its `llmdv-...` artifact. Names are unique per
invocation and run attempt. The artifact contains `integration.json` and, when
collected, the run's dashboard, results, exchanges, logs, profile, and failure evidence.
At the artifact root, read `integration.json` for orchestration status and
`profile-source.json` for the selected source (when preparation reached that step).
A successfully collected run is under `runs/<run-directory>/`; open its
`dashboard.html`. Unsuccessful copy attempts remain under `runs.partial-*/` and may
contain incomplete evidence. Setup failure can leave no run artifact; read the setup
step and summary in that case.

| Field | Meaning |
| --- | --- |
| `status` | `prepared`, `completed`, `skipped`, `setup_error`, `timed_out`, or `interrupted`; `completed` means verification exited, not that it passed |
| `verification_exit` | Recorded llmdv exit code; `null` in JSON or empty in step outputs when no verdict was obtained |
| `collection_status` | `not_attempted`, `complete`, or `failed`; independent of the verdict and artifact upload |

Read `verification_exit` as: `0` verification succeeded, `1` test failures, `2` usage
or profile error, `3` environment failure, `4` tool failure, `5` delivery failure,
and `6` interruption. A missing verdict establishes no test result.

A green non-blocking job is not proof of a passing validation run. In particular,
`collection_status: complete` means collection succeeded, not that GitHub accepted the
artifact. The upload step reports delivery failures separately.

This integration uploads current-run artifacts only. It does not publish to S3, send
notifications, or compare against a previous nightly. A failed check is not automatically
classified as a new regression.

## Roll out and optionally gate

Start with representative mapped configurations. Confirm the selected profile and model
match the deployment, smoke duration fits the remaining job budget, artifacts are readable,
and skips/setup errors are distinguishable from passes. Expand only after reviewing those
results. The existing fake-router end-to-end tests prove the wrapper mechanism, not every
real guide configuration.

After the smoke checks are reliable for a caller, it may set `llmdv_blocking: 'true'`.
Only recorded verification exit `1` fails that gate. Setup, collection, and upload problems
remain non-blocking, and delivery failure does not erase an already-recorded verification
failure. Other llmdv exits remain visible in the summary and artifacts. This option gates
fleet test failures only; it does not require validation to have run successfully.
Existing benchmark, setup, and teardown failures can still fail the overall nightly
regardless of `llmdv_blocking`.

The gate runs after existing cleanup and benchmark uploads. Failure classification keeps
benchmark failures first; a validation-gate failure is classified as `validation` and the
badge shows `validation-error`. Existing behavior is unchanged when validation is disabled.

## Local checks

Run the workflow hooks and offline integration tests:

```sh
pre-commit run --all-files
uv run --with 'PyYAML==6.0.3' python -m unittest discover -s tests -v
```

The tests inspect the workflow contract and execute its setup/classification shell with
fake commands. They do not deploy resources or make inference requests.
