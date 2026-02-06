#!/usr/bin/env python3
"""
Simple streaming model downloader with real-time JSON progress.
Direct HTTPS downloads - no hf_hub dependency.

All models download to: ~/Library/Application Support/Modelr/models/{model_name}/
"""

import json
import hashlib
import os
import sys
import time
from pathlib import Path
from typing import Optional, List, Union
from dataclasses import dataclass, field

import requests

# Force unbuffered output
os.environ["PYTHONUNBUFFERED"] = "1"


@dataclass
class FileConfig:
    """Single file to download."""
    filename: str
    sha256: Optional[str] = None  # None = skip verification (for small config files)
    subfolder: Optional[str] = None
    min_size_bytes: Optional[int] = None  # Minimum expected size for integrity check


@dataclass
class ModelConfig:
    """Model configuration - can have one or multiple files."""
    repo_id: str
    revision: str
    out_dir: str  # Output directory name under models/
    files: List[FileConfig] = field(default_factory=list)

    # For single-file models (backwards compat)
    filename: Optional[str] = None
    subfolder: Optional[str] = None
    sha256: Optional[str] = None

    def get_files(self) -> List[FileConfig]:
        """Get list of files to download."""
        if self.files:
            return self.files
        # Single file mode
        return [FileConfig(
            filename=self.filename,
            sha256=self.sha256,
            subfolder=self.subfolder
        )]

    def get_url(self, file: FileConfig) -> str:
        """Get download URL for a file.

        Raises:
            ValueError: If subfolder or filename contains path traversal attempts.
        """
        # Validate inputs to prevent path traversal attacks
        def validate_path_component(component: str, field_name: str) -> None:
            if not component:
                return
            # Reject path traversal attempts
            if ".." in component:
                raise ValueError(f"{field_name} contains invalid path traversal: {component}")
            # Reject absolute paths (starting with / or drive letters like C:)
            if component.startswith("/") or (len(component) >= 2 and component[1] == ":"):
                raise ValueError(f"{field_name} cannot be an absolute path: {component}")
            # Reject other suspicious patterns
            if component.startswith("~"):
                raise ValueError(f"{field_name} cannot start with ~: {component}")

        validate_path_component(file.subfolder, "subfolder")
        validate_path_component(file.filename, "filename")

        base = f"https://huggingface.co/{self.repo_id}/resolve/{self.revision}"
        if file.subfolder:
            return f"{base}/{file.subfolder}/{file.filename}"
        return f"{base}/{file.filename}"


# VLM revision (pin to specific commit for reproducibility)
VLM_REVISION = "main"
VLM_REPO = "mlx-community/Qwen3-VL-2B-Instruct-4bit"

MODELS = {
    # SAM - single file
    "sam3": ModelConfig(
        repo_id="mlx-community/sam3-image",
        revision="b72a14d8127e17e6f2a3d2e075bbbf4307ba146e",
        out_dir="sam3",
        filename="model.safetensors",
        sha256="0ad4c3f42ecf706c4cda63cf58d621699491ed65012b3999284ea370984f7173",
    ),

    # Hunyuan Mini - model weights + config
    # SHA256 checksums pinned to specific revision for integrity verification
    "hunyuan-2mini": ModelConfig(
        repo_id="tencent/Hunyuan3D-2mini",
        revision="f90a0f7df7d5e6f71109cf333f6a95a0ae3194a6",
        out_dir="hunyuan-2mini",
        files=[
            FileConfig(
                filename="model.fp16.safetensors",
                subfolder="hunyuan3d-dit-v2-mini",
                # SHA256 for revision f90a0f7df7d5e6f71109cf333f6a95a0ae3194a6
                sha256="3cc66f3bea33e4062b7dbc875ffe1d70c4888914aec3e91b60f94e9bd01b522b",
                min_size_bytes=3_800_000_000,  # ~3.8 GB
            ),
            FileConfig(filename="config.yaml", subfolder="hunyuan3d-dit-v2-mini"),
        ],
    ),

    # VLM - multiple files required for mlx_vlm.load()
    "vlm": ModelConfig(
        repo_id=VLM_REPO,
        revision=VLM_REVISION,
        out_dir="vlm",
        files=[
            # Main model weights (~1.78 GB)
            FileConfig(filename="model.safetensors"),
            # Config files (small, no sha256 needed)
            FileConfig(filename="config.json"),
            FileConfig(filename="generation_config.json"),
            FileConfig(filename="preprocessor_config.json"),
            # Tokenizer files
            FileConfig(filename="tokenizer.json"),
            FileConfig(filename="tokenizer_config.json"),
            FileConfig(filename="special_tokens_map.json"),
            FileConfig(filename="added_tokens.json"),
            FileConfig(filename="vocab.json"),
            FileConfig(filename="merges.txt"),
            # Chat template
            FileConfig(filename="chat_template.jinja"),
        ],
    ),
}


