import os
import sys
import torch
import numpy as np
import cv2
from PIL import Image
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

def main():
    if "--test" in sys.argv:
        print("Model: SAM2 (Hiera Base Plus)")
        print("Checking for model checkpoint...")
        model_cfg = "sam2_hiera_b+.yaml"
        script_dir = os.path.dirname(os.path.abspath(__file__))
        checkpoint_path = os.path.join(script_dir, "checkpoints", "sam2_hiera_base_plus.pt")
        os.makedirs(os.path.dirname(checkpoint_path), exist_ok=True)
        
        if not os.path.exists(checkpoint_path):
            print("Downloading SAM model checkpoint...")
            download_checkpoint(checkpoint_path, "base_plus")
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
            image = Image.open(test_img_path)
            w, h = image.size
            print(f"Image dimensions: {w}x{h}")
            
            image_np = np.array(image.convert("RGB"))
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
            
            # Save mask with alpha channel (Light Sky Blue mask with mask alpha)
            mask_255 = (mask * 255).astype(np.uint8)
            h_img, w_img = mask_255.shape
            rgba = np.zeros((h_img, w_img, 4), dtype=np.uint8)
            rgba[:, :, 0] = 250 # B: Light Sky Blue
            rgba[:, :, 1] = 206 # G
            rgba[:, :, 2] = 135 # Red
            rgba[:, :, 3] = mask_255 # Alpha
            
            output_mask_path = os.path.join(os.path.dirname(test_img_path), "self_test_mask.png")
            cv2.imwrite(output_mask_path, rgba)
            print(f"Visual self-test complete. Mask saved to {output_mask_path}")
            
        sys.exit(0)

    if len(sys.argv) < 4:
        print("Usage: python sam_wrapper.py <image_path> <x> <y> [output_path]")
        sys.exit(1)

    image_path = sys.argv[1]
    x = int(sys.argv[2])
    y = int(sys.argv[3])
    output_path = sys.argv[4] if len(sys.argv) > 4 else "mask.png"

    print(f"Loading model (Hiera Base Plus)...")
    model_cfg = "sam2_hiera_b+.yaml"
    script_dir = os.path.dirname(os.path.abspath(__file__))
    checkpoint_path = os.path.join(script_dir, "checkpoints", "sam2_hiera_base_plus.pt")
    os.makedirs(os.path.dirname(checkpoint_path), exist_ok=True)
    download_checkpoint(checkpoint_path, "base_plus")
    
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    predictor = SAM2ImagePredictor(build_sam2(model_cfg, checkpoint_path, device=device))

    print(f"Processing image: {image_path}")
    image = Image.open(image_path)
    image_np = np.array(image.convert("RGB"))
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

    # Save mask with alpha channel (Light Sky Blue mask)
    mask_255 = (mask * 255).astype(np.uint8)
    h_img, w_img = mask_255.shape
    rgba = np.zeros((h_img, w_img, 4), dtype=np.uint8)
    rgba[:, :, 0] = 250
    rgba[:, :, 1] = 206
    rgba[:, :, 2] = 135
    rgba[:, :, 3] = mask_255
    
    cv2.imwrite(output_path, rgba)
    print(f"Mask saved to {output_path}")

if __name__ == "__main__":
    main()
