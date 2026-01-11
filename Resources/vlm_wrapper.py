#!/usr/bin/env python3
"""
MLX VLM Wrapper for Modelr
============================
Vision Language Model server for auto-detecting objects in images.
Uses Qwen3-VL-2B-Instruct-4bit via mlx-vlm for fast on-device inference.
"""

import os
import sys
import json
import time
import gc
from typing import Optional, Dict, Any, Tuple
from pathlib import Path

from PIL import Image

from modelr_core import (
    BaseModelServer,
    get_logger,
    log_info,
    log_debug,
    log_error,
    get_model_size_formatted,
)
from modelr_core.exceptions import ModelLoadError

# Default model and prompt
MODEL_ID = "mlx-community/Qwen3-VL-2B-Instruct-4bit"
# For Qwen3-VL, the prompt needs image tokens inserted via chat template
DEFAULT_PROMPT = "State the common name of the item shown. Max 2 words. Do not be specific. Do not denote items by brand, name, etc. E.g Tesla should be Car, Bumblebee (transformers) should be robot, do not use names."

# Qwen3-VL specific tokens
VISION_START = "<|vision_start|>"
IMAGE_PAD = "<|image_pad|>"
VISION_END = "<|vision_end|>"

# Image resize settings for faster inference
# 384x384 is the sweet spot: ~100ms inference vs 50s at full resolution
MAX_IMAGE_SIZE = 384


class VLMServer(BaseModelServer):
    """Vision Language Model server for object detection/description."""

    def __init__(self, model_id: str = MODEL_ID):
        super().__init__("vlm_wrapper", model_id)
        self.model_id = model_id
        self.model = None
        self.vlm_processor = None
        self.current_image_path: Optional[str] = None

    def load_model(self) -> Tuple[Any, str]:
        """Load the MLX VLM model."""
        try:
            log_info(f"Loading VLM model: {self.model_id}", self.logger)

            from mlx_vlm import load

            self.model, self.vlm_processor = load(self.model_id)

            log_info("VLM model loaded successfully", self.logger)
            return self.vlm_processor, "mlx"
        except Exception as e:
            raise ModelLoadError(f"Failed to load VLM model: {e}")

    def prepare_image(self, image: Image.Image) -> Any:
        """Store the current image for later use."""
        # Just store the PIL image - mlx_vlm.generate handles processing
        return image

    def handle_set_image(self, request: Dict[str, Any]) -> Dict[str, Any]:
        """Handle set_image command - store path for describe command."""
        image_path = request.get("imagePath")
        if not image_path or not os.path.exists(image_path):
            return {"success": False, "error": "Image not found"}

        self.current_image_path = image_path

        # Get image dimensions
        try:
            with Image.open(image_path) as img:
                w, h = img.size
            return {"success": True, "width": w, "height": h}
        except Exception as e:
            log_error(f"Error loading image: {e}", self.logger)
            return {"success": False, "error": str(e)}

    def perform_prediction(self, request: Dict[str, Any]) -> Dict[str, Any]:
        """Not used - we use handle_describe instead."""
        return {"success": False, "error": "Use 'describe' command instead"}

    def _resize_image_for_inference(self, image_path: str) -> Image.Image:
        """Resize image for faster inference while maintaining aspect ratio.

        384x384 is the sweet spot: ~100ms inference vs 50s at full resolution.
        """
        img = Image.open(image_path)

        # Convert to RGB if necessary (handles RGBA, P mode, etc.)
        if img.mode != "RGB":
            img = img.convert("RGB")

        # Only resize if larger than MAX_IMAGE_SIZE
        if max(img.size) > MAX_IMAGE_SIZE:
            # Use thumbnail to maintain aspect ratio
            img.thumbnail((MAX_IMAGE_SIZE, MAX_IMAGE_SIZE), Image.Resampling.LANCZOS)
            log_debug(f"Resized image from original to {img.size}", self.logger)

        return img

    def handle_describe(self, request: Dict[str, Any]) -> Dict[str, Any]:
        """Describe the current or specified image."""
        image_path = request.get("imagePath", self.current_image_path)
        prompt = request.get("prompt", DEFAULT_PROMPT)
        max_tokens = request.get("maxTokens", 10)
        temperature = request.get("temperature", 0.0)

        if not image_path or not os.path.exists(image_path):
            return {"success": False, "error": "No image set or image not found"}

        try:
            start_time = time.time()

            # Resize image for faster inference (384x384 optimal)
            resized_image = self._resize_image_for_inference(image_path)

            # For Qwen3-VL, we need to use the processor's chat template to properly
            # format the prompt with image tokens
            messages = [
                {
                    "role": "user",
                    "content": [
                        {"type": "image"},
                        {"type": "text", "text": prompt}
                    ]
                }
            ]

            # Apply chat template to get properly formatted prompt with image tokens
            formatted_prompt = self.vlm_processor.apply_chat_template(
                messages, tokenize=False, add_generation_prompt=True
            )

            log_debug(f"Formatted prompt: {formatted_prompt[:200]}", self.logger)

            from mlx_vlm import generate

            # Generate description using resized PIL image
            result = generate(
                self.model,
                self.vlm_processor,
                formatted_prompt,
                image=resized_image,
                max_tokens=max_tokens,
                temperature=temperature,
            )
            # Result is a GenerationResult object, extract the text
            output = result.text if hasattr(result, 'text') else str(result)

            # Clean up the output - extract just the object name
            description = self._clean_description(output)

            inference_time = int((time.time() - start_time) * 1000)

            log_info(f"VLM output: '{output}' -> '{description}' ({inference_time}ms)", self.logger)

            return {
                "success": True,
                "description": description,
                "rawOutput": output,
                "inferenceTimeMs": inference_time,
            }
        except Exception as e:
            log_error(f"Description error: {e}", self.logger)
            return {"success": False, "error": str(e)}

    def _clean_description(self, raw_output: str) -> str:
        """Clean VLM output to get a short object name."""
        # Remove common prefixes/suffixes the model might add
        text = raw_output.strip()

        # Remove quotes if present
        if text.startswith('"') and text.endswith('"'):
            text = text[1:-1]
        if text.startswith("'") and text.endswith("'"):
            text = text[1:-1]

        # Take only first 2 words (as per our prompt)
        words = text.split()
        if len(words) > 2:
            text = " ".join(words[:2])

        # Capitalize properly
        text = text.strip().title()

        return text

    def handle_name(self, request: Dict[str, Any]) -> Dict[str, Any]:
        """Generate a short descriptive project name for an image."""
        image_path = request.get("imagePath", self.current_image_path)

        if not image_path or not os.path.exists(image_path):
            return {"success": False, "error": "No image set or image not found"}

        # Prompt designed to get a short, descriptive name suitable for a project
        name_prompt = (
            "Give a short descriptive name for this image (2-4 words). "
            "Focus on the main subject. Be specific but concise. "
            "Examples: 'Blue Sports Car', 'Golden Retriever Puppy', 'Vintage Coffee Mug'. "
            "Just output the name, nothing else."
        )

        try:
            start_time = time.time()

            # Resize image for faster inference
            resized_image = self._resize_image_for_inference(image_path)

            messages = [
                {
                    "role": "user",
                    "content": [
                        {"type": "image"},
                        {"type": "text", "text": name_prompt}
                    ]
                }
            ]

            formatted_prompt = self.vlm_processor.apply_chat_template(
                messages, tokenize=False, add_generation_prompt=True
            )

            from mlx_vlm import generate

            result = generate(
                self.model,
                self.vlm_processor,
                formatted_prompt,
                image=resized_image,
                max_tokens=15,  # Allow slightly more tokens for descriptive name
                temperature=0.3,  # Small creativity for better names
            )

            output = result.text if hasattr(result, 'text') else str(result)

            # Clean up the name
            name = self._clean_project_name(output)

            inference_time = int((time.time() - start_time) * 1000)

            log_info(f"VLM name: '{output}' -> '{name}' ({inference_time}ms)", self.logger)

            return {
                "success": True,
                "description": name,
                "rawOutput": output,
                "inferenceTimeMs": inference_time,
            }
        except Exception as e:
            log_error(f"Name generation error: {e}", self.logger)
            return {"success": False, "error": str(e)}

    def _clean_project_name(self, raw_output: str) -> str:
        """Clean VLM output to get a suitable project name."""
        text = raw_output.strip()

        # Remove quotes if present
        if text.startswith('"') and text.endswith('"'):
            text = text[1:-1]
        if text.startswith("'") and text.endswith("'"):
            text = text[1:-1]

        # Remove common prefixes the model might add
        prefixes_to_remove = [
            "the name is ", "name: ", "project name: ", "title: ",
            "a ", "an ", "the "
        ]
        text_lower = text.lower()
        for prefix in prefixes_to_remove:
            if text_lower.startswith(prefix):
                text = text[len(prefix):]
                text_lower = text.lower()

        # Take first 4 words max
        words = text.split()
        if len(words) > 4:
            text = " ".join(words[:4])

        # Title case and clean
        text = text.strip().title()

        return text

    def handle_custom_command(self, command: str, request: Dict[str, Any]) -> Dict[str, Any]:
        """Handle VLM-specific commands."""
        if command == "describe":
            return self.handle_describe(request)
        elif command == "name":
            return self.handle_name(request)
        return {"success": False, "error": f"Unknown command: {command}"}


