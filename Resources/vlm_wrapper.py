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

# Model configuration
MODEL_ID = "mlx-community/Qwen3-VL-2B-Instruct-4bit"  # For reference only
DEFAULT_PROMPT = "State the common name of the item shown. Max 2 words. Do not be specific. Do not denote items by brand, name, etc. E.g Tesla should be Car, Bumblebee (transformers) should be robot, do not use names."

# Image resize settings for faster inference
# 384x384 is the sweet spot: ~100ms inference vs 50s at full resolution
MAX_IMAGE_SIZE = 384


def get_model_path() -> Path:
    """Get the local model path from environment or default."""
    models_dir = os.environ.get("MODELR_MODELS_DIR")
    if models_dir:
        return Path(models_dir) / "vlm"
    return Path.home() / "Library" / "Application Support" / "Modelr" / "models" / "vlm"


class VLMServer(BaseModelServer):
    """Vision Language Model server for object detection/description."""

    def __init__(self):
        self.model_path = get_model_path()
        super().__init__("vlm_wrapper", str(self.model_path))
        self.model = None
        self.vlm_processor = None
        self.current_image_path: Optional[str] = None

    def load_model(self) -> Tuple[Any, str]:
        """Load the MLX VLM model from local path."""
        try:
            log_info(f"Loading VLM model from: {self.model_path}", self.logger)

            if not self.model_path.exists():
                raise ModelLoadError(f"Model not found at {self.model_path}. Run model_downloader.py first.")

            from mlx_vlm import load

            # Load from local path
            self.model, self.vlm_processor = load(str(self.model_path))

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


def emit_progress(stage: str, **kwargs):
    """Emit JSON progress in the same format as model_downloader.py."""
    print(json.dumps({"stage": stage, "ts": time.time(), "model": "vlm", **kwargs}), flush=True)


def verify_model():
    """Check if VLM model files are present locally. No loading - just file verification."""
    model_path = get_model_path()

    emit_progress("checking")

    if not model_path.exists():
        emit_progress("error", message=f"Model not found at {model_path}")
        print(f"Error: VLM model not found at {model_path}", file=sys.stderr)
        print("Run: python model_downloader.py download --model vlm", file=sys.stderr)
        sys.exit(1)

    # Check for required files (skip actual loading - that's tested when server starts)
    required_files = ["model.safetensors", "config.json", "tokenizer.json"]
    missing = [f for f in required_files if not (model_path / f).exists()]

    if missing:
        emit_progress("error", message=f"Missing files: {missing}")
        print(f"Error: Missing VLM files: {missing}", file=sys.stderr)
        print("Run: python model_downloader.py download --model vlm", file=sys.stderr)
        sys.exit(1)

    # Verify model.safetensors has reasonable size (>100MB)
    model_file = model_path / "model.safetensors"
    if model_file.stat().st_size < 100_000_000:
        emit_progress("error", message="model.safetensors appears incomplete")
        print("Error: model.safetensors appears incomplete", file=sys.stderr)
        sys.exit(1)

    emit_progress("complete", cached=True, path=str(model_path))
    print(f"VLM model files verified at {model_path}")


def main():
    if "--get-size" in sys.argv:
        size_str = get_model_size_formatted("vlm-qwen3")
        print(f"SIZE:{size_str}", flush=True)
        return

    if "--verify" in sys.argv or "--warmup" in sys.argv:
        # --warmup kept for backwards compat, now just verifies
        verify_model()
        return

    if "--server" in sys.argv:
        server = VLMServer()
        server.run()
        return

    if "--test" in sys.argv:
        print("Testing VLM model loading...")
        server = VLMServer()
        server.initialize()
        print("VLM model loaded successfully!")

        for i, arg in enumerate(sys.argv):
            if arg == "--image" and i + 1 < len(sys.argv):
                image_path = sys.argv[i + 1]
                result = server.handle_describe({"imagePath": image_path})
                print(f"Description: {result.get('description', 'N/A')}")
                print(f"Raw output: {result.get('rawOutput', 'N/A')}")
        return

    print("Usage: vlm_wrapper.py --server | --verify | --test [--image <path>]")
    print(f"Model path: {get_model_path()}")


if __name__ == "__main__":
    main()
