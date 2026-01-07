#!/usr/bin/env python3
"""
Hunyuan3D-2.1 Model Generation Wrapper for Modelr
===================================================
Refactored using common utilities for consistency.
"""

import os
import sys
import argparse
import time
import gc
from typing import Optional, Callable, Dict, Any, Tuple
from pathlib import Path

import torch
import numpy as np
from PIL import Image
from huggingface_hub import snapshot_download

from modelr_core import (
    get_logger,
    get_device,
    ModelConfig,
    log_info,
    log_error,
    log_debug,
    log_warning,
    load_image,
    extract_foreground,
    get_model_size_formatted,
)
from modelr_core.exceptions import (
    ModelLoadError,
    GenerationError,
)

logger = get_logger("hunyuan_wrapper")
HUNYUAN_CACHE_DIR = ModelConfig.get_hunyuan_cache_dir()

class HunyuanGenerator:
    """Manages Hunyuan3D model generation."""

    # Model variant mapping: variant -> (repo_id, subfolder, use_safetensors)
    VARIANT_MAP = {
        # Mini variants (all in same repo, different subfolders)
        "mini": ("tencent/Hunyuan3D-2mini", "hunyuan3d-dit-v2-mini", True),
        "mini-fast": ("tencent/Hunyuan3D-2mini", "hunyuan3d-dit-v2-mini-fast", True),
        "mini-turbo": ("tencent/Hunyuan3D-2mini", "hunyuan3d-dit-v2-mini-turbo", True),
        # Standard 2.1 model
        "std": ("tencent/Hunyuan3D-2.1", "hunyuan3d-dit-v2-1", True),
    }

    def __init__(self, model_variant: str = "std"):
        self.model_variant = model_variant
        self.pipeline = None
        self.device = get_device()

    def load(self):
        """Load the pipeline."""
        try:
            from hy3dgen.shapegen import Hunyuan3DDiTFlowMatchingPipeline

            log_info("Modelr hunyuan_wrapper: safetensors-only warmup enabled")

            repo_id, subfolder, use_safetensors = self.VARIANT_MAP.get(
                self.model_variant, self.VARIANT_MAP["std"]
            )
            log_info(f"Loading Hunyuan3D pipeline: {repo_id}/{subfolder}")

            # hy3dgen's loader expects `model_path` to be a repo_id (e.g. "tencent/Hunyuan3D-2mini")
            # and looks for a local mirror at: $HY3DGEN_MODELS/<repo_id>/<subfolder>/.
            # If that directory is missing it falls back to its own snapshot_download(...) which
            # downloads the entire subfolder (including both .ckpt and .safetensors) and can double
            # disk usage.
            # If HY3DGEN_MODELS was defaulted to the HF hub cache dir, redirect it to a sibling
            # directory to avoid polluting hub/ with hy3dgen's repo-id layout.
            configured_hy3dgen_models = os.environ.get("HY3DGEN_MODELS")
            inferred_hy3dgen_models = Path(HUNYUAN_CACHE_DIR).parent / "hy3dgen"
            if configured_hy3dgen_models and Path(configured_hy3dgen_models) != Path(HUNYUAN_CACHE_DIR):
                hy3dgen_models_dir = Path(configured_hy3dgen_models)
            else:
                hy3dgen_models_dir = inferred_hy3dgen_models
                os.environ["HY3DGEN_MODELS"] = str(hy3dgen_models_dir)
            hy3dgen_models_dir.mkdir(parents=True, exist_ok=True)

            # Prefetch only the files we need.
            # The upstream repos often publish both a .ckpt and a .safetensors with the same weights;
            # downloading both doubles disk usage.
            snapshot_path = snapshot_download(
                repo_id=repo_id,
                allow_patterns=[
                    f"{subfolder}/*.safetensors",
                    f"{subfolder}/*.json",
                    f"{subfolder}/*.yaml",
                    f"{subfolder}/*.yml",
                    f"{subfolder}/*.txt",
                ],
                ignore_patterns=[
                    f"{subfolder}/*.ckpt",
                    f"{subfolder}/*.ckpt.*",
                ],
                cache_dir=str(HUNYUAN_CACHE_DIR),
            )
            log_info(f"Using local snapshot: {snapshot_path}")

            # Materialize the exact local directory layout hy3dgen expects so it won't invoke its
            # own snapshot_download (which otherwise grabs both ckpt+safetensors).
            try:
                snapshot_dir = Path(snapshot_path)
                snapshot_weights_dir = snapshot_dir / subfolder
                hy3d_local_dir = hy3dgen_models_dir / repo_id / subfolder
                hy3d_local_dir.mkdir(parents=True, exist_ok=True)

                def link_into_local(name: str) -> None:
                    src = snapshot_weights_dir / name
                    if not src.exists() and not src.is_symlink():
                        return
                    try:
                        target = src.resolve(strict=False) if src.is_symlink() else src
                    except Exception:
                        target = src
                    dst = hy3d_local_dir / name
                    try:
                        if dst.exists() or dst.is_symlink():
                            dst.unlink()
                    except Exception:
                        pass
                    try:
                        dst.symlink_to(target)
                    except Exception:
                        # If symlinks aren't allowed for any reason, fall back to copying.
                        import shutil

                        shutil.copy2(target, dst)

                # Always include config, and all safetensors in the subfolder.
                link_into_local("config.yaml")
                for st in snapshot_weights_dir.glob("*.safetensors"):
                    link_into_local(st.name)
                for meta in snapshot_weights_dir.glob("*.json"):
                    link_into_local(meta.name)
                for meta in snapshot_weights_dir.glob("*.yml"):
                    link_into_local(meta.name)
                for meta in snapshot_weights_dir.glob("*.yaml"):
                    link_into_local(meta.name)
                for meta in snapshot_weights_dir.glob("*.txt"):
                    link_into_local(meta.name)
            except Exception as e:
                log_debug(f"Failed to stage hy3dgen local model dir: {e}")

            # Best-effort cleanup for users who previously downloaded both ckpt+safetensors.
            # If both exist, keep safetensors and prune ckpt to reclaim disk and avoid double downloads.
            try:
                snapshot_dir = Path(snapshot_path)
                repo_root = snapshot_dir.parent.parent  # .../models--X/snapshots/<hash>
                blobs_dir = repo_root / "blobs"
                weights_dir = snapshot_dir / subfolder

                if weights_dir.exists():
                    safetensors = list(weights_dir.glob("**/*.safetensors"))
                    ckpts = list(weights_dir.glob("**/*.ckpt")) + list(weights_dir.glob("**/*.ckpt.*"))
                    if safetensors and ckpts:
                        for ckpt in ckpts:
                            target_blob: Optional[Path] = None
                            if ckpt.is_symlink():
                                try:
                                    target_blob = ckpt.resolve(strict=False)
                                except Exception:
                                    target_blob = None

                            try:
                                ckpt.unlink(missing_ok=True)
                            except TypeError:
                                # Python < 3.8 compat (shouldn't happen in our env, but safe)
                                if ckpt.exists() or ckpt.is_symlink():
                                    ckpt.unlink()

                            if target_blob is not None:
                                try:
                                    # Only delete blobs inside this repo's blobs dir.
                                    if blobs_dir in target_blob.parents and target_blob.exists():
                                        target_blob.unlink()
                                except Exception:
                                    pass

                        log_info("Pruned cached .ckpt weights (keeping .safetensors)")
            except Exception as e:
                log_debug(f"Failed to prune ckpt weights: {e}")

            # IMPORTANT: hy3dgen expects `model_path` to be a repo_id; passing a local snapshot path
            # can cause it to call snapshot_download(repo_id=<local path>) which fails validation.
            self.pipeline = Hunyuan3DDiTFlowMatchingPipeline.from_pretrained(
                repo_id,
                subfolder=subfolder,
                device=self.device,
                use_safetensors=use_safetensors,
                variant="fp16",
            )
            return self.pipeline
        except Exception as e:
            raise ModelLoadError(f"Failed to load Hunyuan3D pipeline: {e}")

    def generate(
        self, 
        image: Image.Image, 
        output_path: str, 
        num_steps: int = 50, 
        octree_resolution: int = 384,
        progress_callback: Optional[Callable[[str, float], None]] = None
    ) -> str:
        """Generate 3D model."""
        if self.pipeline is None:
            self.load()
            
        try:
            if progress_callback:
                progress_callback("Generating 3D shape", 0.2)
                
            log_info(f"Generating 3D shape (steps={num_steps}, resolution={octree_resolution})...")
            
            with torch.inference_mode():
                mesh = self.pipeline(
                    image=image,
                    octree_resolution=octree_resolution,
                    num_inference_steps=num_steps,
                )[0]

            if progress_callback:
                progress_callback("Exporting model", 0.9)
                
            mesh.export(output_path)
            
            if progress_callback:
                progress_callback("Complete", 1.0)
                
            return output_path
        except Exception as e:
            raise GenerationError(f"Failed to generate 3D model: {e}")

    def cleanup(self):
        self.pipeline = None
        if torch.cuda.is_available():
            torch.cuda.empty_cache()
        gc.collect()

