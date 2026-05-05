# Zig Persistent Worker Plan

Owner: next agent working in `rules_zig`.

Goal: add an optional Bazel persistent worker for Zig compile actions so Zig can keep its cache across actions/builds without requiring `/tmp` or `/var/tmp` sandbox mount pairs.

## Current Decision Log

- [x] Use a Zig worker, not C++.
- [x] Use Bazel worker JSON protocol over stdin/stdout, not gRPC.
- [x] Do not implement multiplexing in the first version.
- [x] Keep the worker as a wrapper around the existing Zig CLI. Do not embed or link Zig compiler internals.
- [x] First rollout is opt-in by build setting, default off.
- [x] Preserve direct non-worker actions as the default and as the fallback path.

## References Read

- Bazel worker docs: `https://bazel.build/remote/creating`, `https://bazel.build/remote/persistent`.
- Bazel protocol shape: `src/main/protobuf/worker_protocol.proto` in `bazelbuild/bazel`.
- Bazel worker arg split: `WorkerParser.splitSpawnArgsIntoWorkerArgsAndFlagFiles`; strict mode wants exactly one final `@flagfile`.
- `rules_swift` model: JSON worker in `tools/worker/worker_protocol.cc`; worker fallback in `tools/worker/worker_main.cc`; action wiring in `swift/internal/actions.bzl`.
- `rules_kotlin` model: proto worker in `src/main/kotlin/io/bazel/worker/PersistentWorker.kt`; action execution requirements in `kotlin/internal/toolchains.bzl`.
- Local cache wiring today: `zig/private/common/zig_cache.bzl`, `.bazelrc.common`, `README.md`.

## Acceptance Criteria

- [x] `--@rules_zig//zig/settings:use_workers=true` makes eligible Zig compile actions register with `supports-workers = "1"` and run through the worker executable when Bazel selects the worker strategy.
- [x] `--@rules_zig//zig/settings:use_workers=false` keeps current direct `zig` action behavior.
- [x] Worker mode keeps Zig cache state under a Bazel-owned output-tree path, not `/tmp` or `/var/tmp`.
- [x] Worker responses capture child Zig stdout/stderr in `WorkResponse.output`; worker stdout contains only JSON `WorkResponse` messages.
- [x] Non-worker invocation of the worker binary executes the same Zig command once and exits.
- [x] Existing compile behavior is preserved when workers are disabled.
- [ ] Existing docs/translate-c behavior is preserved when workers are disabled. Deferred by user request; not touched.
- [x] Tests prove action registration, worker protocol basics, fallback mode, cache override, and at least one real worker build.
- [ ] Docs explain opt-in, strategy flag, sandboxing limitation, and cache behavior. Deferred by user request.

## Implementation Tasks

- [x] Add worker build settings.
  - Add `use_workers` and `host_use_workers` `bool_flag`s in `zig/settings/BUILD.bazel`, default `False`.
  - Add both labels to `settings(...)` and `zig/private/settings.bzl`.
  - Add `use_workers` to `ZigSettingsInfo`.
  - Add `.bazelrc.flags` alias, likely `build --flag_alias=zig_workers=@rules_zig//zig/settings:use_workers`.
  - Add analysis tests mirroring `use_cc_common_link` / mode tests.

- [x] Add a private worker package.
  - Suggested path: `zig/private/worker/`.
  - Add `worker.zig`.
  - Add BUILD target for the worker binary.
  - Avoid a self-cycle: build worker with a private direct-Zig action/rule, or another bootstrap path that does not itself use the worker.
  - Include worker files in `all_files` targets after implementation.

- [x] Implement worker protocol in Zig.
  - Detect and remove `--persistent_worker` from startup args.
  - If not present, run one command and return its exit code.
  - In persistent mode, read newline-delimited JSON `WorkRequest` objects from stdin.
  - Parse fields needed now: `arguments`, `requestId`, `cancel`, `verbosity`.
  - Ignore unknown fields.
  - Respond once per non-cancel request.
  - For cancel requests, return a `wasCancelled` response or ignore if singleplex is not using cancellation.
  - Write compact JSON `WorkResponse` to stdout and flush after each response.

