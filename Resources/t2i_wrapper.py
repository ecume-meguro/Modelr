#!/usr/bin/env python3
"""
Text-to-Image Generation Wrapper for Modelr
=============================================
Stable Diffusion 1.5 with PyTorch MPS for generating images from text prompts.
Supports both one-shot generation and persistent server mode.
"""

import os
import sys
import json
import argparse
import time
import gc
import traceback
import select
import threading
from typing import Optional, Callable, Dict, Any
from pathlib import Path

import torch
import numpy as np
from PIL import Image

# Import modelr_core utilities
from modelr_core import (
    get_logger,
    log_info,
    log_error,
    log_debug,
    log_warning,
)
from modelr_core.exceptions import (
    ModelLoadError,
    GenerationError,
)

logger = get_logger("t2i_wrapper")

# Default model - SDXL Turbo (good quality, fast 1-4 steps, ~6GB)
DEFAULT_MODEL = "stabilityai/sdxl-turbo"


def get_device():
    """Get the best available device for inference."""
    if torch.backends.mps.is_available():
        return "mps"
    elif torch.cuda.is_available():
        return "cuda"
    return "cpu"


def enhance_prompt_for_3d(prompt: str) -> str:
    """Enhance a user prompt for optimal 3D asset generation.

    Adds modifiers for:
    - Centered framing
    - Black background
    - Product photography style
    - Full object visibility
    """
    # Check if user already specified background
    has_background_spec = any(word in prompt.lower() for word in [
        "background", "backdrop", "studio", "isolated"
    ])

    # Build enhanced prompt
    enhanced_parts = [prompt.strip()]

    # Add 3D-friendly modifiers
    if not has_background_spec:
        enhanced_parts.append("isolated on solid black background")

    enhanced_parts.extend([
        "centered in frame",
        "full object visible",
        "product photography",
        "studio lighting",
        "high detail",
        "sharp focus"
    ])

    return ", ".join(enhanced_parts)


# Default negative prompt optimized for 3D asset generation
DEFAULT_NEGATIVE_PROMPT = (
    "background, scenery, environment, landscape, street, road, buildings, "
    "architecture, sky, clouds, grass, trees, people, text, watermark, "
    "cropped, cut off, out of frame, partial, blurry, low quality, "
    "distorted, deformed, ugly, duplicate"
)


class T2IGenerator:
    """Manages SDXL Turbo text-to-image generation with PyTorch MPS."""

    def __init__(self, model_id: str = DEFAULT_MODEL):
        self.model_id = model_id
        self.pipeline = None
        self.device = get_device()
        self.is_turbo = "turbo" in model_id.lower()

    def load(self):
        """Load the SDXL Turbo pipeline."""
        try:
            from diffusers import AutoPipelineForText2Image

            log_info(f"Loading SDXL Turbo: {self.model_id} on {self.device}")

            # Use float32 on MPS to avoid NaN issues in VAE decoding
            # CUDA can use float16, CPU uses float32
            if self.device == "mps":
                dtype = torch.float32
                variant = None  # Don't use fp16 variant for float32
            elif self.device == "cuda":
                dtype = torch.float16
                variant = "fp16"
            else:
                dtype = torch.float32
                variant = None

            self.pipeline = AutoPipelineForText2Image.from_pretrained(
                self.model_id,
                torch_dtype=dtype,
                variant=variant,
            )

            # Move to device
            self.pipeline = self.pipeline.to(self.device)

            # Enable memory optimizations
            if hasattr(self.pipeline, 'enable_attention_slicing'):
                self.pipeline.enable_attention_slicing()

            log_info("Stable Diffusion loaded successfully")
            return self.pipeline

        except ImportError as e:
            log_error(f"diffusers not available: {e}")
            raise ModelLoadError(f"diffusers import failed: {e}")
        except Exception as e:
            raise ModelLoadError(f"Failed to load Stable Diffusion: {e}")

    def generate(
        self,
        prompt: str,
        output_path: str,
        negative_prompt: str = "",
        width: int = 512,
        height: int = 512,
        num_steps: int = 4,  # SDXL Turbo only needs 1-4 steps
        guidance_scale: float = 0.0,  # Turbo doesn't need CFG
        seed: Optional[int] = None,
        progress_callback: Optional[Callable[[str, float, Optional[str]], None]] = None,
    ) -> str:
        """Generate an image from a text prompt.

        Args:
            prompt: Text description of the desired image
            output_path: Where to save the generated image
            negative_prompt: What to avoid in the image (ignored for Turbo models)
            width: Image width (default 512)
            height: Image height (default 512)
            num_steps: Number of diffusion steps (1-4 for Turbo)
            guidance_scale: CFG scale (0.0 for Turbo, higher for other models)
            seed: Random seed for reproducibility
            progress_callback: Optional callback for progress updates
        """
        if self.pipeline is None:
            self.load()

        try:
            # Set seed for reproducibility
            if seed is None:
                seed = int(time.time()) % (2**32)

            generator = torch.Generator(device=self.device).manual_seed(seed)

            # Enhance prompt for 3D asset generation
            enhanced_prompt = enhance_prompt_for_3d(prompt)

            # SDXL Turbo doesn't use negative prompts effectively
            # Only use negative prompt for non-turbo models
            if self.is_turbo:
                full_negative = None
                actual_guidance = 0.0  # Turbo works best with 0 CFG
                actual_steps = min(num_steps, 4)  # Cap at 4 for Turbo
            else:
                if negative_prompt:
                    full_negative = f"{DEFAULT_NEGATIVE_PROMPT}, {negative_prompt}"
                else:
                    full_negative = DEFAULT_NEGATIVE_PROMPT
                actual_guidance = guidance_scale
                actual_steps = num_steps

            log_info(f"Generating image: '{prompt[:50]}...' (steps={actual_steps}, cfg={actual_guidance})")
            log_info(f"Enhanced prompt: {enhanced_prompt[:100]}...")

            if progress_callback:
                progress_callback("Starting", 0.05, "Initializing...")

            # Create a callback for step progress
            def step_callback(pipe, step_index, timestep, callback_kwargs):
                if progress_callback:
                    step_progress = 0.1 + (step_index / actual_steps) * 0.75
                    progress_callback("Diffusion", step_progress, f"{step_index + 1}/{actual_steps}")
                return callback_kwargs

            # Generate the image
            with torch.inference_mode():
                result = self.pipeline(
                    prompt=enhanced_prompt,
                    negative_prompt=full_negative,
                    width=width,
                    height=height,
                    num_inference_steps=actual_steps,
                    guidance_scale=actual_guidance,
                    generator=generator,
                    callback_on_step_end=step_callback,
                )

            image = result.images[0]

            if progress_callback:
                progress_callback("Saving", 0.95, "Writing file...")

            # Ensure output directory exists
            Path(output_path).parent.mkdir(parents=True, exist_ok=True)

            # Save the image
            image.save(output_path)
            log_info(f"Image saved to: {output_path}")

            return output_path

        except Exception as e:
            raise GenerationError(f"Failed to generate image: {e}")

    def cleanup(self):
        """Release model from memory."""
        self.pipeline = None
        if torch.backends.mps.is_available():
            torch.mps.empty_cache()
        gc.collect()