def emit(stage: str, **kwargs):
    print(json.dumps({"stage": stage, "ts": time.time(), **kwargs}), flush=True)


def get_models_dir() -> Path:
    """Get the models directory, respecting MODELR_MODELS_DIR env var."""
    if "MODELR_MODELS_DIR" in os.environ:
        p = Path(os.environ["MODELR_MODELS_DIR"])
    else:
        p = Path.home() / "Library" / "Application Support" / "Modelr" / "models"
    p.mkdir(parents=True, exist_ok=True)
    return p


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def download_file(
    url: str,
    out_path: Path,
    model_key: str,
    expected_sha256: Optional[str] = None,
    min_size_bytes: Optional[int] = None,
    force: bool = False
) -> bool:
    """Download a single file with resume support and verification.

    Args:
        url: Download URL
        out_path: Destination path
        model_key: Model identifier for logging
        expected_sha256: Optional SHA256 checksum for verification
        min_size_bytes: Optional minimum file size for integrity check
        force: Force re-download even if cached

    Returns:
        True if downloaded, False if cached
    """
    partial = out_path.parent / f"{out_path.name}.partial"

    # Check existing file
    if out_path.exists() and not force:
        file_size = out_path.stat().st_size

        # Check minimum size if specified
        if min_size_bytes and file_size < min_size_bytes:
            emit("warning", message=f"{out_path.name} too small ({file_size} < {min_size_bytes}), re-downloading")
            out_path.unlink()
        elif expected_sha256:
            # Verify SHA256 if provided
            if sha256_file(out_path) == expected_sha256:
                return False  # Cached and verified
            emit("warning", message=f"{out_path.name} SHA256 mismatch, re-downloading")
            out_path.unlink()
        else:
            return False  # No verification needed, assume OK

    # Get size
    try:
        head = requests.head(url, allow_redirects=True, timeout=15)
        head.raise_for_status()
        total = int(head.headers.get("Content-Length", 0))
    except Exception as e:
        emit("error", message=f"HEAD failed for {out_path.name}: {e}")
        raise

    # Resume support
    resume_from = 0
    if partial.exists():
        resume_from = partial.stat().st_size
        if resume_from >= total:
            partial.unlink()
            resume_from = 0

    headers = {"User-Agent": "Modelr/3.0"}
    if resume_from > 0:
        headers["Range"] = f"bytes={resume_from}-"

    # Download with streaming
    try:
        resp = requests.get(url, headers=headers, stream=True, timeout=30)
        resp.raise_for_status()

        mode = "ab" if resume_from > 0 and resp.status_code == 206 else "wb"
        if mode == "wb":
            resume_from = 0

        current = resume_from
        last_emit = time.time()
        samples = []

        with open(partial, mode) as f:
            for chunk in resp.iter_content(chunk_size=512 * 1024):
                if chunk:
                    f.write(chunk)
                    current += len(chunk)
                    now = time.time()

                    samples.append((now, len(chunk)))
                    samples = [(t, b) for t, b in samples if now - t < 3.0]

                    if now - last_emit >= 0.15 and total > 1_000_000:  # Only emit for large files
                        if len(samples) >= 2:
                            dt = samples[-1][0] - samples[0][0]
                            db = sum(b for _, b in samples)
                            speed = int(db / dt) if dt > 0 else 0
                        else:
                            speed = 0

                        remaining = total - current
                        eta = int(remaining / speed) if speed > 0 else -1

                        emit(
                            "downloading",
                            model=model_key,
                            file=out_path.name,
                            current_bytes=current,
                            total_bytes=total,
                            speed_bps=speed,
                            eta_seconds=eta,
                            progress=current / total if total > 0 else 0
                        )
                        last_emit = now

    except Exception as e:
        emit("error", message=f"Download failed for {out_path.name}: {e}")
        raise

    # Verify minimum size if specified
    if min_size_bytes:
        actual_size = partial.stat().st_size
        if actual_size < min_size_bytes:
            partial.unlink()
            emit("error", message=f"File too small for {out_path.name}: {actual_size} < {min_size_bytes}")
            raise ValueError(f"File too small: {out_path.name} ({actual_size} < {min_size_bytes} bytes)")

    # Verify SHA256 if provided
    if expected_sha256:
        if sha256_file(partial) != expected_sha256:
            partial.unlink()
            emit("error", message=f"SHA256 mismatch for {out_path.name}")
            raise ValueError(f"SHA256 mismatch: {out_path.name}")

    # Move to final
    partial.rename(out_path)
    return True