- [x] Implement command execution in worker.
  - Startup args should contain stable worker args only, probably Zig executable/lib metadata and cache policy.
  - Request args should contain the actual Zig subcommand and flags.
  - Spawn the Zig executable as a child process.
  - Redirect child stdout and stderr into buffers.
  - Return child exit code and combined output through `WorkResponse.output`.
  - Never let child stdout/stderr write to worker stdout directly.
  - Preserve env values needed today: `ZIG_LIB_DIR`, `ZIG_GLOBAL_CACHE_DIR`, `ZIG_LOCAL_CACHE_DIR`.

- [x] Design and implement worker cache path.
  - Derive a cache root from worker cwd / output base, not from `/tmp`.
  - Include at least Zig version in the cache path.
  - Prefer a path removed by `bazel clean`.
  - Candidate: locate from cwd under `<outputBase>/bazel-workers/...` and create `<outputBase>/rules_zig_worker_cache/<zig_version>/`.
  - Use that path for both `--cache-dir` and `--global-cache-dir` in worker mode.
  - Keep existing `zigtoolchaininfo.zig_cache` for direct mode.

- [ ] Refactor action registration.
  - Centralized Zig compile action creation in `zig_build.bzl`.
  - `zig_docs.bzl`, `translate_c.bzl`, and `zig_c_library.bzl` deferred by user request.
  - When workers are disabled, keep existing `ctx.actions.run` / `run_shell` shape.
  - When enabled, set executable to the worker.
  - Add execution requirements:
    - `supports-workers = "1"`
    - `requires-worker-protocol = "json"`
    - likely `worker-key-mnemonic = "ZigCompile"` or one stable value per cache-compatible group.
  - Ensure action `arguments` ends with exactly one final `@flagfile`.
  - Put per-request Zig command and flags in that final flagfile.
  - Keep startup args stable enough to avoid too many worker keys.

- [ ] Handle special action forms.
  - `zig_build.bzl`: `build-exe`, `build-lib`, `test --test-no-exec`, shared library `-dynamic`.
  - `zig_docs.bzl`: deferred by user request.
  - `translate_c.bzl`: deferred by user request.
  - `zig_c_library.bzl`: deferred by user request.
  - `use_cc_common_link`: only Zig compile sub-actions should use worker; `cc_common.link` stays untouched.

- [x] Add tests.
  - Unit/analysis tests:
    - settings provider exposes `use_workers`.
    - disabled actions have no worker startup args.
    - enabled actions use worker startup args.
    - execution requirements verified manually with `aquery`; analysis `Action` does not expose them.
    - strict final param file shape is present in action wiring; `aquery` expands it in display.
  - Worker protocol tests:
    - parse request/response JSON.
    - one-shot fallback runs a simple command.
    - persistent loop handles at least two requests.
    - child output is captured into response, not worker stdout.
  - End-to-end:
    - build a simple `zig_binary` with `--zig_workers=true --strategy=ZigCompile=worker,local`.
    - rebuild/touch source and verify success.
    - run under `--worker_quit_after_build` during tests to avoid leaked processes.
    - optionally inspect action args/cache path with `aquery`.
    - integration test poisons `RULES_ZIG_CACHE_PREFIX`, restarts Bazel, and verifies worker builds still use `bazel-out/rules_zig_worker_cache`.

- [ ] Update docs. Deferred by user request.
  - README cache section: explain worker cache path and that `/tmp` mount pairs are only needed for direct/sandbox cache mode.
  - `.bazelrc.common`: decide whether to remove mount-pair defaults only after worker mode is stable and default-on.
  - Generated docs for settings/rules if applicable.
  - Add usage snippet:
    - `build --flag_alias=zig_workers=@rules_zig//zig/settings:use_workers`
    - `build --zig_workers=true`
    - `build --strategy=ZigCompile=worker,local`

- [ ] Verification pass.
  - Run focused analysis tests for settings and rules.
  - Run worker unit tests.
  - Run real worker build/test targets.
  - Run existing focused suites: `bazel test //zig/tests:config_test //zig/tests:cache_test //zig/tests:rules_test`.
  - Run integration tests if time/network/cache permits.
  - Record exact pass/fail commands in this file.

## Open Questions

- [ ] Should the first setting be a bool (`use_workers`) or a tri-state (`off`, `auto`, `on`)?
  - Current plan uses bool default false because it is simple and mirrors existing repo settings.
  - A tri-state may be useful later if default behavior changes.
- [x] Does a Zig-built worker create an unacceptable bootstrap cycle?
  - Resolved: private bootstrap rule compiles `worker.zig` directly with toolchain Zig.
