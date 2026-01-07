"""Model information utilities for Modelr.

Provides unified model size querying via HuggingFace Hub API.
"""

import sys
import json
from typing import Dict, Optional, Tuple

# Model definitions with repo info and fallback sizes
MODELS = {
    "hunyuan-mini": {
        "repo_id": "tencent/Hunyuan3D-2mini",
        "subfolder": "hunyuan3d-dit-v2-mini",
        "files": ["model.safetensors"],
        "fallback_bytes": 3_800_000_000,  # ~3.8 GB
    },
    "hunyuan-std": {
        "repo_id": "tencent/Hunyuan3D-2.1",
        "subfolder": "hunyuan3d-dit-v2-1",
        "files": ["model.fp16.safetensors"],
        "fallback_bytes": 7_400_000_000,  # ~7.4 GB
    },
    "sam3": {
        "repo_id": "mlx-community/sam3-image",
        "subfolder": None,
        "files": ["model.safetensors"],
        "fallback_bytes": 3_000_000_000,  # ~3 GB
    },
}


def get_repo_file_sizes(repo_id: str, subfolder: Optional[str] = None, files: Optional[list] = None) -> Tuple[int, Dict[str, int]]:
    """Query file sizes from HuggingFace Hub API.

    Args:
        repo_id: HuggingFace repository ID (e.g., "tencent/Hunyuan3D-2mini")
        subfolder: Optional subfolder within the repo
        files: Optional list of specific files to query; if None, queries all files

    Returns:
        Tuple of (total_size_bytes, dict of filename -> size)
    """
    try:
        from huggingface_hub import HfApi

        api = HfApi()

        # Get repo info which includes file sizes
        repo_info = api.repo_info(repo_id, files_metadata=True)

        file_sizes = {}
        total_size = 0

        for sibling in repo_info.siblings:
            file_path = sibling.rfilename
            file_size = sibling.size

            if file_size is None:
                continue

            # Filter by subfolder if specified
            if subfolder:
                if not file_path.startswith(f"{subfolder}/"):
                    continue

            # Filter by specific files if specified
            if files:
                filename = file_path.split("/")[-1]
                if subfolder:
                    target_path = f"{subfolder}/{filename}"
                    if file_path not in [f"{subfolder}/{f}" for f in files] and filename not in files:
                        continue
                else:
                    if filename not in files and file_path not in files:
                        continue

            file_sizes[file_path] = file_size
            total_size += file_size

        return total_size, file_sizes

    except Exception as e:
        print(f"Error querying HuggingFace Hub: {e}", file=sys.stderr)
        return 0, {}


def get_model_size(model_key: str, use_fallback: bool = True) -> int:
    """Get the download size for a model in bytes by querying HuggingFace Hub.

    Args:
        model_key: One of "hunyuan-mini", "hunyuan-std", "sam3"
        use_fallback: If True, return fallback size when query fails

    Returns:
        Size in bytes from HuggingFace, or fallback size, or 0 if unknown
    """
    if model_key not in MODELS:
        return 0

    config = MODELS[model_key]
    total_size, _ = get_repo_file_sizes(
        config["repo_id"],
        config.get("subfolder"),
        config.get("files")
    )

    # Use fallback if query returned 0
    if total_size == 0 and use_fallback:
        total_size = config.get("fallback_bytes", 0)

    return total_size


def get_model_size_formatted(model_key: str) -> str:
    """Get a human-readable size string for a model.

    Args:
        model_key: One of "hunyuan-mini", "hunyuan-std", "sam3"

    Returns:
        Formatted string like "~3.8 GB"
    """
    size_bytes = get_model_size(model_key)
    if size_bytes == 0:
        return "Unknown"

    size_gb = size_bytes / (1024 ** 3)
    if size_gb >= 1.0:
        return f"~{size_gb:.1f} GB"
    else:
        size_mb = size_bytes / (1024 ** 2)
        return f"~{size_mb:.0f} MB"


def get_all_model_sizes() -> Dict[str, Dict[str, any]]:
    """Get sizes for all known models.

    Returns:
        Dict mapping model_key to {"bytes": int, "formatted": str}
    """
    result = {}
    for model_key in MODELS:
        size_bytes = get_model_size(model_key)
        result[model_key] = {
            "bytes": size_bytes,
            "formatted": get_model_size_formatted(model_key),
        }
    return result


def main():
    """CLI entry point for querying model sizes."""
    import sys
    import argparse

    parser = argparse.ArgumentParser(description="Query model sizes from HuggingFace Hub")
    parser.add_argument("--model", choices=list(MODELS.keys()) + ["all"], default="all",
                       help="Model to query (default: all)")
    parser.add_argument("--json", action="store_true", help="Output as JSON")

    args = parser.parse_args()

    if args.model == "all":
        sizes = get_all_model_sizes()
        if args.json:
            print(json.dumps(sizes))
        else:
            for model_key, info in sizes.items():
                print(f"{model_key}: {info['formatted']} ({info['bytes']} bytes)")
    else:
        size_bytes = get_model_size(args.model)
        formatted = get_model_size_formatted(args.model)
        if args.json:
            print(json.dumps({"bytes": size_bytes, "formatted": formatted}))
        else:
            print(f"{args.model}: {formatted} ({size_bytes} bytes)")


if __name__ == "__main__":
    main()