def download_model(model_key: str, force: bool = False) -> Path:
    """Download all files for a model, preserving subfolder structure."""
    if model_key not in MODELS:
        emit("error", message=f"Unknown model: {model_key}")
        raise ValueError(f"Unknown: {model_key}")

    config = MODELS[model_key]
    out_dir = get_models_dir() / config.out_dir
    out_dir.mkdir(exist_ok=True)

    emit("checking", model=model_key)

    files = config.get_files()
    downloaded_any = False

    for file in files:
        url = config.get_url(file)
        # Preserve subfolder structure if specified
        if file.subfolder:
            file_out_dir = out_dir / file.subfolder
            file_out_dir.mkdir(parents=True, exist_ok=True)
            out_path = file_out_dir / file.filename
        else:
            out_path = out_dir / file.filename

        try:
            was_downloaded = download_file(
                url=url,
                out_path=out_path,
                model_key=model_key,
                expected_sha256=file.sha256,
                min_size_bytes=file.min_size_bytes,
                force=force
            )
            if was_downloaded:
                downloaded_any = True
        except Exception as e:
            emit("error", message=f"Failed to download {file.filename}: {e}")
            raise

    if downloaded_any:
        emit("complete", model=model_key, path=str(out_dir), cached=False)
    else:
        emit("complete", model=model_key, path=str(out_dir), cached=True)

    return out_dir


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Modelr Model Downloader")
    parser.add_argument("command", choices=["download", "verify", "list"])
    parser.add_argument("--model", "-m", help="Specific model to download/verify")
    parser.add_argument("--force", "-f", action="store_true", help="Force re-download")
    args = parser.parse_args()

    if args.command == "list":
        print("Available models:")
        for k, c in MODELS.items():
            files = c.get_files()
            print(f"  {k}: {len(files)} file(s) -> models/{c.out_dir}/")
            for f in files:
                print(f"    - {f.filename}")
        sys.exit(0)

    if args.command == "verify":
        models_to_check = [args.model] if args.model else list(MODELS.keys())
        all_ok = True

        for k in models_to_check:
            if k not in MODELS:
                print(f"{k}: UNKNOWN MODEL")
                all_ok = False
                continue

            c = MODELS[k]
            model_dir = get_models_dir() / c.out_dir
            files = c.get_files()
            model_ok = True

            for f in files:
                # Handle subfolder structure
                if f.subfolder:
                    p = model_dir / f.subfolder / f.filename
                else:
                    p = model_dir / f.filename

                if not p.exists():
                    print(f"{k}/{f.filename}: NOT FOUND")
                    model_ok = False
                else:
                    file_size = p.stat().st_size
                    # Check minimum size first
                    if f.min_size_bytes and file_size < f.min_size_bytes:
                        print(f"{k}/{f.filename}: TOO SMALL ({file_size} < {f.min_size_bytes} bytes)")
                        model_ok = False
                    # Then check SHA256 if provided
                    elif f.sha256 and sha256_file(p) != f.sha256:
                        print(f"{k}/{f.filename}: BAD CHECKSUM")
                        model_ok = False

            if model_ok:
                print(f"{k}: OK ({len(files)} files)")
            else:
                all_ok = False

        sys.exit(0 if all_ok else 1)

    if args.command == "download":
        try:
            models_to_download = [args.model] if args.model else list(MODELS.keys())
            for k in models_to_download:
                download_model(k, force=args.force)
        except Exception as e:
            print(f"Error: {e}", file=sys.stderr)
            sys.exit(1)
