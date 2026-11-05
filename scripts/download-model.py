#!/usr/bin/env python3
"""Download the pinned MLX model once; verify existing managed files on reruns.

This installer needs network access. The GigaFlow recognition worker itself runs
offline. Model weights are not part of the source repository.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile

REPOSITORY = "aystream/GigaAM-v3-e2e-rnnt-mlx"
REVISION = "decfca492069ea30fb5ead79c4516d50c16d93ea"
FILES = ("config.json", "tokenizer.model", "weights.safetensors")
MANIFEST = "gigaflow-model.json"
RUNTIME = Path.home() / "Developer/gigaam-pilot"


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def file_manifest(directory: Path) -> dict:
    result = {}
    for name in FILES:
        path = directory / name
        if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
            raise RuntimeError(f"Required model file is missing or unsafe: {name}")
        result[name] = {"bytes": path.stat().st_size, "sha256": digest(path)}
    return result


def verify(directory: Path) -> None:
    manifest = directory / MANIFEST
    if directory.is_symlink() or manifest.is_symlink() or not manifest.is_file():
        raise RuntimeError(
            "An existing model has no GigaFlow download manifest. It was not changed. "
            "If this is your working runtime, skip this download step."
        )
    data = json.loads(manifest.read_text(encoding="utf-8"))
    if data.get("repository") != REPOSITORY or data.get("revision") != REVISION:
        raise RuntimeError("Existing model revision differs; refusing to replace it.")
    if data.get("files") != file_manifest(directory):
        raise RuntimeError("Model verification failed; no files were changed.")


def install(verify_only: bool = False) -> None:
    destination = RUNTIME / "models/gigaam-v3-e2e-rnnt-mlx"
    if destination.exists() or destination.is_symlink():
        verify(destination)
        print(f"Verified model revision {REVISION} at {destination}")
        return
    if verify_only:
        raise RuntimeError("The model is not installed; run without --verify-only to download it.")

    # Import only on the download path: --verify-only requires just Python.
    os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
    from huggingface_hub import snapshot_download

    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".gigaflow-download-", dir=destination.parent) as temporary:
        staging = Path(temporary) / "model"
        snapshot_download(
            repo_id=REPOSITORY,
            revision=REVISION,
            local_dir=staging,
            allow_patterns=list(FILES),
            token=False,
        )
        record = {"repository": REPOSITORY, "revision": REVISION, "files": file_manifest(staging)}
        (staging / MANIFEST).write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
        # Download metadata is no longer needed once every file has been checked.
        shutil.rmtree(staging / ".cache", ignore_errors=True)
        if destination.exists() or destination.is_symlink():
            raise RuntimeError("A model appeared during download; refusing to replace it.")
        staging.rename(destination)
    print(f"Installed model revision {REVISION} at {destination}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify-only", action="store_true", help="Check files without network access")
    args = parser.parse_args()
    try:
        install(args.verify_only)
    except Exception as error:
        print(f"Model setup failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
