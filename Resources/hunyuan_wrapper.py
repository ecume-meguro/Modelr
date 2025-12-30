#!/usr/bin/env python3
"""
Hunyuan3D-2 Model Generation Wrapper for ModelrV3

Generates 3D models from masked images using Tencent's Hunyuan3D-2.
Supports self-test mode for validation during app startup.
Shape generation only (no texture/paint pipeline).
"""

import os
import sys
import argparse
import time

# Isolate all model downloads to Application Support
APP_SUPPORT_DIR = os.path.expanduser("~/Library/Application Support/ModelrV3")
HUNYUAN_CACHE_DIR = os.path.join(APP_SUPPORT_DIR, "Hunyuan3D")

os.makedirs(HUNYUAN_CACHE_DIR, exist_ok=True)
os.environ["HY3DGEN_MODELS"] = HUNYUAN_CACHE_DIR
os.environ["HF_HOME"] = os.path.join(HUNYUAN_CACHE_DIR, "hf_home")
os.environ["HUGGINGFACE_HUB_CACHE"] = os.path.join(HUNYUAN_CACHE_DIR, "hf_cache")
os.environ["TORCH_HOME"] = os.path.join(HUNYUAN_CACHE_DIR, "torch_home")


def load_pipeline(model_variant="mini", device="mps"):
    """Load the Hunyuan3D shape generation pipeline."""
    from hy3dgen.shapegen import Hunyuan3DDiTFlowMatchingPipeline

    repo_map = {
        "mini": ("tencent/Hunyuan3D-2mini", "hunyuan3d-dit-v2-mini"),
        "std": ("tencent/Hunyuan3D-2", "hunyuan3d-dit-v2-0"),
    }

    repo_id, subfolder = repo_map.get(model_variant, repo_map["mini"])

    print(f"Loading Hunyuan3D pipeline: {repo_id}/{subfolder}", file=sys.stderr)

    pipeline = Hunyuan3DDiTFlowMatchingPipeline.from_pretrained(
        repo_id,
        subfolder=subfolder,
        device=device,
        use_safetensors=True,
        cache_dir=HUNYUAN_CACHE_DIR,
    )

    return pipeline


def extract_foreground_with_mask(image_path, mask_path, output_dir=None):
    """
    Extract foreground from image using a SAM2 mask.
    SAM2 mask is RGBA where the alpha channel contains the actual mask (0-255).
    RGB channels are just a constant color tint for visualization.
    """
    from PIL import Image
    import numpy as np

    image = Image.open(image_path).convert("RGBA")
    mask_img = Image.open(mask_path).convert("RGBA")

    # Resize mask to match image if needed
    if mask_img.size != image.size:
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
        composite_path = os.path.join(output_dir, "self_test_composite.png")
        result.save(composite_path)
        print(f"Saved composite to: {composite_path}", file=sys.stderr)

    return result


def generate_3d_model(image, output_path, model_variant="mini", device="mps",
                      num_steps=30, octree_resolution=256):
    """Generate a 3D model from an RGBA image (shape only, no texture)."""
    import torch

    start_time = time.time()

    # Load shape generation pipeline
    pipeline = load_pipeline(model_variant, device)

    print(f"Generating 3D shape (steps={num_steps}, resolution={octree_resolution})...", file=sys.stderr)
    with torch.inference_mode():
        mesh = pipeline(
            image=image,
            octree_resolution=octree_resolution,
            num_inference_steps=num_steps,
        )[0]

    shape_time = time.time() - start_time
    print(f"Shape generation took {shape_time:.1f}s", file=sys.stderr)

    # Export to GLB
    mesh.export(output_path)

    print(f"Total generation time: {shape_time:.1f}s", file=sys.stderr)
    print(f"Model saved to: {output_path}", file=sys.stderr)

    return output_path


def run_self_test(mask_path, original_image_path, output_dir, model_variant="mini"):
    """
    Run self-test: generate 3D model from masked self-test image.
    """
    import torch
    from PIL import Image

    device = "mps" if torch.backends.mps.is_available() else "cpu"
    print(f"Self-test using device: {device}", file=sys.stderr)

    # Use .obj format for SceneKit compatibility (GLB not supported by ModelIO)
    output_path = os.path.join(output_dir, "self_test_model.obj")

    # Extract foreground using SAM2 mask (saves composite for debugging)
    print("Extracting foreground with mask...", file=sys.stderr)
    foreground = extract_foreground_with_mask(original_image_path, mask_path, output_dir=output_dir)

    # Generate 3D model (shape only, reduced quality for faster self-test)
    generate_3d_model(
        image=foreground,
        output_path=output_path,
        model_variant=model_variant,
        device=device,
        num_steps=35,           # High feature quality
        octree_resolution=150,  # Lower mesh resolution for faster generation
    )

    print(f"SELF_TEST_MODEL_PATH:{output_path}", flush=True)
    return output_path


def warmup_model(model_variant="mini"):
    """Pre-download and load the model to warm up the cache."""
    print("Warming up Hunyuan3D model (downloading if needed)...", file=sys.stderr)
    _ = load_pipeline(model_variant, device="mps")
    print("Model warmup complete!", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description="Hunyuan3D-2 Shape Generation Wrapper")
    parser.add_argument("--test", nargs=2, metavar=("MASK", "IMAGE"),
                        help="Run self-test with mask and original image paths")
    parser.add_argument("--warmup", action="store_true",
                        help="Pre-download model without generating anything")
    parser.add_argument("--output-dir", default=APP_SUPPORT_DIR,
                        help="Directory for output files")
    parser.add_argument("--model", default="mini", choices=["mini", "std"],
                        help="Model variant: mini (faster) or std (higher quality)")
    parser.add_argument("--image", help="Input image path for generation")
    parser.add_argument("--mask", help="Mask image path (white=foreground)")
    parser.add_argument("--output", help="Output GLB path")
    parser.add_argument("--steps", type=int, default=30, help="Number of diffusion steps (default: 30)")
    parser.add_argument("--resolution", type=int, default=256, help="Octree mesh resolution (default: 256)")
    parser.add_argument("--no_texture", action="store_true", help="(ignored, texture not supported)")

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

        if args.mask:
            image = extract_foreground_with_mask(args.image, args.mask, output_dir=args.output_dir)
        else:
            image = Image.open(args.image).convert("RGBA")

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
