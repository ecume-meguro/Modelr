#!/usr/bin/env python3
"""
MLX SAM3 Wrapper for ModelrV3
=============================

This module provides a Python wrapper around the MLX SAM3 (Segment Anything Model 3)
for use with the ModelrV3 macOS application. It supports:
- Text-based segmentation prompts
- Point prompts (positive/negative)
- Box prompts
- Interactive server mode for persistent session

Optimized for Apple Silicon using MLX framework.
"""

import os
import sys
import json
import time
import gc
from typing import Optional, Callable, List, Tuple, Dict, Any
from pathlib import Path

import numpy as np
import cv2
from PIL import Image, ImageOps, ImageDraw

# MLX imports
import mlx.core as mx
from sam3 import build_sam3_image_model
from sam3.model.sam3_image_processor import Sam3Processor

from modelrv3_core import (
    get_logger,
    validate_image_path,
    validate_coordinates,
    validate_image_dimensions,
    check_gpu_available,
    health_check,
    get_device,
    ModelConfig,
    PerformanceConfig,
    metrics,
    log_info,
    log_error,
    log_debug,
    log_warning,
    load_image,
    save_mask_rgba,
)
from modelrv3_core.exceptions import (
    ModelLoadError,
    ImageValidationError,
    OutOfMemoryError,
)

logger = get_logger("sam_wrapper")


class ModelManager:
    """Manages MLX SAM3 model lifecycle."""
    
    def __init__(self, model_type: str = "default", script_dir: str = ""):
        self.model_type = model_type
        self.script_dir = script_dir
        self.model = None
        self.processor: Optional[Sam3Processor] = None
        self.device: str = "mlx"

    def load(self) -> Tuple[Sam3Processor, str]:
        """Load the MLX SAM3 model."""
        try:
            log_info("Building MLX SAM3 model...")
            
            # Build MLX SAM3 - weights auto-download from HuggingFace
            self.model = build_sam3_image_model()
            self.processor = Sam3Processor(self.model, confidence_threshold=0.5)

            log_info("MLX SAM3 Model loaded successfully on Apple Silicon")
            return self.processor, self.device

        except Exception as e:
            raise ModelLoadError(f"Failed to load MLX model: {e}")

    def cleanup(self) -> None:
        """Cleanup model resources."""
        self.processor = None
        self.model = None
        gc.collect()
        log_debug("Model cleanup complete")

    def __enter__(self):
        self.load()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.cleanup()


def load_predictor(
    model_type: str = "default",
    script_dir: str = "",
    progress_callback: Optional[Callable[[int, int], None]] = None,
) -> Tuple[Sam3Processor, str]:
    """Load the SAM3 predictor."""
    manager = ModelManager(model_type, script_dir)
    return manager.load()


def save_mask(mask: np.ndarray, output_path: str) -> str:
    """Save mask as RGBA PNG with alpha channel."""
    try:
        return save_mask_rgba(mask, output_path)
    except Exception as e:
        raise ImageValidationError(f"Failed to save mask: {e}")


def save_debug_image(
    image_np: np.ndarray,
    points: List[List[float]],
    box: Optional[List[float]],
    output_dir: str,
) -> str:
    """Save debug visualization with points and boxes."""
    try:
        debug_img = Image.fromarray(image_np)
        draw = ImageDraw.Draw(debug_img)
        
        # Draw points
        point_radius = 15
        for point in points:
            if len(point) >= 2:
                x, y = point[0], point[1]
                draw.ellipse(
                    [x - point_radius, y - point_radius, x + point_radius, y + point_radius],
                    outline="lime",
                    width=3,
                )
        
        # Draw box
        if box is not None and len(box) >= 4:
            draw.rectangle(box[:4], outline="cyan", width=3)
        
        os.makedirs(output_dir, exist_ok=True)
        debug_path = os.path.join(output_dir, "debug_click_point.png")
        debug_img.save(debug_path)
        return debug_path
    except Exception as e:
        log_warning(f"Failed to save debug image: {e}")
        return ""


