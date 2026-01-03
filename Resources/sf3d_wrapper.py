#!/usr/bin/env python3
"""
SF3D (Stable Fast 3D) Wrapper for ModelrV3

Generates 3D models from images using Stability AI's SF3D.
Supports self-test mode for validation during app startup.
Requires PYTORCH_ENABLE_MPS_FALLBACK=1 for MPS backend.
"""

import os
import sys
import argparse
import time
import gc
from typing import Optional, Callable
from pathlib import Path

os.environ["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"

import torch
import numpy as np
from PIL import Image

try:
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
    )
    from modelrv3_core.logging import log_info, log_error, log_debug, log_warning
    from modelrv3_core.exceptions import (
        ModelLoadError,
        ImageValidationError,
        GenerationError,
        OutOfMemoryError,
    )

    logger = get_logger("sf3d_wrapper")

    APP_SUPPORT_DIR = str(ModelConfig.get_checkpoint_dir().parent)
    SF3D_CACHE_DIR = Path(os.path.join(APP_SUPPORT_DIR, "SF3D"))
except ImportError:
    logger = None
    log_info = lambda x: print(x, file=sys.stderr)
    log_error = lambda x: print(f"ERROR: {x}", file=sys.stderr)
    log_warning = lambda x: print(f"WARNING: {x}", file=sys.stderr)
    log_debug = lambda x: None
    get_device = lambda: (
        "mps"
        if torch.backends.mps.is_available()
        else "cuda"
        if torch.cuda.is_available()
        else "cpu"
    )
    check_gpu_available = (
        lambda: torch.backends.mps.is_available() or torch.cuda.is_available()
    )
    ModelLoadError = Exception
    ImageValidationError = Exception
    GenerationError = Exception
    OutOfMemoryError = Exception

    def validate_image_path(path):
        if not os.path.exists(path):
            raise ImageValidationError(f"File not found: {path}")

    def validate_output_dir(path):
        os.makedirs(path, exist_ok=True)

    def validate_mask_compatibility(image_path, mask_path):
        pass

    ModelConfig = type(
        "ModelConfig",
        (),
        {
            "get_checkpoint_dir": lambda: Path.home()
            / "Library"
            / "Application Support"
            / "ModelrV3"
        },
    )()
    PerformanceConfig = type("PerformanceConfig", (), {"ENABLE_METRICS": False})()
    metrics = {}

    APP_SUPPORT_DIR = os.path.expanduser("~/Library/Application Support/ModelrV3")
    SF3D_CACHE_DIR = Path(os.path.join(APP_SUPPORT_DIR, "SF3D"))

SF3D_CACHE_DIR.mkdir(parents=True, exist_ok=True)

os.environ["HF_HOME"] = str(SF3D_CACHE_DIR / "hf_home")
os.environ["HUGGINGFACE_HUB_CACHE"] = str(SF3D_CACHE_DIR / "hf_cache")
os.environ["TORCH_HOME"] = str(SF3D_CACHE_DIR / "torch_home")


def load_sf3d_model(device: str = "mps"):
    """Load the SF3D model from HuggingFace."""
    try:
        script_dir = Path(__file__).parent

        sf3d_repo_path = script_dir / "stable-fast-3d"

        if not sf3d_repo_path.exists():
            sf3d_repo_path = script_dir.parent / "stable-fast-3d"

        if not sf3d_repo_path.exists():
            sf3d_repo_path = script_dir.parent.parent / "stable-fast-3d"

        if sf3d_repo_path.exists():
            log_info(f"Adding SF3D repo to path: {sf3d_repo_path}")
            sys.path.insert(0, str(sf3d_repo_path))
        else:
            log_warning(
                f"stable-fast-3d not found in expected locations, trying import anyway"
            )

        from sf3d.system import SF3D

        log_info("Loading SF3D model from zimengxiong/Modelr-SF3D...")

        model = SF3D.from_pretrained(
            "zimengxiong/Modelr-SF3D",
            config_name="config.yaml",
            weight_name="model.safetensors",
        )
        model.to(device)
        model.eval()

        log_info(f"SF3D model loaded successfully on {device}")
        return model

    except RuntimeError as e:
        if "out of memory" in str(e).lower():
            raise OutOfMemoryError(f"GPU memory exhausted: {e}")
        raise ModelLoadError(f"Failed to load SF3D model: {e}")
    except Exception as e:
        raise ModelLoadError(f"Unexpected error loading SF3D model: {e}")


