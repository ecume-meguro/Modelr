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

# Set MPS fallback before importing torch
os.environ["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"

import torch
import numpy as np
from PIL import Image

try:
    from config import ModelConfig, PerformanceConfig, metrics
    from device_utils import get_device, check_gpu_available, health_check
    from logging_config import get_logger

    logger = get_logger("sf3d_wrapper")

    APP_SUPPORT_DIR = str(ModelConfig.get_checkpoint_dir().parent)
    SF3D_CACHE_DIR = Path(os.path.join(APP_SUPPORT_DIR, "SF3D"))
except ImportError:
    logger = None
    APP_SUPPORT_DIR = os.path.expanduser("~/Library/Application Support/ModelrV3")
    SF3D_CACHE_DIR = Path(os.path.join(APP_SUPPORT_DIR, "SF3D"))

SF3D_CACHE_DIR.mkdir(parents=True, exist_ok=True)

# Set HuggingFace cache to our app directory
os.environ["HF_HOME"] = str(SF3D_CACHE_DIR / "hf_home")
os.environ["HUGGINGFACE_HUB_CACHE"] = str(SF3D_CACHE_DIR / "hf_cache")
os.environ["TORCH_HOME"] = str(SF3D_CACHE_DIR / "torch_home")


class ModelLoadError(Exception):
    pass


class ImageValidationError(Exception):
    pass


class GenerationError(Exception):
    pass


class OutOfMemoryError(Exception):
    pass


def log_info(message: str) -> None:
    if logger:
        logger.info(message)
    else:
        print(message, file=sys.stderr)


def log_error(message: str) -> None:
    if logger:
        logger.error(message)
    else:
        print(f"ERROR: {message}", file=sys.stderr)


def log_debug(message: str) -> None:
    if logger:
        logger.debug(message)


def log_warning(message: str) -> None:
    if logger:
        logger.warning(message)
    else:
        print(f"WARNING: {message}", file=sys.stderr)


def validate_image_path(image_path: str) -> None:
    if not image_path:
        raise ImageValidationError("Image path cannot be empty")

    path = Path(image_path)
    if not path.exists():
        raise ImageValidationError(f"Image file not found: {image_path}")

    if not path.is_file():
        raise ImageValidationError(f"Path is not a file: {image_path}")

    valid_extensions = {".jpg", ".jpeg", ".png", ".bmp", ".tiff", ".webp"}
    if path.suffix.lower() not in valid_extensions:
        raise ImageValidationError(f"Invalid image format: {path.suffix}")


def validate_output_dir(output_dir: str) -> None:
    path = Path(output_dir)
    if not path.exists():
        try:
            path.mkdir(parents=True, exist_ok=True)
        except Exception as e:
            raise ImageValidationError(f"Failed to create output directory: {e}")

    if not path.is_dir():
        raise ImageValidationError(f"Output path is not a directory: {output_dir}")


def validate_mask_compatibility(image_path: str, mask_path: str) -> None:
    try:
        with Image.open(image_path) as img, Image.open(mask_path) as mask:
            img_size = img.size
            mask_size = mask.size

            if (
                abs(img_size[0] - mask_size[0]) > 10
                or abs(img_size[1] - mask_size[1]) > 10
            ):
                log_warning(
                    f"Image size {img_size} and mask size {mask_size} differ significantly"
                )
    except Exception as e:
        raise ImageValidationError(f"Failed to validate mask compatibility: {e}")


def load_sf3d_model(device: str = "mps"):
    """Load the SF3D model from HuggingFace."""
    try:
        # Add stable-fast-3d to path - check multiple locations
        script_dir = Path(__file__).parent
        
        # Location 1: stable-fast-3d in same directory as script (when copied to SF3D folder)
        sf3d_repo_path = script_dir / "stable-fast-3d"
        
        # Location 2: stable-fast-3d in parent directory (project root)
        if not sf3d_repo_path.exists():
            sf3d_repo_path = script_dir.parent / "stable-fast-3d"
        
        # Location 3: stable-fast-3d two levels up (from Resources/)
        if not sf3d_repo_path.exists():
            sf3d_repo_path = script_dir.parent.parent / "stable-fast-3d"
        
        if sf3d_repo_path.exists():
            log_info(f"Adding SF3D repo to path: {sf3d_repo_path}")
            sys.path.insert(0, str(sf3d_repo_path))
        else:
            log_warning(f"stable-fast-3d not found in expected locations, trying import anyway")
        
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
    """
    Extract foreground from image using a SAM2 mask.
    SAM2 mask is RGBA where the alpha channel contains the actual mask (0-255).
    """
    try:
        validate_image_path(image_path)
        validate_image_path(mask_path)
        validate_mask_compatibility(image_path, mask_path)

        log_debug(f"Extracting foreground from {image_path} using mask {mask_path}")

        image = Image.open(image_path).convert("RGBA")
        mask_img = Image.open(mask_path).convert("RGBA")

        # Resize mask to match image if needed
        if mask_img.size != image.size:
            log_debug(f"Resizing mask from {mask_img.size} to {image.size}")
            mask_img = mask_img.resize(image.size, Image.Resampling.LANCZOS)

        image_array = np.array(image)
        mask_array = np.array(mask_img)

        # SAM2 mask: alpha channel IS the mask (0=background, 255=foreground)
        alpha_mask = mask_array[:, :, 3]

        # Apply mask as alpha channel to original image
        image_array[:, :, 3] = alpha_mask

        result = Image.fromarray(image_array, "RGBA")

        # Save composite for debugging
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

        # Load SF3D model
        model = load_sf3d_model(device)

        # Import rembg for foreground processing
        import rembg
        from sf3d.utils import resize_foreground

        if progress_callback:
            progress_callback("Processing image", 0.2)

        # Resize foreground to proper ratio
        log_info(f"Resizing foreground with ratio {foreground_ratio}...")
        processed_image = resize_foreground(image, foreground_ratio)

        if progress_callback:
            progress_callback("Generating 3D mesh", 0.3)

        log_info(
            f"Generating 3D model (texture_res={texture_resolution}, remesh={remesh_option})..."
        )

        with torch.no_grad():
            # SF3D run_image expects a list of images
            mesh, glob_dict = model.run_image(
                [processed_image],
                bake_resolution=texture_resolution,
                remesh=remesh_option,
                vertex_count=-1,  # No vertex reduction
            )

        generation_time = time.time() - start_time

        if progress_callback:
            progress_callback("Exporting model", 0.9)

        # Export to OBJ with MTL and texture files for SceneKit compatibility
        # Using scene export writes the OBJ, MTL, and texture image files
        import trimesh
        scene = trimesh.Scene(geometry=mesh)
        scene.export(output_path)

        if progress_callback:
            progress_callback("Complete", 1.0)

        log_info(f"SF3D generation took {generation_time:.1f}s")
        log_info(f"Model saved to: {output_path}")

        # Track metrics if available
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
    """
    Run self-test: generate 3D model from masked self-test image.
    """
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

        # SF3D outputs OBJ format with MTL and texture files for SceneKit compatibility
        output_path = os.path.join(output_dir, "self_test_model_sf3d.obj")

        # Extract foreground using SAM2 mask
        log_info("Extracting foreground with mask...")
        foreground = extract_foreground_with_mask(
            original_image_path, mask_path, output_dir=output_dir
        )

        # Generate 3D model with SF3D
        generate_3d_model(
            image=foreground,
            output_path=output_path,
            device=device,
            texture_resolution=1024,  # Higher resolution for quality
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

    args = parser.parse_args()

    os.makedirs(args.output_dir, exist_ok=True)

    if args.warmup:
        warmup_model()
    elif args.test:
        mask_path, image_path = args.test
        run_self_test(mask_path, image_path, args.output_dir)
    elif args.image:
        device = "mps" if torch.backends.mps.is_available() else "cpu"

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
