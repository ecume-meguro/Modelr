#!/usr/bin/env python3
"""
Hunyuan3D-2.1 Model Generation Wrapper for ModelrV3

Generates 3D models from masked images using Tencent's Hunyuan3D-2.1.
Supports self-test mode for validation during app startup.
Shape generation only (no texture/paint pipeline).
"""

import os
import sys
import argparse
import time
import gc
from typing import Optional, Callable
from pathlib import Path

import torch
import numpy as np
from PIL import Image

from modelrv3_core import (
    get_logger,
    validate_image_path,
    validate_output_dir,
    validate_mask_compatibility,
    get_device,
    check_gpu_available,
    health_check,
    ModelConfig,
    PerformanceConfig,
    metrics,
    log_info,
    log_error,
    log_debug,
    log_warning,
    load_image,
    extract_foreground,
)
from modelrv3_core.exceptions import (
    ModelLoadError,
    ImageValidationError,
    GenerationError,
    OutOfMemoryError,
)

logger = get_logger("hunyuan_wrapper")

APP_SUPPORT_DIR = str(ModelConfig.get_checkpoint_dir().parent)
HUNYUAN_CACHE_DIR = ModelConfig.get_hunyuan_cache_dir()


def load_pipeline(model_variant: str = "std", device: str = "mps"):
    """Load the Hunyuan3D-2.1 shape generation pipeline."""
    try:
        from hy3dgen.shapegen import Hunyuan3DDiTFlowMatchingPipeline

        repo_map = {
            "mini": ("tencent/Hunyuan3D-2mini", "hunyuan3d-dit-v2-mini", True),   # has safetensors
            "std": ("tencent/Hunyuan3D-2.1", "hunyuan3d-dit-v2-1", False),        # only has .ckpt
        }

        repo_id, subfolder, use_safetensors = repo_map.get(model_variant, repo_map["std"])

        log_info(f"Loading Hunyuan3D pipeline: {repo_id}/{subfolder}")

        pipeline = Hunyuan3DDiTFlowMatchingPipeline.from_pretrained(
            repo_id,
            subfolder=subfolder,
            device=device,
            use_safetensors=use_safetensors,
            cache_dir=str(HUNYUAN_CACHE_DIR),
        )

        log_info(f"Pipeline loaded successfully on {device}")
        return pipeline

    except RuntimeError as e:
        if "out of memory" in str(e).lower():
            raise OutOfMemoryError(f"GPU memory exhausted: {e}")
        raise ModelLoadError(f"Failed to load pipeline: {e}")
    except Exception as e:
        raise ModelLoadError(f"Unexpected error loading pipeline: {e}")


def extract_foreground_with_mask(
    image_path: str, mask_path: str, output_dir: Optional[str] = None
) -> Image.Image:
    """
    Extract foreground from image using a SAM2 mask.
    Uses centralized core utility.
    """
    try:
        validate_image_path(image_path)
        validate_image_path(mask_path)
        validate_mask_compatibility(image_path, mask_path)

        log_info(f"[Mask Debug] Image path: {image_path}")
        log_info(f"[Mask Debug] Mask path: {mask_path}")

        # Load image - preserve alpha if present
        image = Image.open(image_path)
        log_info(f"[Mask Debug] Image mode: {image.mode}, size: {image.size}")

        mask_img = Image.open(mask_path)
        log_info(f"[Mask Debug] Mask mode: {mask_img.mode}, size: {mask_img.size}")

        # Check mask statistics
        mask_gray = mask_img.convert("L")
        mask_arr = np.array(mask_gray)
        white_pixels = np.sum(mask_arr > 128)
        black_pixels = np.sum(mask_arr <= 128)
        total_pixels = mask_arr.size
        log_info(f"[Mask Debug] Mask stats: {white_pixels} white ({100*white_pixels/total_pixels:.1f}%), {black_pixels} black ({100*black_pixels/total_pixels:.1f}%)")

        result = extract_foreground(image, mask_img)
        log_info(f"[Mask Debug] Result mode: {result.mode}, size: {result.size}")

        # Check result alpha statistics
        result_arr = np.array(result)
        visible_pixels = np.sum(result_arr[:, :, 3] > 128)
        log_info(f"[Mask Debug] Result visible pixels: {visible_pixels} ({100*visible_pixels/total_pixels:.1f}%)")

        # Always save debug composite for inspection
        if output_dir:
            validate_output_dir(output_dir)
            composite_path = os.path.join(output_dir, "debug_composite.png")
            result.save(composite_path)
            log_info(f"[Mask Debug] Saved debug composite to: {composite_path}")

        return result

    except Exception as e:
        raise ImageValidationError(f"Failed to extract foreground: {e}")


