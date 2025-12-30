import os
import sys
import json
import time
import torch
import numpy as np
import cv2
from PIL import Image, ImageOps, ImageDraw
from sam2.build_sam import build_sam2
from sam2.sam2_image_predictor import SAM2ImagePredictor
import urllib.request

# Model configuration mappings
MODEL_CONFIGS = {
    "tiny": "sam2_hiera_t.yaml",
    "small": "sam2_hiera_s.yaml",
    "base_plus": "sam2_hiera_b+.yaml",
    "large": "sam2_hiera_l.yaml"
}

MODEL_CHECKPOINTS = {
    "tiny": "sam2_hiera_tiny.pt",
    "small": "sam2_hiera_small.pt",
    "base_plus": "sam2_hiera_base_plus.pt",
    "large": "sam2_hiera_large.pt"
}

CHECKPOINT_URLS = {
    "tiny": "https://dl.fbaipublicfiles.com/segment_anything_2/072824/sam2_hiera_tiny.pt",
    "small": "https://dl.fbaipublicfiles.com/segment_anything_2/072824/sam2_hiera_small.pt",
    "base_plus": "https://dl.fbaipublicfiles.com/segment_anything_2/072824/sam2_hiera_base_plus.pt",
    "large": "https://dl.fbaipublicfiles.com/segment_anything_2/072824/sam2_hiera_large.pt"
}


def download_checkpoint(path, model_type="base_plus"):
    if not os.path.exists(path):
        print(f"Downloading checkpoint to {path}...", file=sys.stderr)
        urllib.request.urlretrieve(CHECKPOINT_URLS[model_type], path)
        print("Download complete.", file=sys.stderr)


def get_checkpoint_path(model_type, script_dir):
    checkpoint_name = MODEL_CHECKPOINTS.get(model_type, "sam2_hiera_tiny.pt")
    checkpoint_path = os.path.join(script_dir, "checkpoints", checkpoint_name)
    os.makedirs(os.path.dirname(checkpoint_path), exist_ok=True)
    return checkpoint_path


def load_predictor(model_type, script_dir):
    """Load SAM2 model and return predictor."""
    model_cfg = MODEL_CONFIGS.get(model_type, "sam2_hiera_t.yaml")
    checkpoint_path = get_checkpoint_path(model_type, script_dir)
    download_checkpoint(checkpoint_path, model_type)

    device = "mps" if torch.backends.mps.is_available() else "cpu"
    predictor = SAM2ImagePredictor(build_sam2(model_cfg, checkpoint_path, device=device))
    return predictor, device


def save_mask(mask, output_path):
    """Save mask as RGBA PNG with alpha channel."""
    mask_255 = (mask * 255).astype(np.uint8)
    h_mask, w_mask = mask_255.shape

    rgba = np.zeros((h_mask, w_mask, 4), dtype=np.uint8)
    rgba[:, :, 0] = 200  # B (in BGR for cv2)
    rgba[:, :, 1] = 100  # G
    rgba[:, :, 2] = 50   # R
    rgba[:, :, 3] = mask_255  # Alpha

    cv2.imwrite(output_path, rgba)
    return output_path


def save_debug_image(image_np, points, box, output_dir):
    """Save a debug image with click points and box marked."""
    debug_img = Image.fromarray(image_np)
    draw = ImageDraw.Draw(debug_img)

    # Draw points
    r = 15
    for (x, y) in points:
        draw.ellipse([x-r, y-r, x+r, y+r], outline='lime', width=3)
        draw.line([x-r, y, x+r, y], fill='lime', width=2)
        draw.line([x, y-r, x, y+r], fill='lime', width=2)

    # Draw box
    if box is not None:
        x1, y1, x2, y2 = box
        draw.rectangle([x1, y1, x2, y2], outline='cyan', width=3)

    debug_path = os.path.join(output_dir, "debug_click_point.png")
    debug_img.save(debug_path)
    return debug_path


# =============================================================================
# SERVER MODE - Persistent process with JSON stdin/stdout protocol
# =============================================================================