def extract_foreground_with_mask(
    image_path: str, mask_path: str, output_dir: Optional[str] = None
) -> Image.Image:
    """Extract foreground from image using a SAM2 mask."""
    try:
        validate_image_path(image_path)
        validate_image_path(mask_path)
        validate_mask_compatibility(image_path, mask_path)

        log_debug(f"Extracting foreground from {image_path} using mask {mask_path}")

        image = Image.open(image_path).convert("RGBA")
        mask_img = Image.open(mask_path).convert("RGBA")

        if mask_img.size != image.size:
            log_debug(f"Resizing mask from {mask_img.size} to {image.size}")
            mask_img = mask_img.resize(image.size, Image.Resampling.LANCZOS)

        image_array = np.array(image)
        mask_array = np.array(mask_img)

        alpha_mask = mask_array[:, :, 3]

        image_array[:, :, 3] = alpha_mask

        result = Image.fromarray(image_array, "RGBA")

        if output_dir:
            validate_output_dir(output_dir)
            composite_path = os.path.join(output_dir, "self_test_composite.png")
            result.save(composite_path)
            log_debug(f"Saved composite to: {composite_path}")

        return result

    except Exception as e:
        raise ImageValidationError(f"Failed to extract foreground: {e}")


def generate_3d_model(
    image: Image.Image,
    output_path: str,
    device: Optional[str] = None,
    texture_resolution: int = 1024,
    remesh_option: str = "none",
    foreground_ratio: float = 0.85,
    progress_callback: Optional[Callable[[str, float], None]] = None,
) -> str:
    """Generate a 3D model from an RGBA image using SF3D."""
    try:
        if device is None:
            device = get_device() if logger else "mps"
            if device == "mps" and not torch.backends.mps.is_available():
                device = "cpu"

        validate_output_dir(os.path.dirname(output_path) or ".")

        start_time = time.time()

        if progress_callback:
            progress_callback("Loading SF3D model", 0.0)

        model = load_sf3d_model(device)

        import rembg
        from sf3d.utils import resize_foreground

        if progress_callback:
            progress_callback("Processing image", 0.2)

        log_info(f"Resizing foreground with ratio {foreground_ratio}...")
        processed_image = resize_foreground(image, foreground_ratio)

        if progress_callback:
            progress_callback("Generating 3D mesh", 0.3)

        log_info(
            f"Generating 3D model (texture_res={texture_resolution}, remesh={remesh_option})..."
        )

        with torch.no_grad():
            mesh, glob_dict = model.run_image(
                [processed_image],
                bake_resolution=texture_resolution,
                remesh=remesh_option,
                vertex_count=-1,
            )

        generation_time = time.time() - start_time

        if progress_callback:
            progress_callback("Exporting model", 0.9)

        import trimesh

        scene = trimesh.Scene(geometry=mesh)
        scene.export(output_path)

        if progress_callback:
            progress_callback("Complete", 1.0)

        log_info(f"SF3D generation took {generation_time:.1f}s")
        log_info(f"Model saved to: {output_path}")

        if (
            logger
            and hasattr(PerformanceConfig, "ENABLE_METRICS")
            and PerformanceConfig.ENABLE_METRICS
        ):
            if "generation_times" in metrics:
                metrics["generation_times"].append(generation_time)

        return output_path

    except Exception as e:
        raise GenerationError(f"Failed to generate 3D model: {e}")