def generate_3d_model(
    image: Image.Image,
    output_path: str,
    model_variant: str = "std",
    device: Optional[str] = None,
    num_steps: int = 50,
    octree_resolution: int = 384,
    progress_callback: Optional[Callable[[str, float], None]] = None,
) -> str:
    """Generate a 3D model from an RGBA image (shape only, no texture)."""
    try:
        if device is None:
            device = get_device() if logger else "mps"

        validate_output_dir(os.path.dirname(output_path) or ".")

        start_time = time.time()

        if progress_callback:
            progress_callback("Loading model", 0.0)

        pipeline = load_pipeline(model_variant, device)

        if progress_callback:
            progress_callback("Generating 3D shape", 0.2)

        log_info(
            f"Generating 3D shape (steps={num_steps}, resolution={octree_resolution})..."
        )

        # Debug: verify image being sent to pipeline
        log_info(f"[Pipeline Input] Mode: {image.mode}, Size: {image.size}")

        # Save debug copy of exact image being fed to pipeline
        debug_input_path = os.path.join(os.path.dirname(output_path) or ".", "DEBUG_hunyuan_input.png")
        image.save(debug_input_path)
        log_info(f"[Pipeline Input] DEBUG: Saved input image to: {debug_input_path}")

        img_arr = np.array(image)
        log_info(f"[Pipeline Input] Array shape: {img_arr.shape}, dtype: {img_arr.dtype}")

        if len(img_arr.shape) == 3:
            if img_arr.shape[2] == 4:
                # RGBA
                transparent = np.sum(img_arr[:, :, 3] == 0)
                opaque = np.sum(img_arr[:, :, 3] == 255)
                partial = img_arr.shape[0] * img_arr.shape[1] - transparent - opaque
                log_info(f"[Pipeline Input] Alpha channel: {opaque} opaque (255), {transparent} transparent (0), {partial} partial")
                log_info(f"[Pipeline Input] Alpha min={img_arr[:,:,3].min()}, max={img_arr[:,:,3].max()}, mean={img_arr[:,:,3].mean():.1f}")
            elif img_arr.shape[2] == 3:
                log_info(f"[Pipeline Input] WARNING: Image is RGB only (no alpha channel!)")
            else:
                log_info(f"[Pipeline Input] WARNING: Unexpected channels: {img_arr.shape[2]}")
        else:
            log_info(f"[Pipeline Input] WARNING: Unexpected array shape: {img_arr.shape}")

        with torch.inference_mode():
            mesh = pipeline(
                image=image,
                octree_resolution=octree_resolution,
                num_inference_steps=num_steps,
            )[0]

        shape_time = time.time() - start_time

        if progress_callback:
            progress_callback("Exporting model", 0.9)

        mesh.export(output_path)

        if progress_callback:
            progress_callback("Complete", 1.0)

        log_info(f"Shape generation took {shape_time:.1f}s")
        log_info(f"Model saved to: {output_path}")

        if (
            logger
            and hasattr(PerformanceConfig, "ENABLE_METRICS")
            and PerformanceConfig.ENABLE_METRICS
        ):
            if "generation_times" in metrics:
                metrics["generation_times"].append(shape_time)

        return output_path

    except Exception as e:
        raise GenerationError(f"Failed to generate 3D model: {e}")


def run_self_test(
    mask_path: str,
    original_image_path: str,
    output_dir: str,
    model_variant: str = "std",
) -> str:
    """Run self-test: generate 3D model from masked self-test image."""
    try:
        validate_image_path(mask_path)
        validate_image_path(original_image_path)
        validate_output_dir(output_dir)

        device = (
            get_device()
            if logger
            else ("mps" if torch.backends.mps.is_available() else "cpu")
        )
        log_info(f"Self-test using device: {device}")

        output_path = os.path.join(output_dir, "self_test_model.obj")

        log_info("Extracting foreground with mask...")
        foreground = extract_foreground_with_mask(
            original_image_path, mask_path, output_dir=output_dir
        )

        generate_3d_model(
            image=foreground,
            output_path=output_path,
            model_variant=model_variant,
            device=device,
            num_steps=50,
            octree_resolution=384,
        )

        print(f"SELF_TEST_MODEL_PATH:{output_path}", flush=True)
        log_info(f"Self-test complete: {output_path}")
        return output_path

    except Exception as e:
        log_error(f"Self-test failed: {e}")
        raise


