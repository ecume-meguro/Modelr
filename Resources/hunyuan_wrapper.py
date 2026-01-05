#!/usr/bin/env python3
"""
Hunyuan3D-2.1 Model Generation Wrapper for ModelrV3
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

from modelrv3_core import (
    get_logger,
    get_device,
    ModelConfig,
    log_info,
    log_error,
    log_debug,
    log_warning,
    load_image,
    extract_foreground,
)
from modelrv3_core.exceptions import (
    ModelLoadError,
    GenerationError,
)

logger = get_logger("hunyuan_wrapper")
HUNYUAN_CACHE_DIR = ModelConfig.get_hunyuan_cache_dir()

class HunyuanGenerator:
    """Manages Hunyuan3D model generation."""
    
    def __init__(self, model_variant: str = "std"):
        self.model_variant = model_variant
        self.pipeline = None
        self.device = get_device()

    def load(self):
        """Load the pipeline."""
        try:
            from hy3dgen.shapegen import Hunyuan3DDiTFlowMatchingPipeline

            repo_map = {
                "mini": ("tencent/Hunyuan3D-2mini", "hunyuan3d-dit-v2-mini", True),
                "std": ("tencent/Hunyuan3D-2.1", "hunyuan3d-dit-v2-1", False),
            }

            repo_id, subfolder, use_safetensors = repo_map.get(self.model_variant, repo_map["std"])
            log_info(f"Loading Hunyuan3D pipeline: {repo_id}/{subfolder}")

            self.pipeline = Hunyuan3DDiTFlowMatchingPipeline.from_pretrained(
                repo_id,
                subfolder=subfolder,
                device=self.device,
                use_safetensors=use_safetensors,
                cache_dir=str(HUNYUAN_CACHE_DIR),
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
    parser.add_argument("--model", default="std", choices=["mini", "std"], help="Model variant")
    parser.add_argument("--image", help="Input image path")
    parser.add_argument("--mask", help="Mask image path")
    parser.add_argument("--output", help="Output path")
    parser.add_argument("--steps", type=int, default=50, help="Diffusion steps")
    parser.add_argument("--resolution", type=int, default=384, help="Octree resolution")

    args = parser.parse_args()

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