def run_self_test(
    mask_path: str,
    original_image_path: str,
    output_dir: str,
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
        log_info(f"SF3D Self-test using device: {device}")

        output_path = os.path.join(output_dir, "self_test_model_sf3d.obj")

        log_info("Extracting foreground with mask...")
        foreground = extract_foreground_with_mask(
            original_image_path, mask_path, output_dir=output_dir
        )

        generate_3d_model(
            image=foreground,
            output_path=output_path,
            device=device,
            texture_resolution=1024,
            remesh_option="none",
        )

        print(f"SELF_TEST_MODEL_PATH:{output_path}", flush=True)
        log_info(f"SF3D Self-test complete: {output_path}")
        return output_path

    except Exception as e:
        log_error(f"SF3D Self-test failed: {e}")
        raise


def warmup_model() -> None:
    """Pre-download and load the model to warm up the cache."""
    try:
        log_info("Warming up SF3D model (downloading if needed)...")
        device = get_device() if logger else "mps"
        if device == "mps" and not torch.backends.mps.is_available():
            device = "cpu"
        _ = load_sf3d_model(device)
        log_info("SF3D Model warmup complete!")
    except Exception as e:
        log_error(f"SF3D Model warmup failed: {e}")
        raise


class SF3DModelManager:
    def __init__(self):
        self.model = None
        self.device = None

    def load(self):
        try:
            self.device = get_device() if logger else "mps"
            if self.device == "mps" and not torch.backends.mps.is_available():
                self.device = "cpu"
            self.model = load_sf3d_model(self.device)
            return self.model
        except Exception as e:
            raise ModelLoadError(f"Failed to load SF3D model: {e}")

    def cleanup(self):
        if self.model is not None:
            try:
                del self.model
                self.model = None
            except Exception as e:
                log_warning(f"Error during model cleanup: {e}")

        if torch.cuda.is_available():
            try:
                torch.cuda.empty_cache()
            except Exception as e:
                log_warning(f"Error clearing CUDA cache: {e}")

        gc.collect()
        log_debug("SF3D model cleanup complete")

    def __enter__(self):
        self.load()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.cleanup()


def main():
    parser = argparse.ArgumentParser(description="SF3D (Stable Fast 3D) Wrapper")
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
    parser.add_argument("--image", help="Input image path for generation")
    parser.add_argument("--mask", help="Mask image path (white=foreground)")
    parser.add_argument("--output", help="Output GLB path")
    parser.add_argument(
        "--texture-resolution",
        type=int,
        default=1024,
        help="Texture resolution (default: 1024)",
    )
    parser.add_argument(
        "--remesh",
        default="none",
        choices=["none", "triangle", "quad"],
        help="Remeshing option (default: none)",
    )
    parser.add_argument(
        "--foreground-ratio",
        type=float,
        default=0.85,
        help="Foreground size ratio (default: 0.85)",
    )
    parser.add_argument(
        "--device",
        type=str,
        default=None,
        help="Device to use (mps, cpu, cuda)",
    )

    args = parser.parse_args()

    os.makedirs(args.output_dir, exist_ok=True)

    if args.warmup:
        warmup_model()
    elif args.test:
        mask_path, image_path = args.test
        run_self_test(mask_path, image_path, args.output_dir)
    elif args.image:
        device = args.device or ("mps" if torch.backends.mps.is_available() else "cpu")

        if args.mask:
            image = extract_foreground_with_mask(
                args.image, args.mask, output_dir=args.output_dir
            )
        else:
            image = Image.open(args.image).convert("RGBA")

        output_path = args.output or os.path.join(args.output_dir, "output_model.glb")

        generate_3d_model(
            image=image,
            output_path=output_path,
            device=device,
            texture_resolution=args.texture_resolution,
            remesh_option=args.remesh,
            foreground_ratio=args.foreground_ratio,
        )
    else:
        parser.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()