def warmup_model(model_variant: str = "std") -> None:
    """Pre-download and load the Hunyuan3D model to warm up the cache."""
    try:
        log_info(f"Warmup called with model_variant='{model_variant}'")
        device = get_device() if logger else "mps"
        _ = load_pipeline(model_variant, device=device)
        log_info("Model warmup complete!")
    except Exception as e:
        log_error(f"Model warmup failed: {e}")
        raise


class HunyuanModelManager:
    def __init__(self, model_variant: str = "std"):
        self.model_variant = model_variant
        self.pipeline = None
        self.device = None

    def load(self):
        try:
            self.device = get_device() if logger else "mps"
            self.pipeline = load_pipeline(self.model_variant, self.device)
            return self.pipeline
        except Exception as e:
            raise ModelLoadError(f"Failed to load Hunyuan3D-2.1 model: {e}")

    def cleanup(self):
        if self.pipeline is not None:
            try:
                del self.pipeline
                self.pipeline = None
            except Exception as e:
                log_warning(f"Error during pipeline cleanup: {e}")

        if torch.cuda.is_available():
            try:
                torch.cuda.empty_cache()
            except Exception as e:
                log_warning(f"Error clearing CUDA cache: {e}")

        gc.collect()
        log_debug("Hunyuan3D-2.1 model cleanup complete")

    def __enter__(self):
        self.load()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.cleanup()


def main():
    parser = argparse.ArgumentParser(description="Hunyuan3D-2.1 Shape Generation Wrapper")
    parser.add_argument(
        "--test",
        nargs=2,
        metavar=("MASK", "IMAGE"),
        help="Run self-test with mask and original image paths",
    )
    parser.add_argument(
        "--warmup",
        action="store_true",
        help="Pre-download model without generating anything",
    )
    parser.add_argument(
        "--output-dir", default=APP_SUPPORT_DIR, help="Directory for output files"
    )
    parser.add_argument(
        "--model",
        default="std",
        choices=["mini", "std"],
        help="Model variant: mini (faster, 2mini) or std (Hunyuan3D-2.1, higher quality)",
    )
    parser.add_argument("--image", help="Input image path for generation")
    parser.add_argument("--mask", help="Mask image path (white=foreground)")
    parser.add_argument("--output", help="Output GLB path")
    parser.add_argument(
        "--steps", type=int, default=50, help="Number of diffusion steps (default: 50)"
    )
    parser.add_argument(
        "--resolution",
        type=int,
        default=384,
        help="Octree mesh resolution (default: 384)",
    )
    parser.add_argument(
        "--no_texture", action="store_true", help="(ignored, texture not supported)"
    )

    args = parser.parse_args()

    os.makedirs(args.output_dir, exist_ok=True)

    if args.warmup:
        warmup_model(args.model)
    elif args.test:
        mask_path, image_path = args.test
        run_self_test(mask_path, image_path, args.output_dir, args.model)
    elif args.image:
        import torch
        from PIL import Image

        device = "mps" if torch.backends.mps.is_available() else "cpu"

        # Load input image
        image = Image.open(args.image).convert("RGBA")
        log_info(f"[Input] Image: {args.image} (Mode: {image.mode}, Size: {image.size})")

        # If mask is provided, use it to ensure correct foreground extraction
        # This honors the "MAKE SURE NO OTHER IMAGES ARE BEING PROCESSED" requirement
        if args.mask and os.path.exists(args.mask):
            log_info(f"[Input] Applying mask: {args.mask}")
            mask_img = Image.open(args.mask).convert("L")
            if mask_img.size != image.size:
                mask_img = mask_img.resize(image.size, Image.Resampling.LANCZOS)
            
            # Use the core extraction utility which sets background to white with alpha=0
            image = extract_foreground(image, mask_img)
            log_info(f"[Input] Mask applied. Result mode: {image.mode}")
        else:
            log_info("[Input] No mask provided or mask not found, using image as-is (assuming already masked)")

        output_path = args.output or os.path.join(args.output_dir, "output_model.obj")

        generate_3d_model(
            image=image,
            output_path=output_path,
            model_variant=args.model,
            device=device,
            num_steps=args.steps,
            octree_resolution=args.resolution,
        )
    else:
        parser.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()
