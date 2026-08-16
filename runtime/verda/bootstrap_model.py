"""Download and atomically persist the complete MiniCPM-o 4.5 snapshot."""

from __future__ import annotations

import os
import shutil
import time
import traceback
import uuid
from pathlib import Path

from huggingface_hub import snapshot_download


MODEL_REPO = os.environ.get("HF_MODEL_REPO", "openbmb/MiniCPM-o-4_5")
MODEL_DIR = Path(os.environ.get("MODEL_DIR", "/data/models/minicpm-o-4_5"))
MARKER = ".minicpm-o-4_5-ready"
LOCK_DIR = MODEL_DIR.parent / ".minicpm-o-4_5-download.lock"


def log(message: str) -> None:
    print(f"[minicpm-bootstrap {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}] {message}", flush=True)


def is_ready(path: Path) -> bool:
    # The snapshot may be sharded, hence a glob rather than one fixed filename.
    return (
        (path / MARKER).is_file()
        and (path / "config.json").is_file()
        and any(path.glob("*.safetensors"))
        and any((path / name).is_file() for name in ("tokenizer.json", "tokenizer.model"))
    )


def acquire_lock() -> None:
    while True:
        try:
            LOCK_DIR.mkdir()
            return
        except FileExistsError:
            if is_ready(MODEL_DIR):
                return
            log("another replica is downloading the model; waiting for its /data cache")
            time.sleep(5)


def main() -> None:
    MODEL_DIR.parent.mkdir(parents=True, exist_ok=True)
    if is_ready(MODEL_DIR):
        log(f"complete cache ready at {MODEL_DIR}; skipping Hugging Face download")
        return
    if not os.environ.get("HF_TOKEN"):
        raise RuntimeError("HF_TOKEN must be configured as a Verda secret before the first startup")

    acquire_lock()
    if is_ready(MODEL_DIR):
        log("cache became ready while waiting; skipping Hugging Face download")
        return

    staging = MODEL_DIR.parent / f".minicpm-o-4_5-staging-{uuid.uuid4().hex}"
    try:
        log(f"downloading the complete model snapshot from {MODEL_REPO}")
        snapshot_download(repo_id=MODEL_REPO, local_dir=staging, token=os.environ["HF_TOKEN"])
        if not (staging / "config.json").is_file() or not any(staging.glob("*.safetensors")):
            raise RuntimeError("incomplete MiniCPM-o 4.5 snapshot: config.json and safetensors are required")
        if not any((staging / name).is_file() for name in ("tokenizer.json", "tokenizer.model")):
            raise RuntimeError("incomplete MiniCPM-o 4.5 snapshot: tokenizer files are required")
        (staging / MARKER).write_text("ready\n", encoding="utf-8")
        if MODEL_DIR.exists():
            shutil.rmtree(MODEL_DIR)
        staging.replace(MODEL_DIR)
        log(f"complete cache committed atomically at {MODEL_DIR}")
    except Exception:
        log(f"bootstrap failed:\n{traceback.format_exc()}")
        raise
    finally:
        shutil.rmtree(staging, ignore_errors=True)
        shutil.rmtree(LOCK_DIR, ignore_errors=True)


if __name__ == "__main__":
    main()