class T2IServer:
    """Persistent server for text-to-image generation."""

    def __init__(self, model_id: str = DEFAULT_MODEL):
        self.model_id = model_id
        self.generator = None
        self.logger = get_logger("t2i_server")
        self._cancel_requested = False
        self._is_generating = False

    def initialize(self):
        """Load the model and prepare for generation requests."""
        log_info(f"Initializing T2I server with model: {self.model_id}", self.logger)
        self.generator = T2IGenerator(self.model_id)
        self.generator.load()
        log_info("T2I model loaded and ready", self.logger)

    def send_response(self, response: Dict[str, Any]):
        """Send a JSON response to stdout."""
        print(json.dumps(response), flush=True)

    def send_progress(self, message_id: str, stage: str, progress: float, detail: str = ""):
        """Send a progress update."""
        self.send_response({
            "success": True,
            "type": "progress",
            "messageId": message_id,
            "stage": stage,
            "progress": progress,
            "detail": detail
        })

    def handle_generate(self, request: Dict[str, Any]) -> Dict[str, Any]:
        """Handle a generation request."""
        message_id = request.get("messageId", "")
        prompt = request.get("prompt", "")
        negative_prompt = request.get("negativePrompt", "")
        output_path = request.get("outputPath")
        width = request.get("width", 512)
        height = request.get("height", 512)
        steps = request.get("steps", 20)
        guidance_scale = request.get("guidanceScale", 7.5)
        seed = request.get("seed")

        if not prompt:
            return {"success": False, "error": "Prompt required", "messageId": message_id}

        if not output_path:
            return {"success": False, "error": "Output path required", "messageId": message_id}

        # Reset cancel flag
        self._cancel_requested = False
        self._is_generating = True

        try:
            # Progress callback for reporting status to Swift
            def progress_callback(status: str, value: float, detail: Optional[str] = None):
                stage = "diffusion" if "Diffusion" in status else "encoding" if "Starting" in status else "saving"
                self.send_progress(message_id, stage, value, detail or "")

            self.send_progress(message_id, "encoding", 0.05, "Starting generation...")

            # Use seed or generate one
            actual_seed = seed if seed is not None else int(time.time()) % (2**32)

            result_path = self.generator.generate(
                prompt=prompt,
                output_path=output_path,
                negative_prompt=negative_prompt,
                width=width,
                height=height,
                num_steps=steps,
                guidance_scale=guidance_scale,
                seed=actual_seed,
                progress_callback=progress_callback,
            )

            self._is_generating = False
            return {
                "success": True,
                "type": "complete",
                "messageId": message_id,
                "imagePath": result_path,
                "seed": actual_seed
            }

        except GenerationError as e:
            self._is_generating = False
            if "cancelled" in str(e).lower():
                return {
                    "success": False,
                    "type": "cancelled",
                    "messageId": message_id,
                    "error": "Generation cancelled"
                }
            log_error(f"Generation error: {e}", self.logger)
            return {
                "success": False,
                "type": "error",
                "messageId": message_id,
                "error": str(e)
            }
        except Exception as e:
            self._is_generating = False
            log_error(f"Generation error: {e}", self.logger)
            log_debug(traceback.format_exc(), self.logger)
            return {
                "success": False,
                "type": "error",
                "messageId": message_id,
                "error": str(e)
            }

    def run(self):
        """Main server loop."""
        import queue

        command_queue = queue.Queue()

        def stdin_reader():
            """Read stdin in a separate thread."""
            stdin_fd = sys.stdin.fileno()
            try:
                while True:
                    ready, _, _ = select.select([stdin_fd], [], [], 0.1)
                    if ready:
                        line_bytes = sys.stdin.buffer.readline()
                        if not line_bytes:
                            break
                        line = line_bytes.decode('utf-8').strip()
                        if line:
                            command_queue.put(line)
            except Exception as e:
                print(f"[T2IServer] stdin_reader error: {e}", file=sys.stderr, flush=True)

        try:
            self.initialize()

            # Signal ready to Swift
            self.send_response({
                "success": True,
                "ready": True,
                "server": "t2i",
                "model": self.model_id,
                "device": self.generator.device
            })

            # Start the stdin reader thread
            reader_thread = threading.Thread(target=stdin_reader, daemon=True)
            reader_thread.start()

            while True:
                try:
                    line = command_queue.get()
                    request = json.loads(line)
                    command = request.get("command", "")

                    if command == "generate":
                        response = self.handle_generate(request)
                    elif command == "cancel":
                        self._cancel_requested = True
                        response = {
                            "success": True,
                            "type": "cancelled",
                            "message": "Cancel requested"
                        }
                    elif command == "ping":
                        response = {
                            "success": True,
                            "status": "pong",
                            "model": self.model_id,
                            "device": self.generator.device
                        }
                    elif command == "exit":
                        self.send_response({"success": True, "status": "exiting"})
                        break
                    else:
                        response = {"success": False, "error": f"Unknown command: {command}"}

                    self.send_response(response)

                except json.JSONDecodeError as e:
                    self.send_response({"success": False, "error": f"Invalid JSON: {e}"})
                except Exception as e:
                    log_error(f"Request error: {e}", self.logger)
                    self.send_response({"success": False, "error": str(e)})

        except Exception as e:
            log_error(f"Fatal server error: {e}", self.logger)
            log_error(traceback.format_exc(), self.logger)
            sys.exit(1)


