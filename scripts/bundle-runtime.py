#!/usr/bin/env python3
"""Assemble a relocatable, offline Python + MLX + model runtime for the DMG.

Run on the Apple Silicon build Mac after scripts/setup-runtime.sh. The existing
runtime is read only. No virtualenv, account paths, audio, caches or signing keys
are copied. Build output goes to an explicitly chosen, previously absent folder.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys

MODEL_REPOSITORY = "aystream/GigaAM-v3-e2e-rnnt-mlx"
MODEL_REVISION = "decfca492069ea30fb5ead79c4516d50c16d93ea"
PACKAGE_REVISION = "20276ddd6173d636b37c6c6e13b4ee8f7b94d1ac"
MODEL_FILES = ("config.json", "tokenizer.model", "weights.safetensors", "README.md")
MACHO_MAGIC = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}


def run(arguments, **kwargs):
    return subprocess.run(arguments, check=True, text=True, capture_output=True, **kwargs)


def sha256(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def ignored(directory, names):
    return [name for name in names if name in {"__pycache__", ".cache", ".DS_Store", "uv_build.json"}
            or name.endswith((".pyc", ".pyo", ".nbc", ".nbi"))]


def check_links(source: Path) -> None:
    for item in source.rglob("*"):
        if item.is_symlink():
            try:
                item.resolve(strict=True).relative_to(source)
            except (OSError, ValueError):
                raise RuntimeError(f"Source contains an external or broken symlink: {item.name}") from None


def inspect_macho(root: Path):
    maximum = (0, 0)
    libraries = []
    for path in sorted(root.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open("rb") as stream:
            if stream.read(4) not in MACHO_MAGIC:
                continue
        relative = str(path.relative_to(root))
        architectures = run(["/usr/bin/lipo", "-archs", str(path)]).stdout.split()
        if "arm64" not in architectures:
            raise RuntimeError(f"Native library does not support arm64: {relative}")
        output = run(["/usr/bin/otool", "-arch", "arm64", "-l", str(path)]).stdout
        versions = re.findall(r"\bminos\s+([0-9.]+)", output)
        versions += re.findall(r"cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version ([0-9.]+)", output)
        minimum = max((tuple(map(int, version.split("."))) for version in versions), default=(0, 0))
        maximum = max(maximum, minimum)
        # otool -L includes a dylib's own LC_ID_DYLIB entry. Its build-time name
        # is not a dependency; every actual dependency must still be portable.
        own_ids = set(re.findall(r"cmd LC_ID_DYLIB\s+cmdsize \d+\s+name (.*?) \(offset \d+\)", output))
        if any(value.startswith("/") for value in own_ids):
            # uv rewrites standalone libpython's own ID to the install location.
            # Give copied dylibs a location-independent ID before release signing.
            run(["/usr/bin/install_name_tool", "-id", "@rpath/" + path.name, str(path)])
            # arm64 requires valid signatures even for the pre-release smoke test.
            # The release builder subsequently replaces these with its real identity.
            run(["/usr/bin/codesign", "--force", "--sign", "-", str(path)])
            own_ids = {"@rpath/" + path.name}
        dependencies = run(["/usr/bin/otool", "-arch", "arm64", "-L", str(path)]).stdout.splitlines()[1:]
        for line in dependencies:
            if not line.startswith("\t"):
                continue
            dependency = line.strip().split(" (", 1)[0]
            if dependency in own_ids:
                continue
            if dependency.startswith("/") and not dependency.startswith(("/usr/lib/", "/System/Library/")):
                raise RuntimeError(f"Native library has a non-system absolute dependency: {relative}")
        libraries.append({"path": relative, "minimum_macos": ".".join(map(str, minimum))})
    return ".".join(map(str, maximum)), libraries


def assert_no_private_paths(root: Path, source: Path) -> None:
    # Bytecode is removed rather than shipped with build-time co_filename paths.
    markers = {str(Path.home()).encode(), str(source).encode()}
    markers = {value for value in markers if len(value) > 5}
    overlap = max(map(len, markers), default=1) - 1
    for path in root.rglob("*"):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open("rb") as stream:
            previous = b""
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                data = previous + block
                if any(marker in data for marker in markers):
                    raise RuntimeError(f"A build-machine path remains in {path.relative_to(root)}")
                previous = data[-overlap:] if overlap else b""


def assemble(source: Path, destination: Path, licenses: Path) -> None:
    if sys.platform != "darwin" or platform.machine() != "arm64":
        raise RuntimeError("Build the runtime on a native Apple Silicon Mac.")
    source = source.resolve(strict=True)
    destination = destination.absolute()
    if destination.exists() or destination.is_symlink():
        raise RuntimeError("Destination already exists; choose a fresh build directory.")
    venv_python = source / ".venv/bin/python"
    facts = json.loads(run([str(venv_python), "-I", "-c",
        "import json,sys,sysconfig,platform,importlib.metadata as m; "
        "print(json.dumps(dict(base=sys.base_prefix,version=platform.python_version(),"
        "arch=platform.machine(),packages=sysconfig.get_path('purelib'),"
        "distributions={d.metadata['Name']:d.version for d in m.distributions()})))"]).stdout)
    if not facts["version"].startswith("3.11.") or facts["arch"] != "arm64":
        raise RuntimeError("Expected an arm64 Python 3.11 build environment.")
    base = Path(facts["base"]).resolve(strict=True)
    packages = Path(facts["packages"]).resolve(strict=True)
    if facts["version"] != "3.11.18" or not (base / "BUILD").is_file() or (base / "BUILD").read_text().strip() != "20261026":
        raise RuntimeError("Release packaging requires python-build-standalone 3.11.18, build 20261026, matching the bundled notices.")
    package_origin = json.loads((packages / "gigaam_mlx-0.1.0.dist-info/direct_url.json").read_text())
    if package_origin.get("vcs_info", {}).get("commit_id") != PACKAGE_REVISION:
        raise RuntimeError("The installed gigaam-mlx commit differs from the release pin.")
    lock = Path(__file__).resolve().parents[1] / "requirements.lock.txt"
    normalized = {re.sub(r"[-_.]+", "-", name).lower(): version for name, version in facts["distributions"].items()}
    for line in lock.read_text().splitlines():
        if "==" in line:
            name, expected = line.strip().split("==", 1)
            if normalized.get(re.sub(r"[-_.]+", "-", name).lower()) != expected:
                raise RuntimeError(f"Installed version differs from the lock file: {name}")
    check_links(base)
    check_links(packages)
    if not licenses.is_dir() or not (licenses / "GigaAM-MIT.txt").is_file():
        raise RuntimeError("The redistribution notices directory is missing.")
    destination.mkdir(parents=True)
    python = destination / "python"
    (python / "bin").mkdir(parents=True)
    shutil.copy2(base / "bin/python3.11", python / "bin/python3.11")
    (python / "bin/python3").symlink_to("python3.11")
    (python / "bin/python").symlink_to("python3.11")
    shutil.copytree(base / "lib", python / "lib", ignore=ignored, symlinks=False)
    target_packages = python / "lib/python3.11/site-packages"
    if target_packages.exists():
        shutil.rmtree(target_packages)
    shutil.copytree(packages, target_packages, ignore=ignored, symlinks=False)
    # uv relocates Python's build-time configuration alongside libpython's ID.
    # Keep sysconfig usable after another move without publishing that prefix.
    for path in (python / "lib/python3.11").glob("_sysconfigdata*.py"):
        configuration = path.read_text()
        for prefix in sorted({str(base), facts["base"]}, key=len, reverse=True):
            configuration = configuration.replace(prefix, "__GIGAFLOW_PYTHON_PREFIX__")
        configuration += ("\n# Resolve relocated build variables from the embedded interpreter.\n"
                          "import sys as _gigaflow_sys\n"
                          "build_time_vars = {key: value.replace('__GIGAFLOW_PYTHON_PREFIX__', _gigaflow_sys.base_prefix) "
                          "if isinstance(value, str) else value for key, value in build_time_vars.items()}\n"
                          "del _gigaflow_sys\n")
        path.write_text(configuration)
    # Development configuration is unnecessary and may contain rewritten prefixes.
    shutil.rmtree(python / "lib/pkgconfig", ignore_errors=True)
    for path in (python / "lib/python3.11").glob("config-*"):
        if path.is_dir():
            shutil.rmtree(path)
    model = destination / "models/gigaam-v3-e2e-rnnt-mlx"
    model.mkdir(parents=True)
    model_facts = {}
    for name in MODEL_FILES:
        original = source / "models/gigaam-v3-e2e-rnnt-mlx" / name
        if name == "README.md" and not original.exists():
            original = licenses / "GigaAM-model-card.md"
        if not original.is_file() or original.is_symlink():
            raise RuntimeError(f"Model file missing or unsafe: {name}")
        shutil.copy2(original, model / name)
        model_facts[name] = {"bytes": original.stat().st_size, "sha256": sha256(original)}
    shutil.copytree(licenses, destination / "Licenses")
    shutil.copy2(python / "lib/python3.11/LICENSE.txt", destination / "Licenses/CPython-LICENSE.txt")
    shutil.copy2(licenses / "GigaAM-MIT.txt", model / "LICENSE")
    minimum, native_files = inspect_macho(python)
    assert_no_private_paths(destination, source)
    manifest = {"schema": 1, "python": facts["version"], "architecture": "arm64",
                "minimum_macos": minimum, "requirements_sha256": sha256(lock),
                "packages": facts["distributions"], "model_repository": MODEL_REPOSITORY,
                "model_revision": MODEL_REVISION, "model_files": model_facts,
                "native_files": native_files}
    (destination / "runtime-manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"runtime": str(destination), "python": facts["version"],
                      "minimum_macos": minimum, "native_files": len(native_files),
                      "bytes": sum(path.stat().st_size for path in destination.rglob("*") if path.is_file())}))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path.home() / "Developer/gigaam-pilot")
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--licenses", type=Path, default=Path(__file__).resolve().parent / "runtime-licenses")
    args = parser.parse_args()
    try:
        assemble(args.source, args.destination, args.licenses)
    except Exception as error:
        print(f"Runtime bundle failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