def server_mode(model_type, script_dir, output_dir):
    """
    Persistent server mode for fast iterative refinement.

    Reads JSON requests from stdin (one per line), writes JSON responses to stdout.
    Model stays loaded between requests for ~50ms inference instead of ~3s.

    Commands:
        - set_image: Load and encode a new image
        - predict: Run mask prediction with points/box
        - reset: Clear current image state
    """
    # Load model once at startup
    print(f"Loading SAM2 model ({model_type})...", file=sys.stderr)
    predictor, device = load_predictor(model_type, script_dir)
    print(f"Model loaded on {device}", file=sys.stderr)

    # State
    current_image_path = None
    current_image_np = None
    image_set = False

    # Signal ready
    response = {"success": True, "ready": True}
    print(json.dumps(response), flush=True)

    # Main request loop
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        try:
            request = json.loads(line)
            command = request.get("command", "")

            if command == "set_image":
                # Load and encode new image
                image_path = request.get("imagePath")
                if not image_path or not os.path.exists(image_path):
                    response = {"success": False, "error": f"Image not found: {image_path}"}
                else:
                    image = ImageOps.exif_transpose(Image.open(image_path))
                    current_image_np = np.array(image.convert("RGB"))
                    current_image_path = image_path

                    with torch.inference_mode():
                        predictor.set_image(current_image_np)

                    image_set = True
                    h, w = current_image_np.shape[:2]
                    response = {
                        "success": True,
                        "imagePath": image_path,
                        "width": w,
                        "height": h
                    }

            elif command == "predict":
                if not image_set:
                    response = {"success": False, "error": "No image set. Call set_image first."}
                else:
                    start_time = time.time()

                    points = request.get("points", [])
                    box = request.get("box")

                    # Build inputs
                    input_points = np.array(points) if points else None
                    input_labels = np.ones(len(points), dtype=np.int32) if points else None
                    input_box = np.array(box) if box else None

                    with torch.inference_mode():
                        masks, scores, _ = predictor.predict(
                            point_coords=input_points,
                            point_labels=input_labels,
                            box=input_box,
                            multimask_output=True
                        )

                    # Select best mask
                    best_idx = int(np.argmax(scores))
                    mask = masks[best_idx]
                    best_score = float(scores[best_idx])

                    # Save mask
                    mask_path = os.path.join(output_dir, "mask.png")
                    save_mask(mask, mask_path)

                    # Save debug image
                    save_debug_image(current_image_np, points or [], box, output_dir)

                    elapsed_ms = int((time.time() - start_time) * 1000)
                    response = {
                        "success": True,
                        "maskPath": mask_path,
                        "score": best_score,
                        "inferenceTimeMs": elapsed_ms
                    }

            elif command == "reset":
                # Clear state, keep model loaded
                current_image_path = None
                current_image_np = None
                image_set = False
                predictor.reset_predictor()
                response = {"success": True}

            else:
                response = {"success": False, "error": f"Unknown command: {command}"}

        except json.JSONDecodeError as e:
            response = {"success": False, "error": f"Invalid JSON: {str(e)}"}
        except Exception as e:
            response = {"success": False, "error": str(e)}

        # Send response
        print(json.dumps(response), flush=True)


# =============================================================================
# CLI MODE - Original single-shot invocation
# =============================================================================