def main():
    parser = argparse.ArgumentParser(description="Stable Diffusion Text-to-Image Wrapper")
    parser.add_argument("--server", action="store_true", help="Run as persistent server")
    parser.add_argument("--warmup", action="store_true", help="Pre-download model")
    parser.add_argument("--model", default=DEFAULT_MODEL, help="Model ID from HuggingFace")
    parser.add_argument("--prompt", help="Text prompt for generation")
    parser.add_argument("--negative-prompt", default="", help="Negative prompt")
    parser.add_argument("--output", help="Output path")
    parser.add_argument("--width", type=int, default=512, help="Image width")
    parser.add_argument("--height", type=int, default=512, help="Image height")
    parser.add_argument("--steps", type=int, default=20, help="Diffusion steps")
    parser.add_argument("--cfg", type=float, default=7.5, help="Guidance scale")
    parser.add_argument("--seed", type=int, help="Random seed")

    args = parser.parse_args()

    if args.server:
        server = T2IServer(args.model)
        server.run()
        return

    if args.warmup:
        generator = T2IGenerator(args.model)
        generator.load()
        log_info("Warmup complete")
        return

    if args.prompt:
        output_path = args.output or "output_image.png"

        generator = T2IGenerator(args.model)

        def progress_print(status, value, detail=None):
            print(f"PROGRESS:{int(value*100)}% - {status}" + (f" ({detail})" if detail else ""), flush=True)

        generator.generate(
            prompt=args.prompt,
            output_path=output_path,
            negative_prompt=args.negative_prompt,
            width=args.width,
            height=args.height,
            num_steps=args.steps,
            guidance_scale=args.cfg,
            seed=args.seed,
            progress_callback=progress_print,
        )
        print(f"SUCCESS:{output_path}", flush=True)
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
