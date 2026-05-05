#!/usr/bin/env python3
import os
import pathlib
import sys


def main() -> int:
    log_path = os.environ["FAKE_ZIG_LOG"]
    argv = sys.argv[1:]
    pathlib.Path(log_path).parent.mkdir(parents=True, exist_ok=True)
    with open(log_path, "a", encoding="utf-8") as log:
        log.write(
            " ".join(argv)
            + f" ZIG_LOCAL_CACHE_DIR={os.environ.get('ZIG_LOCAL_CACHE_DIR', '')}"
            + f" ZIG_GLOBAL_CACHE_DIR={os.environ.get('ZIG_GLOBAL_CACHE_DIR', '')}"
            + "\n"
        )

    cache_dir = None
    global_cache_dir = None
    fail = False
    for index, arg in enumerate(argv):
        if arg == "--cache-dir" and index + 1 < len(argv):
            cache_dir = argv[index + 1]
        elif arg == "--global-cache-dir" and index + 1 < len(argv):
            global_cache_dir = argv[index + 1]
        elif arg == "--fail":
            fail = True

    if cache_dir:
        pathlib.Path(cache_dir).mkdir(parents=True, exist_ok=True)
        pathlib.Path(cache_dir, "fake-zig-local-cache-entry").write_text(" ".join(argv), encoding="utf-8")

    if global_cache_dir:
        pathlib.Path(global_cache_dir).mkdir(parents=True, exist_ok=True)
        pathlib.Path(global_cache_dir, "fake-zig-global-cache-entry").write_text(" ".join(argv), encoding="utf-8")

    print(f"fake stdout: {' '.join(argv)}")
    print(f"fake stderr: {' '.join(argv)}", file=sys.stderr)
    return 12 if fail else 0


if __name__ == "__main__":
    raise SystemExit(main())