def warmup_model():
    """Pre-download the model weights."""
    log_info("Warming up VLM model...")
    try:
        from mlx_vlm import load
        model, processor = load(MODEL_ID)
        del model, processor
        gc.collect()
        log_info("VLM warmup complete")
    except Exception as e:
        log_error(f"VLM warmup failed: {e}")
        sys.exit(1)


def main():
    if "--get-size" in sys.argv:
        size_str = get_model_size_formatted("vlm-qwen3")
        print(f"SIZE:{size_str}", flush=True)
        return

    if "--warmup" in sys.argv:
        warmup_model()
        return

    if "--server" in sys.argv:
        server = VLMServer()
        server.run()
        return

    if "--test" in sys.argv:
        # Quick test - load model and run a test inference
        print("Testing VLM model loading...")
        server = VLMServer()
        server.initialize()
        print("VLM model loaded successfully!")

        # Test with a sample image if provided
        for i, arg in enumerate(sys.argv):
            if arg == "--image" and i + 1 < len(sys.argv):
                image_path = sys.argv[i + 1]
                result = server.handle_describe({"imagePath": image_path})
                print(f"Description: {result.get('description', 'N/A')}")
                print(f"Raw output: {result.get('rawOutput', 'N/A')}")
        return

    print("Usage: vlm_wrapper.py --server | --warmup | --get-size | --test [--image <path>]")


if __name__ == "__main__":
    main()