- [ ] What exact cache root survives between worker requests and is removed by `bazel clean` on all supported platforms?
  - Current implementation uses `bazel-out/rules_zig_worker_cache/<zig_version>` from execroot cwd.
  - Verified on macOS with Zig 0.16.0 simple build.
- [x] Should docs/translate-c use worker in first PR?
  - Deferred by user request on 2026-05-05; compile actions only for now.
- [ ] How should worker mode behave with `--worker_sandboxing`?
  - Current assumption: document unsupported initially. Confirm with a real build.

## Plan Review

- [x] The plan includes protocol choice, language choice, opt-in flag, action wiring, cache path, tests, docs, and rollout behavior.
- [x] The plan calls out the main Bazel worker trap: exactly one final flagfile for worker request args.
- [x] The plan calls out the main correctness trap: worker stdout must contain only `WorkResponse`.
- [x] The plan preserves the existing direct action path, reducing rollout risk.
- [x] The plan leaves enough code locations for a later agent to start without repeating the research.
- [x] Missing before implementation: exact bootstrap target shape for building the worker without recursive worker usage.
- [ ] Missing before implementation: exact cross-platform cache-root derivation.
- [x] Missing before implementation: decision whether docs/translate-c are in v1 or deferred.

## Session Notes

- Worktree at plan creation had only unrelated untracked `local_zig_toolchain_plan.md`.
- Implemented `use_workers` / `host_use_workers`, provider plumbing, `.bazelrc.flags` alias `--zig_workers`, private Zig worker bootstrap, JSON worker loop, and compile-action wiring for `zig_build.bzl`.
- `zig_docs.bzl`, `translate_c.bzl`, and `zig_c_library.bzl` intentionally not touched per user request.
- First worker build failed because nested Starlark `Args` were stringified into the worker request paramfile. Fixed by making compile actions end in a single forced multiline paramfile and passing command-shape args as worker startup args.
- Verification passed:
  - `bazel build //zig/private/worker:worker --verbose_failures`
  - `bazel build //zig/tests/simple-binary:binary --verbose_failures`
  - `bazel build //zig/tests/simple-binary:binary --zig_workers=true --strategy=ZigCompile=worker,local --worker_verbose --worker_quit_after_build --verbose_failures`
  - `bazel build //zig/tests/simple-library:library --zig_workers=true --strategy=ZigCompile=worker,local --worker_verbose --worker_quit_after_build --verbose_failures`
  - `bazel aquery 'mnemonic("ZigBuildExe", //zig/tests/simple-binary:binary)' --zig_workers=true --noinclude_artifacts --include_commandline --noinclude_param_files --output=text`
  - `bazel test //zig/tests:rules_test --test_output=errors --verbose_failures`
  - `bazel build //zig/private:all_files --verbose_failures`
- Worker execution proof from build output: Bazel created a non-sandboxed singleplex `ZigCompile` worker and reported `1 worker`; `aquery` showed `ExecutionInfo: {requires-worker-protocol: json, supports-workers: 1, worker-key-mnemonic: ZigCompile}`.
- Added `//zig/private/worker_tests:worker_protocol_test` after baseline commit. It uses a fake Zig executable to verify JSON responses, request ids, cancellation, child stdout/stderr capture, bad cache arg filtering, worker cache arg injection, cache entry creation, and one-shot fallback.
- Added integration coverage in `integration_tests_runner.zig`: worker build with `--zig_workers=true --strategy=ZigCompile=worker,local --worker_verbose --worker_quit_after_build`, poisoned `RULES_ZIG_CACHE_PREFIX`, `bazel shutdown`, then another worker build. This verifies the Bazel-owned cache path works across Bazel invocations and without the old `/tmp` or `/var/tmp` cache path.
- Worker bootstrap compile now uses `bazel-out/rules_zig_worker_cache/bootstrap/<zig_version>` so the worker binary itself does not fail when `RULES_ZIG_CACHE_PREFIX` is unusable.
- Additional verification passed:
  - `bazel build //zig/private/worker:worker --repo_env=RULES_ZIG_CACHE_PREFIX=/dev/null/rules_zig_direct_cache --verbose_failures`
  - `bazel test //zig/private/worker_tests:worker_protocol_test --test_output=errors --verbose_failures`
  - `bazel test //zig/tests/integration_tests:bzlmod_test_bazel_.bazelversion --test_output=errors --verbose_failures`
