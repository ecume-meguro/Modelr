#!/usr/bin/env python3
"""
MLX SAM3 Wrapper for Modelr
=============================
Refactored using BaseModelServer for modularity.
"""

import os
import sys
import json
import gc
from typing import Optional, List, Tuple, Dict, Any

import numpy as np
from PIL import Image, ImageDraw

# MLX imports
from sam3 import build_sam3_image_model
from sam3.model.sam3_image_processor import Sam3Processor

from modelr_core import (
    BaseModelServer,
    get_logger,
    log_info,
    log_debug,
    save_mask_rgba,
    get_model_size_formatted,
)
from modelr_core.exceptions import ModelLoadError, ImageValidationError

class SAM3Server(BaseModelServer):
    def __init__(self, model_type: str = "default", output_dir: str = ".", checkpoint_path: Optional[str] = None):
        super().__init__("sam_wrapper", model_type)
        self.output_dir = output_dir
        self.checkpoint_path = checkpoint_path

    def load_model(self) -> Tuple[Sam3Processor, str]:
        """Load the MLX SAM3 model."""
        try:
            log_info("Building MLX SAM3 model...", self.logger)
            if self.checkpoint_path:
                log_info(f"Using local checkpoint: {self.checkpoint_path}", self.logger)
                model = build_sam3_image_model(checkpoint_path=self.checkpoint_path)
            else:
                model = build_sam3_image_model()
            processor = Sam3Processor(model, confidence_threshold=0.5)
            return processor, "mlx"
        except Exception as e:
            raise ModelLoadError(f"Failed to load MLX model: {e}")

    def prepare_image(self, image: Image.Image) -> Any:
        """Set image in processor (computes backbone features)."""
        return self.processor.set_image(image)

    def perform_prediction(self, request: Dict[str, Any]) -> Dict[str, Any]:
        """Run SAM3 segmentation."""
        points = request.get("points", [])
        labels = request.get("labels", [])
        box = request.get("box")
        text_prompt = request.get("text")

        # Reset prompts for new prediction
        self.processor.reset_all_prompts(self.inference_state)

        h, w = self.current_image_np.shape[:2]

        # Apply text prompt (required for SAM3 to work well)
        if text_prompt:
            self.inference_state = self.processor.set_text_prompt(
                text_prompt, self.inference_state
            )
        elif points or box:
            # SAM3 needs a text prompt to anchor the segmentation
            # Use "visual" as a dummy prompt for geometric-only queries
            self.inference_state = self.processor.set_text_prompt(
                "object", self.inference_state
            )

        # Convert point prompts to small box prompts (MLX SAM3 doesn't support points directly)
        # Each point becomes a small box centered at that location
        point_box_size = 0.02  # 2% of image dimension
        for pt, label in zip(points, labels):
            cx, cy = pt[0] / w, pt[1] / h
            # Create a small box around the point
            self.inference_state = self.processor.add_geometric_prompt(
                [cx, cy, point_box_size, point_box_size],
                bool(label),  # True for positive, False for negative
                self.inference_state
            )

        # Apply box prompt (convert to center format, normalized)
        if box and len(box) >= 4:
            x1, y1, x2, y2 = box[:4]
            cx, cy = (x1 + x2) / 2 / w, (y1 + y2) / 2 / h
            bw, bh = (x2 - x1) / w, (y2 - y1) / h
            self.inference_state = self.processor.add_geometric_prompt(
                [cx, cy, bw, bh], True, self.inference_state
            )
        
        # Get results
        masks = self.inference_state.get("masks")
        scores = self.inference_state.get("scores")
        
        if masks is None or scores is None:
            return {"success": False, "error": "No masks generated"}
            
        masks_np = np.array(masks)
        scores_np = np.array(scores)
        
        if len(masks_np.shape) == 2:
            masks_np = masks_np[None, ...]
            
        mask_paths = []
        for i in range(len(masks_np)):
            mask_path = os.path.join(self.output_dir, f"mask_{i}.png")
            save_mask_rgba(masks_np[i], mask_path)
            mask_paths.append(mask_path)
            
        # Optional debug visualization
        self.save_debug_image(points, box)
        
        indices = np.argsort(scores_np)[::-1].tolist()
        
        return {
            "success": True,
            "masks": [mask_paths[i] for i in indices],
            "scores": [float(scores_np[i]) for i in indices],
            "selectedIndex": 0
        }

    def save_debug_image(self, points: List[List[float]], box: Optional[List[float]]):
        """Save debug visualization."""
        try:
            debug_img = Image.fromarray(self.current_image_np)
            draw = ImageDraw.Draw(debug_img)
            pr = 15
            for p in points:
                if len(p) >= 2:
                    draw.ellipse([p[0]-pr, p[1]-pr, p[0]+pr, p[1]+pr], outline="lime", width=3)
            if box and len(box) >= 4:
                draw.rectangle(box[:4], outline="cyan", width=3)
            
            os.makedirs(self.output_dir, exist_ok=True)
            debug_img.save(os.path.join(self.output_dir, "debug_click_point.png"))
        except Exception as e:
            log_debug(f"Failed to save debug image: {e}", self.logger)

def main():
    # Parse common arguments
    checkpoint_path = None
    output_dir = "."
    for i, arg in enumerate(sys.argv):
        if arg == "--checkpoint" and i + 1 < len(sys.argv):
            checkpoint_path = sys.argv[i + 1]
        elif arg == "--output-dir" and i + 1 < len(sys.argv):
            output_dir = sys.argv[i + 1]

    if "--get-size" in sys.argv:
        size_str = get_model_size_formatted("sam3")
        print(f"SIZE:{size_str}", flush=True)
        return
    elif "--server" in sys.argv:
        server = SAM3Server(output_dir=output_dir, checkpoint_path=checkpoint_path)
        server.run()
    elif "--test" in sys.argv:
        # Simplified test mode
        server = SAM3Server(checkpoint_path=checkpoint_path)
        server.initialize()
        print("Model loaded successfully")
    else:
        print("Usage: sam_wrapper.py --server [--output-dir <path>] [--checkpoint <path>] | --get-size | --test")

if __name__ == "__main__":
    main()