def server_mode(model_type: str, script_dir: str, output_dir: str) -> None:
    """
    Run in server mode, processing JSON commands from stdin.
    
    Commands:
    - set_image: Load an image for segmentation
    - predict: Run segmentation with text/point/box prompts
    - ping: Health check
    - exit: Shutdown server
    """
    log_info(f"Starting MLX SAM3 server mode")
    
    try:
        processor, device = load_predictor(model_type, script_dir)
        current_image_np: Optional[np.ndarray] = None
        image_set = False
        inference_state: Optional[Dict] = None

        # Signal ready
        print(json.dumps({"success": True, "ready": True, "device": device}), flush=True)

        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            
            try:
                request = json.loads(line)
                command = request.get("command", "")

                if command == "set_image":
                    image_path = request.get("imagePath")
                    if not image_path or not os.path.exists(image_path):
                        response = {"success": False, "error": "Image not found"}
                    else:
                        try:
                            # Use centralized load_image
                            image = load_image(image_path)
                            current_image_np = np.array(image)
                            
                            # Set image in processor (computes backbone features)
                            inference_state = processor.set_image(image)
                            image_set = True
                            
                            h, w = current_image_np.shape[:2]
                            response = {"success": True, "width": w, "height": h}
                        except Exception as e:
                            response = {"success": False, "error": str(e)}

                elif command == "predict":
                    if not image_set or inference_state is None:
                        response = {"success": False, "error": "No image set"}
                    else:
                        start_time = time.time()
                        
                        points = request.get("points", [])
                        labels = request.get("labels", [])
                        box = request.get("box")
                        text_prompt = request.get("text")

                        try:
                            # Reset prompts for new prediction
                            processor.reset_all_prompts(inference_state)
                            
                            h, w = current_image_np.shape[:2]
                            
                            # Apply text prompt if provided
                            if text_prompt:
                                inference_state = processor.set_text_prompt(
                                    text_prompt, inference_state
                                )
                            
                            # Apply point prompts (normalized to [0,1])
                            for pt, label in zip(points, labels):
                                normalized_pt = [pt[0] / w, pt[1] / h]
                                inference_state = processor.add_point_prompt(
                                    normalized_pt, int(label), inference_state
                                )
                            
                            # Apply box prompt (convert to center format, normalized)
                            if box and len(box) >= 4:
                                x1, y1, x2, y2 = box[:4]
                                cx = (x1 + x2) / 2 / w
                                cy = (y1 + y2) / 2 / h
                                bw = (x2 - x1) / w
                                bh = (y2 - y1) / h
                                inference_state = processor.add_geometric_prompt(
                                    [cx, cy, bw, bh], True, inference_state
                                )
                            
                            # Get results
                            masks = inference_state.get("masks")
                            scores = inference_state.get("scores")
                            
                            if masks is None or scores is None:
                                response = {"success": False, "error": "No masks generated"}
                            else:
                                # Convert MLX arrays to numpy
                                masks_np = np.array(masks)
                                scores_np = np.array(scores)
                                
                                # Ensure correct shape
                                if len(masks_np.shape) == 2:
                                    masks_np = masks_np[None, ...]
                                
                                # Save masks
                                mask_paths = []
                                for i in range(len(masks_np)):
                                    mask_path = os.path.join(output_dir, f"mask_{i}.png")
                                    save_mask(masks_np[i], mask_path)
                                    mask_paths.append(mask_path)
                                
                                # Save debug image
                                save_debug_image(current_image_np, points, box, output_dir)
                                
                                # Sort by score descending
                                indices = np.argsort(scores_np)[::-1].tolist()
                                
                                inference_time = int((time.time() - start_time) * 1000)
                                
                                response = {
                                    "success": True,
                                    "masks": [mask_paths[i] for i in indices],
                                    "scores": [float(scores_np[i]) for i in indices],
                                    "selectedIndex": 0,
                                    "inferenceTimeMs": inference_time
                                }

                        except Exception as e:
                            log_error(f"Prediction error: {e}")
                            import traceback
                            traceback.print_exc()
                            response = {"success": False, "error": str(e)}

                elif command == "ping":
                    response = {"success": True, "status": "pong", "device": device}

                elif command == "exit":
                    response = {"success": True, "status": "exiting"}
                    print(json.dumps(response), flush=True)
                    break

                else:
                    response = {"success": False, "error": f"Unknown command: {command}"}

                print(json.dumps(response), flush=True)

            except json.JSONDecodeError as e:
                error_response = {"success": False, "error": f"Invalid JSON: {e}"}
                print(json.dumps(error_response), flush=True)
            except Exception as e:
                log_error(f"Request handling error: {e}")
                error_response = {"success": False, "error": str(e)}
                print(json.dumps(error_response), flush=True)

    except Exception as e:
        log_error(f"Fatal server error: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)


def cli_mode():
    """Run in CLI mode for single-shot segmentation."""
    if len(sys.argv) < 4:
        print("Usage: sam_wrapper.py <image> <x> <y> [output]")
        print("       sam_wrapper.py <image> --text <prompt> [output]")
        return
    
    image_path = sys.argv[1]
    output_path = "mask.png"
    
    try:
        processor, device = load_predictor("default", ".")
        image = ImageOps.exif_transpose(Image.open(image_path))
        w, h = image.size
        
        state = processor.set_image(image)
        
        # Check for text mode
        if "--text" in sys.argv:
            text_idx = sys.argv.index("--text")
            if text_idx + 1 < len(sys.argv):
                text_prompt = sys.argv[text_idx + 1]
                state = processor.set_text_prompt(text_prompt, state)
                if text_idx + 2 < len(sys.argv):
                    output_path = sys.argv[text_idx + 2]
        else:
            # Point mode
            x, y = int(sys.argv[2]), int(sys.argv[3])
            if len(sys.argv) > 4:
                output_path = sys.argv[4]
            state = processor.add_point_prompt([x/w, y/h], 1, state)
        
        masks = np.array(state.get("masks", []))
        if len(masks) > 0:
            save_mask(masks[0], output_path)
            print(f"Saved mask to {output_path}")
        else:
            print("No masks generated")
            
    except Exception as e:
        print(f"Error: {e}")
        import traceback
        traceback.print_exc()


def test_mode():
    """Run self-test to verify model loading."""
    print("=" * 50)
    print("MLX SAM3 Self-Test")
    print("=" * 50)
    
    try:
        print("\n[1/3] Loading model...")
        start = time.time()
        processor, device = load_predictor("default", ".")
        load_time = time.time() - start
        print(f"✓ Model loaded in {load_time:.2f}s on {device}")
        
        print("\n[2/3] Testing image processing...")
        # Create a test image
        test_img = Image.new("RGB", (512, 512), color=(128, 128, 128))
        start = time.time()
        state = processor.set_image(test_img)
        img_time = time.time() - start
        print(f"✓ Image processing completed in {img_time:.2f}s")
        
        print("\n[3/3] Testing text prompt...")
        start = time.time()
        state = processor.set_text_prompt("object", state)
        prompt_time = time.time() - start
        
        masks = state.get("masks")
        scores = state.get("scores")
        print(f"✓ Text prompt inference in {prompt_time:.2f}s")
        if masks is not None:
            print(f"  → Generated {len(np.array(masks))} mask(s)")
        
        print("\n" + "=" * 50)
        print("All tests passed! MLX SAM3 is ready.")
        print("=" * 50)
        
    except Exception as e:
        print(f"\n✗ Test failed: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    if "--server" in sys.argv:
        output_dir = "."
        for i, arg in enumerate(sys.argv):
            if arg == "--output-dir" and i + 1 < len(sys.argv):
                output_dir = sys.argv[i + 1]
        server_mode("default", ".", output_dir)
    elif "--test" in sys.argv:
        test_mode()
    else:
        cli_mode()
