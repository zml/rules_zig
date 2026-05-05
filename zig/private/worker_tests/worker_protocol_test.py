#!/usr/bin/env python3
import json
import os
import pathlib
import subprocess
import sys


def runfile(path: str) -> str:
    candidates = [
        pathlib.Path(path),
        pathlib.Path(os.environ.get("RUNFILES_DIR", "")) / path,
        pathlib.Path(os.environ.get("TEST_SRCDIR", "")) / path,
    ]
    for candidate in candidates:
        if candidate.is_file():
            return str(candidate.resolve())
    raise FileNotFoundError(path)


def assert_contains(value: str, needle: str) -> None:
    if needle not in value:
        raise AssertionError(f"missing {needle!r} in {value!r}")


def main() -> int:
    worker = runfile(sys.argv[1])
    fake_zig = runfile(sys.argv[2])

    workdir = pathlib.Path(os.environ["TEST_TMPDIR"]) / "worker-protocol"
    workdir.mkdir(parents=True, exist_ok=True)

    env = os.environ.copy()
    env["FAKE_ZIG_LOG"] = str(workdir / "fake-zig.log")

    requests = "\n".join(
        [
            json.dumps(
                {
                    "arguments": [
                        "--cache-dir",
                        "/dev/null/rules_zig_bad_cache",
                        "--global-cache-dir",
                        "/dev/null/rules_zig_bad_global_cache",
                        "--first",
                    ],
                    "requestId": 1,
                },
                separators=(",", ":"),
            ),
            json.dumps({"arguments": ["--second", "--fail"], "requestId": 2}, separators=(",", ":")),
            json.dumps({"arguments": [], "requestId": 3, "cancel": True}, separators=(",", ":")),
            "",
        ]
    )

    result = subprocess.run(
        [
            worker,
            "--persistent_worker",
            "--zig-exe",
            fake_zig,
            "--zig-version",
            "test-version",
            "build-exe",
        ],
        input=requests,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        cwd=workdir,
        env=env,
        check=False,
    )
    if result.returncode != 0:
        raise AssertionError(f"worker returned {result.returncode}: {result.stderr}")
    if result.stderr:
        raise AssertionError(f"worker wrote stderr: {result.stderr!r}")

    responses = [json.loads(line) for line in result.stdout.splitlines()]
    if len(responses) != 3:
        raise AssertionError(f"expected 3 responses, got {responses!r}")

    by_id = {response["requestId"]: response for response in responses}
    first = by_id[1]
    assert first["exitCode"] == 0, first
    assert_contains(first["output"], "fake stdout:")
    assert_contains(first["output"], "fake stderr:")

    second = by_id[2]
    assert second["exitCode"] == 12, second
    assert_contains(second["output"], "fake stdout:")
    assert_contains(second["output"], "fake stderr:")

    cancel = by_id[3]
    assert cancel["exitCode"] == 0, cancel
    assert cancel["wasCancelled"] is True, cancel

    invocations = pathlib.Path(env["FAKE_ZIG_LOG"]).read_text(encoding="utf-8").splitlines()
    if len(invocations) != 2:
        raise AssertionError(f"expected 2 fake zig invocations, got {invocations!r}")

    for invocation in invocations:
        assert invocation.startswith("build-exe "), invocation
        assert "/dev/null/rules_zig_bad_cache" not in invocation, invocation
        assert "/dev/null/rules_zig_bad_global_cache" not in invocation, invocation
        assert_contains(invocation, "--cache-dir bazel-out/rules_zig_worker_cache/test-version")
        assert_contains(invocation, "--global-cache-dir bazel-out/rules_zig_worker_cache/test-version")

    assert (workdir / "bazel-out/rules_zig_worker_cache/test-version/fake-zig-local-cache-entry").is_file()
    assert (workdir / "bazel-out/rules_zig_worker_cache/test-version/fake-zig-global-cache-entry").is_file()

    param_file = workdir / "oneshot.params"
    param_file.write_text("--oneshot\n", encoding="utf-8")
    oneshot = subprocess.run(
        [
            worker,
            "--zig-exe",
            fake_zig,
            "--zig-version",
            "test-version",
            "build-exe",
            f"@{param_file}",
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        cwd=workdir,
        env=env,
        check=False,
    )
    if oneshot.returncode != 0:
        raise AssertionError(f"one-shot worker returned {oneshot.returncode}: {oneshot.stderr}")
    if oneshot.stdout:
        raise AssertionError(f"one-shot worker wrote stdout: {oneshot.stdout!r}")
    assert_contains(oneshot.stderr, "fake stdout: build-exe --oneshot")
    assert_contains(oneshot.stderr, "fake stderr: build-exe --oneshot")

    all_invocations = pathlib.Path(env["FAKE_ZIG_LOG"]).read_text(encoding="utf-8")
    assert_contains(all_invocations, "--oneshot")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
