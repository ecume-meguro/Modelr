import os
import sys
import torch
import numpy as np
import cv2
from PIL import Image, ImageOps, ImageDraw
from sam2.build_sam import build_sam2
from sam2.sam2_image_predictor import SAM2ImagePredictor
import urllib.request

def download_checkpoint(path, model_type="base_plus"):
    urls = {
        "tiny": "https://dl.fbaipublicfiles.com/segment_anything_2/072824/sam2_hiera_tiny.pt",
        "small": "https://dl.fbaipublicfiles.com/segment_anything_2/072824/sam2_hiera_small.pt",
        "base_plus": "https://dl.fbaipublicfiles.com/segment_anything_2/072824/sam2_hiera_base_plus.pt",
        "large": "https://dl.fbaipublicfiles.com/segment_anything_2/072824/sam2_hiera_large.pt"
    }
    if not os.path.exists(path):
        print(f"Downloading checkpoint to {path}...")
        urllib.request.urlretrieve(urls[model_type], path)
        print("Download complete.")

def save_debug_image(image_np, x, y, output_dir):
    """Save a debug image with the click point marked."""
    debug_img = Image.fromarray(image_np)
    draw = ImageDraw.Draw(debug_img)
    # Draw crosshair at click point
    r = 20
    draw.ellipse([x-r, y-r, x+r, y+r], outline='red', width=3)
    draw.line([x-r*2, y, x+r*2, y], fill='red', width=2)
    draw.line([x, y-r*2, x, y+r*2], fill='red', width=2)
    debug_path = os.path.join(output_dir, "debug_click_point.png")
    debug_img.save(debug_path)
    print(f"Debug image saved to {debug_path}")

def main():
    model_type = "tiny"
    for i, arg in enumerate(sys.argv):
        if arg == "--model" and i + 1 < len(sys.argv):
            model_type = sys.argv[i+1]
            break

    model_configs = {
        "tiny": "sam2_hiera_t.yaml",
        "small": "sam2_hiera_s.yaml",
        "base_plus": "sam2_hiera_b+.yaml",
        "large": "sam2_hiera_l.yaml"
    }
    model_checkpoints = {
        "tiny": "sam2_hiera_tiny.pt",
        "small": "sam2_hiera_small.pt",
        "base_plus": "sam2_hiera_base_plus.pt",
        "large": "sam2_hiera_large.pt"
    }

    if "--test" in sys.argv:
        print(f"Model: SAM2 (Hiera {model_type.replace('_', ' ').title()})")
        print("Checking for model checkpoint...")
        model_cfg = model_configs.get(model_type, "sam2_hiera_t.yaml")
        script_dir = os.path.dirname(os.path.abspath(__file__))
        checkpoint_name = model_checkpoints.get(model_type, "sam2_hiera_tiny.pt")
        checkpoint_path = os.path.join(script_dir, "checkpoints", checkpoint_name)
        os.makedirs(os.path.dirname(checkpoint_path), exist_ok=True)

        if not os.path.exists(checkpoint_path):
            print(f"Downloading SAM model checkpoint ({model_type})...")
            download_checkpoint(checkpoint_path, model_type)
        else:
            print("Checkpoint found.")

        print("Loading SAM model into memory...")
        device = "mps" if torch.backends.mps.is_available() else "cpu"
        predictor = SAM2ImagePredictor(build_sam2(model_cfg, checkpoint_path, device=device))
        print(f"Self-test: Model loaded successfully on {device}")

        # Enhanced visual test
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

                # Click center
                cx, cy = w // 2, h // 2
                input_point = np.array([[cx, cy]])
                input_label = np.array([1])

                masks, scores, logits = predictor.predict(
                    point_coords=input_point,
                    point_labels=input_label,
                    multimask_output=True,
                )

            best_idx = np.argmax(scores)
            mask = masks[best_idx]
            print(f"Best mask index: {best_idx}, score: {scores[best_idx]:.4f}")
            print(f"Mask shape: {mask.shape}, coverage: {mask.sum() / mask.size * 100:.1f}%")

            # Save mask with alpha channel
            mask_255 = (mask * 255).astype(np.uint8)
            h_img, w_img = mask_255.shape
            rgba = np.zeros((h_img, w_img, 4), dtype=np.uint8)
            rgba[:, :, 0] = 200 # B
            rgba[:, :, 1] = 100 # G
            rgba[:, :, 2] = 50  # R
            rgba[:, :, 3] = mask_255 # Alpha

            output_mask_path = os.path.join(os.path.dirname(test_img_path), "self_test_mask.png")
            cv2.imwrite(output_mask_path, rgba)
            print(f"Visual self-test complete. Mask saved to {output_mask_path}")

        sys.exit(0)

    # Actual inference mode
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
    model_cfg = model_configs.get(model_type, "sam2_hiera_t.yaml")
    script_dir = os.path.dirname(os.path.abspath(__file__))
    checkpoint_name = model_checkpoints.get(model_type, "sam2_hiera_tiny.pt")
    checkpoint_path = os.path.join(script_dir, "checkpoints", checkpoint_name)
    os.makedirs(os.path.dirname(checkpoint_path), exist_ok=True)
    download_checkpoint(checkpoint_path, model_type)

    device = "mps" if torch.backends.mps.is_available() else "cpu"
    predictor = SAM2ImagePredictor(build_sam2(model_cfg, checkpoint_path, device=device))

    print(f"Processing image: {image_path}")
    image = ImageOps.exif_transpose(Image.open(image_path))
    image_np = np.array(image.convert("RGB"))
    h_img, w_img = image_np.shape[:2]
    print(f"Image dimensions: {w_img}x{h_img} (WxH)")
    print(f"Click coordinates: ({x}, {y})")

    # Validate coordinates are within image bounds
    if x < 0 or x >= w_img or y < 0 or y >= h_img:
        print(f"WARNING: Coordinates ({x}, {y}) are outside image bounds (0-{w_img-1}, 0-{h_img-1})")

    # Save debug image showing click point
    output_dir = os.path.dirname(output_path) if os.path.dirname(output_path) else "."
    save_debug_image(image_np, x, y, output_dir)

    with torch.inference_mode():
        predictor.set_image(image_np)

        input_point = np.array([[x, y]])
        input_label = np.array([1])

        print(f"Predicting mask at ({x}, {y})...")
        masks, scores, logits = predictor.predict(
            point_coords=input_point,
            point_labels=input_label,
            multimask_output=True,
        )

    # Select best mask
    best_idx = np.argmax(scores)
    mask = masks[best_idx]
    print(f"Selected mask {best_idx} with score {scores[best_idx]:.4f}")
    print(f"All scores: {[f'{s:.4f}' for s in scores]}")
    print(f"Mask shape: {mask.shape}, coverage: {mask.sum() / mask.size * 100:.1f}%")

    # Save mask with alpha channel
    mask_255 = (mask * 255).astype(np.uint8)
    h_mask, w_mask = mask_255.shape

    # Verify mask dimensions match input
    if h_mask != h_img or w_mask != w_img:
        print(f"WARNING: Mask dimensions ({w_mask}x{h_mask}) don't match image ({w_img}x{h_img})")

    rgba = np.zeros((h_mask, w_mask, 4), dtype=np.uint8)
    rgba[:, :, 0] = 200  # B (in BGR for cv2)
    rgba[:, :, 1] = 100  # G
    rgba[:, :, 2] = 50   # R
    rgba[:, :, 3] = mask_255  # Alpha

    cv2.imwrite(output_path, rgba)
    print(f"Mask saved to {output_path} ({w_mask}x{h_mask})")

if __name__ == "__main__":
    main()