def main():
    parser = argparse.ArgumentParser(description="Hunyuan3D-2.1 Shape Generation Wrapper")
    parser.add_argument("--warmup", action="store_true", help="Pre-download model")
    parser.add_argument("--get-size", action="store_true", help="Query model download size")
    parser.add_argument(
        "--model",
        default="std",
        choices=["mini", "mini-fast", "mini-turbo", "std"],
        help="Model variant (mini, mini-fast, mini-turbo, or std)"
    )
    parser.add_argument("--image", help="Input image path")
    parser.add_argument("--mask", help="Mask image path")
    parser.add_argument("--output", help="Output path")
    parser.add_argument("--steps", type=int, default=50, help="Diffusion steps")
    parser.add_argument("--resolution", type=int, default=384, help="Octree resolution")

    args = parser.parse_args()

    if args.get_size:
        # Map model variant to model_info key
        model_key_map = {
            "mini": "hunyuan-mini",
            "mini-fast": "hunyuan-mini",  # Same repo, similar size
            "mini-turbo": "hunyuan-mini", # Same repo, similar size
            "std": "hunyuan-std",
        }
        model_key = model_key_map.get(args.model, "hunyuan-std")
        size_str = get_model_size_formatted(model_key)
        print(f"SIZE:{size_str}", flush=True)
        return

    if args.warmup:
        generator = HunyuanGenerator(args.model)
        generator.load()
        log_info("Warmup complete")
        return

    if args.image:
        # Load and process image
        image = load_image(args.image, convert_mode="RGBA")
        
        if args.mask and os.path.exists(args.mask):
            log_info(f"Applying mask: {args.mask}")
            mask_img = load_image(args.mask, convert_mode="L")
            image = extract_foreground(image, mask_img)
            
        output_path = args.output or "output_model.obj"
        
        generator = HunyuanGenerator(args.model)
        
        def progress_print(status, value):
            print(f"PROGRESS:{int(value*100)}% - {status}", flush=True)
            
        generator.generate(
            image=image,
            output_path=output_path,
            num_steps=args.steps,
            octree_resolution=args.resolution,
            progress_callback=progress_print
        )
        print(f"SUCCESS:{output_path}", flush=True)
    else:
        parser.print_help()

if __name__ == "__main__":
    main()