def cli_mode():
    """Original CLI mode for backwards compatibility."""
    model_type = "tiny"
    for i, arg in enumerate(sys.argv):
        if arg == "--model" and i + 1 < len(sys.argv):
            model_type = sys.argv[i+1]
            break

    script_dir = os.path.dirname(os.path.abspath(__file__))

    if "--test" in sys.argv:
        run_self_test(model_type, script_dir)
        sys.exit(0)

    # Parse positional arguments
    pos_args = []
    skip_next = False
    for i, arg in enumerate(sys.argv[1:]):
        if skip_next:
            skip_next = False
            continue
        if arg == "--model":
            skip_next = True
            continue
        pos_args.append(arg)

    if len(pos_args) < 3:
        print("Usage: python sam_wrapper.py [--model type] <image_path> <x> <y> [output_path]")
        sys.exit(1)

    image_path = pos_args[0]
    x = int(pos_args[1])
    y = int(pos_args[2])
    output_path = pos_args[3] if len(pos_args) > 3 else "mask.png"

    print(f"Loading model (Hiera {model_type.replace('_', ' ').title()})...")
    predictor, device = load_predictor(model_type, script_dir)

    print(f"Processing image: {image_path}")
    image = ImageOps.exif_transpose(Image.open(image_path))
    image_np = np.array(image.convert("RGB"))
    h_img, w_img = image_np.shape[:2]
    print(f"Image dimensions: {w_img}x{h_img} (WxH)")
    print(f"Click coordinates: ({x}, {y})")

    if x < 0 or x >= w_img or y < 0 or y >= h_img:
        print(f"WARNING: Coordinates ({x}, {y}) are outside image bounds")

    output_dir = os.path.dirname(output_path) if os.path.dirname(output_path) else "."
    save_debug_image(image_np, [[x, y]], None, output_dir)

    with torch.inference_mode():
        predictor.set_image(image_np)

        masks, scores, _ = predictor.predict(
            point_coords=np.array([[x, y]]),
            point_labels=np.array([1]),
            multimask_output=True,
        )

    best_idx = np.argmax(scores)
    mask = masks[best_idx]
    print(f"Selected mask {best_idx} with score {scores[best_idx]:.4f}")
    print(f"All scores: {[f'{s:.4f}' for s in scores]}")

    save_mask(mask, output_path)
    print(f"Mask saved to {output_path}")


def run_self_test(model_type, script_dir):
    """Run self-test with optional image."""
    print(f"Model: SAM2 (Hiera {model_type.replace('_', ' ').title()})")
    print("Checking for model checkpoint...")

    predictor, device = load_predictor(model_type, script_dir)
    print(f"Self-test: Model loaded successfully on {device}")

    # Find test image path
    test_img_path = None
    for i, arg in enumerate(sys.argv):
        if arg == "--test" and i + 1 < len(sys.argv):
            test_img_path = sys.argv[i+1]

    if test_img_path and os.path.exists(test_img_path):
        print(f"Testing segmentation model on {test_img_path}...")
        image = ImageOps.exif_transpose(Image.open(test_img_path))
        w, h = image.size
        print(f"Image dimensions: {w}x{h}")

        image_np = np.array(image.convert("RGB"))

        with torch.inference_mode():
            predictor.set_image(image_np)

            # Self-test click point: 700px from left, 700px from bottom
            cx, cy = 700, h - 700
            masks, scores, _ = predictor.predict(
                point_coords=np.array([[cx, cy]]),
                point_labels=np.array([1]),
                multimask_output=True,
            )

        best_idx = np.argmax(scores)
        mask = masks[best_idx]
        print(f"Best mask index: {best_idx}, score: {scores[best_idx]:.4f}")
        print(f"Mask shape: {mask.shape}, coverage: {mask.sum() / mask.size * 100:.1f}%")

        output_mask_path = os.path.join(os.path.dirname(test_img_path), "self_test_mask.png")
        save_mask(mask, output_mask_path)
        print(f"Visual self-test complete. Mask saved to {output_mask_path}")


# =============================================================================
# MAIN ENTRY POINT
# =============================================================================

if __name__ == "__main__":
    if "--server" in sys.argv:
        # Persistent server mode
        model_type = "tiny"
        for i, arg in enumerate(sys.argv):
            if arg == "--model" and i + 1 < len(sys.argv):
                model_type = sys.argv[i+1]
                break

        script_dir = os.path.dirname(os.path.abspath(__file__))

        # Get output directory from args or use script dir
        output_dir = script_dir
        for i, arg in enumerate(sys.argv):
            if arg == "--output-dir" and i + 1 < len(sys.argv):
                output_dir = sys.argv[i+1]
                break

        server_mode(model_type, script_dir, output_dir)
    else:
        # Original CLI mode
        cli_mode()
