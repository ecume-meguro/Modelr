#!/usr/bin/env python3
"""
Clean model downloader - bypasses HuggingFace Hub's proprietary directory structure.
Stores models in a simple, flat structure: ~/Library/Application Support/ModelrV3/models/
"""

import os
import sys
import hashlib
from pathlib import Path
from typing import Optional, Tuple
from huggingface_hub import hf_hub_download

# Model configurations: (repo_id, filename, subfolder, expected_sha256, commit)
MODELS = {
    "hunyuan-2mini": {
        "repo_id": "tencent/Hunyuan3D-2mini",
        "filename": "model.safetensors",
        "subfolder": "hunyuan3d-dit-v2-mini",
        "sha256": "2bc48c8168874bb3f3d9bb6699af40517e498d2da3400c9c54dc0f5779875ab3",
        "commit": "26f3c45873c7fdab278571c419ce577e57c27fac",
    },
    "hunyuan-2.1": {
        "repo_id": "tencent/Hunyuan3D-2.1",
        "filename": "model.fp16.safetensors",
        "subfolder": "hunyuan3d-dit-v2-1",
        "sha256": "6b519fc7242f78e9b5f47ea4d55668fe3d944a2d27332f4ca68d29a6ff603f5e",
        "commit": "07d6dc9694e0ea942683bf6e3e374887d9f5b054",
    },
    "sam3": {
        "repo_id": "mlx-community/sam3-image",
        "filename": "model.safetensors",
        "subfolder": None,
        "sha256": "0ad4c3f42ecf706c4cda63cf58d621699491ed65012b3999284ea370984f7173",
        "commit": "b72a14d8127e17e6f2a3d2e075bbbf4307ba146e",
    },
}


def get_models_dir() -> Path:
    """Get the clean models directory."""
    models_dir = Path.home() / "Library" / "Application Support" / "ModelrV3" / "models"
    models_dir.mkdir(parents=True, exist_ok=True)
    return models_dir


def compute_sha256(filepath: Path) -> str:
    """Compute SHA256 hash of a file."""
    sha256 = hashlib.sha256()
    with open(filepath, "rb") as f:
        for chunk in iter(lambda: f.read(4096), b""):
            sha256.update(chunk)
    return sha256.hexdigest()


def download_model(model_key: str, force: bool = False) -> Path:
    """
    Download a model using exact commit SHA.
    Stores in clean directory structure: models/{model_key}/{filename}
    Returns the path to the downloaded model.
    """
    if model_key not in MODELS:
        raise ValueError(f"Unknown model: {model_key}")

    config = MODELS[model_key]
    models_dir = get_models_dir()
    model_dir = models_dir / model_key
    model_dir.mkdir(exist_ok=True)

    output_path = model_dir / config["filename"]

    # Skip if already downloaded and valid
    if output_path.exists() and not force:
        existing_sha = compute_sha256(output_path)
        if existing_sha == config["sha256"]:
            print(f"✓ {model_key} already exists and is valid")
            return output_path
        else:
            print(f"✗ {model_key} exists but SHA mismatch (expected {config['sha256']}, got {existing_sha})")
            output_path.unlink()

    print(f"Downloading {model_key}...")
    print(f"  Repo: {config['repo_id']}")
    print(f"  File: {config['filename']}")
    print(f"  Commit: {config['commit']}")

    # Download with specific commit
    downloaded_path = hf_hub_download(
        repo_id=config["repo_id"],
        filename=config["filename"],
        subfolder=config["subfolder"],
        revision=config["commit"],
        cache_dir=None,  # Don't use HF cache
        local_dir=str(model_dir),
        local_dir_use_symlinks=False,
    )

    # Verify SHA256
    downloaded_sha = compute_sha256(Path(downloaded_path))
    if downloaded_sha != config["sha256"]:
        raise ValueError(
            f"SHA256 mismatch for {model_key}!\n"
            f"  Expected: {config['sha256']}\n"
            f"  Got:      {downloaded_sha}"
        )

    print(f"✓ {model_key} downloaded and verified")
    return Path(downloaded_path)


def verify_all_models() -> Tuple[int, int]:
    """Verify all downloaded models. Returns (valid, invalid)."""
    models_dir = get_models_dir()
    valid = 0
    invalid = 0

    for model_key, config in MODELS.items():
        model_path = models_dir / model_key / config["filename"]
        if not model_path.exists():
            print(f"✗ {model_key}: NOT FOUND")
            invalid += 1
        else:
            sha = compute_sha256(model_path)
            if sha == config["sha256"]:
                print(f"✓ {model_key}: VALID")
                valid += 1
            else:
                print(f"✗ {model_key}: SHA MISMATCH")
                print(f"  Expected: {config['sha256']}")
                print(f"  Got:      {sha}")
                invalid += 1

    return valid, invalid


if __name__ == "__main__":
    if len(sys.argv) > 1:
        if sys.argv[1] == "verify":
            print("Verifying all models...")
            valid, invalid = verify_all_models()
            print(f"\nResult: {valid} valid, {invalid} invalid")
            sys.exit(0 if invalid == 0 else 1)
        elif sys.argv[1] == "download":
            model_key = sys.argv[2] if len(sys.argv) > 2 else None
            if model_key:
                try:
                    download_model(model_key)
                except Exception as e:
                    print(f"Error: {e}")
                    sys.exit(1)
            else:
                print("Usage: python model_downloader.py download <model_key>")
                print(f"Available models: {', '.join(MODELS.keys())}")
                sys.exit(1)
        else:
            print(f"Unknown command: {sys.argv[1]}")
            sys.exit(1)
    else:
        # Download all models
        print("Downloading all models...")
        models_dir = get_models_dir()
        print(f"Models directory: {models_dir}\n")

        for model_key in MODELS.keys():
            try:
                download_model(model_key)
            except Exception as e:
                print(f"Error downloading {model_key}: {e}")

        print("\nVerifying...")
        verify_all_models()
