#!/usr/bin/env python3
"""
Hunyuan3D-2.1 Model Generation Wrapper for Modelr
===================================================
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

_cancel_file_path = None  # Will be set before generation


def _touch_cancel_file() -> None:
    """Create the cancel file for the *current* Python process.

    The Swift app may be launched via an intermediate process (e.g. `uv`), so the
    most reliable approach is for the Python server itself to touch the cancel file
    that the patched tqdm and generation loop check.
    """
    global _cancel_file_path
    try:
        if _cancel_file_path is None:
            _cancel_file_path = Path(f"/tmp/modelr_cancel_{os.getpid()}")
        _cancel_file_path.parent.mkdir(parents=True, exist_ok=True)
        _cancel_file_path.touch(exist_ok=True)
        print(f"[CANCEL] Touched cancel file: {_cancel_file_path}", file=sys.stderr, flush=True)
    except Exception as e:
        print(f"[CANCEL] Failed to touch cancel file: {e}", file=sys.stderr, flush=True)

def _patch_tqdm():
    """Patch tqdm to check for cancel file. Must be called before hy3dgen is imported."""
    import tqdm as tqdm_module
    import tqdm.auto
    import tqdm.std

    _OriginalTqdm = tqdm_module.tqdm

    class CancellableTqdm(_OriginalTqdm):
        """Patched tqdm that checks for cancel file on each update."""

        def _check_cancel(self):
            global _cancel_file_path
            if _cancel_file_path and _cancel_file_path.exists():
                print(f"[TQDM] Cancel file detected, stopping!", file=sys.stderr, flush=True)
                try:
                    _cancel_file_path.unlink()
                except:
                    pass
                from modelr_core.exceptions import GenerationError
                raise GenerationError("Generation cancelled by user")

        def __iter__(self):
            for item in super().__iter__():
                self._check_cancel()
                yield item

        def update(self, n=1):
            self._check_cancel()
            return super().update(n)

    # Patch ALL tqdm entry points
    tqdm_module.tqdm = CancellableTqdm
    tqdm_module.std.tqdm = CancellableTqdm
    tqdm.auto.tqdm = CancellableTqdm

    # Also update the trange shortcuts
    def cancellable_trange(*args, **kwargs):
        return CancellableTqdm(range(*args), **kwargs)

    tqdm_module.trange = cancellable_trange
    tqdm.auto.trange = cancellable_trange

    print("[TQDM] Patched for cancellation support", file=sys.stderr, flush=True)

# Patch tqdm IMMEDIATELY before any other imports that might use it
_patch_tqdm()

import torch
import numpy as np
from PIL import Image
from huggingface_hub import snapshot_download

from modelr_core import (
    get_logger,
    get_device,
    ModelConfig,
    log_info,
    log_error,
    log_debug,
    log_warning,
    load_image,
    extract_foreground,
    get_model_size_formatted,
)
from modelr_core.exceptions import (
    ModelLoadError,
    GenerationError,
)

logger = get_logger("hunyuan_wrapper")
HUNYUAN_CACHE_DIR = ModelConfig.get_hunyuan_cache_dir()


class HunyuanGenerator:
    """Manages Hunyuan3D model generation."""

    # Model variant mapping: variant -> (repo_id, subfolder, use_safetensors)
    VARIANT_MAP = {
        # Mini variants (all in same repo, different subfolders)
        "mini": ("tencent/Hunyuan3D-2mini", "hunyuan3d-dit-v2-mini", True),
        "mini-fast": ("tencent/Hunyuan3D-2mini", "hunyuan3d-dit-v2-mini-fast", True),
        "mini-turbo": ("tencent/Hunyuan3D-2mini", "hunyuan3d-dit-v2-mini-turbo", True),
        # Standard 2.1 model
        "std": ("tencent/Hunyuan3D-2.1", "hunyuan3d-dit-v2-1", True),
    }

    def __init__(self, model_variant: str = "std"):
        self.model_variant = model_variant
        self.pipeline = None
        self.device = get_device()

    def load(self):
        """Load the pipeline."""
        try:
            from hy3dgen.shapegen import Hunyuan3DDiTFlowMatchingPipeline

            log_info("Modelr hunyuan_wrapper: safetensors-only warmup enabled")

            repo_id, subfolder, use_safetensors = self.VARIANT_MAP.get(
                self.model_variant, self.VARIANT_MAP["std"]
            )
            log_info(f"Loading Hunyuan3D pipeline: {repo_id}/{subfolder}")

            configured_hy3dgen_models = os.environ.get("HY3DGEN_MODELS")
            inferred_hy3dgen_models = Path(HUNYUAN_CACHE_DIR).parent / "hy3dgen"
            if configured_hy3dgen_models and Path(configured_hy3dgen_models) != Path(HUNYUAN_CACHE_DIR):
                hy3dgen_models_dir = Path(configured_hy3dgen_models)
            else:
                hy3dgen_models_dir = inferred_hy3dgen_models
                os.environ["HY3DGEN_MODELS"] = str(hy3dgen_models_dir)
            hy3dgen_models_dir.mkdir(parents=True, exist_ok=True)

            snapshot_path = snapshot_download(
                repo_id=repo_id,
                allow_patterns=[
                    f"{subfolder}/*.safetensors",
                    f"{subfolder}/*.json",
                    f"{subfolder}/*.yaml",
                    f"{subfolder}/*.yml",
                    f"{subfolder}/*.txt",
                ],
                ignore_patterns=[
                    f"{subfolder}/*.ckpt",
                    f"{subfolder}/*.ckpt.*",
                ],
                cache_dir=str(HUNYUAN_CACHE_DIR),
            )
            log_info(f"Using local snapshot: {snapshot_path}")

            try:
                snapshot_dir = Path(snapshot_path)
                snapshot_weights_dir = snapshot_dir / subfolder
                hy3d_local_dir = hy3dgen_models_dir / repo_id / subfolder
                hy3d_local_dir.mkdir(parents=True, exist_ok=True)

                def link_into_local(name: str) -> None:
                    src = snapshot_weights_dir / name
                    if not src.exists() and not src.is_symlink():
                        return
                    try:
                        target = src.resolve(strict=False) if src.is_symlink() else src
                    except Exception:
                        target = src
                    dst = hy3d_local_dir / name
                    try:
                        if dst.exists() or dst.is_symlink():
                            dst.unlink()
                    except Exception:
                        pass
                    try:
                        dst.symlink_to(target)
                    except Exception:
                        import shutil
                        shutil.copy2(target, dst)

                link_into_local("config.yaml")
                for st in snapshot_weights_dir.glob("*.safetensors"):
                    link_into_local(st.name)
                for meta in snapshot_weights_dir.glob("*.json"):
                    link_into_local(meta.name)
                for meta in snapshot_weights_dir.glob("*.yml"):
                    link_into_local(meta.name)
                for meta in snapshot_weights_dir.glob("*.yaml"):
                    link_into_local(meta.name)
                for meta in snapshot_weights_dir.glob("*.txt"):
                    link_into_local(meta.name)
            except Exception as e:
                log_debug(f"Failed to stage hy3dgen local model dir: {e}")

            try:
                snapshot_dir = Path(snapshot_path)
                repo_root = snapshot_dir.parent.parent
                blobs_dir = repo_root / "blobs"
                weights_dir = snapshot_dir / subfolder

                if weights_dir.exists():
                    safetensors = list(weights_dir.glob("**/*.safetensors"))
                    ckpts = list(weights_dir.glob("**/*.ckpt")) + list(weights_dir.glob("**/*.ckpt.*"))
                    if safetensors and ckpts:
                        for ckpt in ckpts:
                            target_blob: Optional[Path] = None
                            if ckpt.is_symlink():
                                try:
                                    target_blob = ckpt.resolve(strict=False)
                                except Exception:
                                    target_blob = None

                            try:
                                ckpt.unlink(missing_ok=True)
                            except TypeError:
                                if ckpt.exists() or ckpt.is_symlink():
                                    ckpt.unlink()

                            if target_blob is not None:
                                try:
                                    if blobs_dir in target_blob.parents and target_blob.exists():
                                        target_blob.unlink()
                                except Exception:
                                    pass

                        log_info("Pruned cached .ckpt weights (keeping .safetensors)")
            except Exception as e:
                log_debug(f"Failed to prune ckpt weights: {e}")

            self.pipeline = Hunyuan3DDiTFlowMatchingPipeline.from_pretrained(
                repo_id,
                subfolder=subfolder,
                device=self.device,
                use_safetensors=use_safetensors,
                variant="fp16",
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
        progress_callback: Optional[Callable[[str, float, Optional[str]], None]] = None,
        cancel_check: Optional[Callable[[], bool]] = None
    ) -> str:
        """Generate 3D model.

        Args:
            cancel_check: Optional callable that returns True if generation should be cancelled.
                         Checked at the start of each diffusion step for clean cancellation.
        """
        if self.pipeline is None:
            self.load()

        try:
            log_info(f"Generating 3D shape (steps={num_steps}, resolution={octree_resolution})...")

            # Track if we've sent any progress (to detect if callback isn't supported)
            steps_reported = [0]

            # Create a step callback for diffusion progress
            # hy3dgen uses callback(step_idx, timestep, outputs) signature
            def step_callback(step_idx, timestep, outputs):
                # Check for cancellation FIRST - this is the cleanest way to break the loop
                if cancel_check and cancel_check():
                    print(f"[DIFFUSION] Cancel detected at step {step_idx + 1}, breaking loop", file=sys.stderr, flush=True)
                    raise GenerationError("Generation cancelled by user")

                if progress_callback:
                    current_step = step_idx + 1
                    steps_reported[0] = current_step
                    # Map step to progress (diffusion is ~15-80% of total)
                    step_progress = 0.15 + (current_step / num_steps) * 0.65
                    detail = f"{current_step}/{num_steps}"
                    # Print explicit progress line for Swift to parse (to stderr)
                    print(f"[DIFFUSION_PROGRESS] {current_step}/{num_steps} {int(step_progress*100)}%", file=sys.stderr, flush=True)
                    progress_callback("Diffusion Sampling", step_progress, detail)

                    # When diffusion completes, signal volume decoding is starting
                    # (volume decoding happens inside pipeline() after diffusion loop)
                    if current_step == num_steps:
                        print("[STAGE] volume_decoding", file=sys.stderr, flush=True)
                        progress_callback("Volume Decoding", 0.82, "Extracting mesh...")

            with torch.inference_mode():
                # Try with callback first
                # Note: tqdm writes to stderr by default, so enable_pbar=True is safe
                try:
                    mesh = self.pipeline(
                        image=image,
                        octree_resolution=octree_resolution,
                        num_inference_steps=num_steps,
                        callback=step_callback,
                        callback_steps=1,
                        enable_pbar=True,  # tqdm goes to stderr, won't interfere with JSON on stdout
                    )[0]
                except TypeError as e:
                    # Callback might not be supported - try without
                    log_warning(f"Pipeline callback not supported: {e}, falling back to no-callback mode")
                    print(f"[DIFFUSION_PROGRESS] 0/{num_steps} 15%", file=sys.stderr, flush=True)
                    if progress_callback:
                        progress_callback("Diffusion Sampling", 0.2, "Processing...")
                    mesh = self.pipeline(
                        image=image,
                        octree_resolution=octree_resolution,
                        num_inference_steps=num_steps,
                        enable_pbar=True,
                    )[0]

            # If callback wasn't called, send a completion update
            if steps_reported[0] == 0 and progress_callback:
                log_warning("No step callbacks received - pipeline may not support callbacks")
                print("[STAGE] volume_decoding", file=sys.stderr, flush=True)
                progress_callback("Volume Decoding", 0.85, "Processing complete")

            # Mesh extraction complete, now saving
            if progress_callback:
                progress_callback("Saving", 0.95, "Writing file...")

            mesh.export(output_path)

            return output_path
        except Exception as e:
            raise GenerationError(f"Failed to generate 3D model: {e}")

    def cleanup(self):
        self.pipeline = None
        if torch.cuda.is_available():
            torch.cuda.empty_cache()
        gc.collect()


class HunyuanServer:
    """Persistent server for Hunyuan3D generation."""

    def __init__(self, model_variant: str = "mini"):
        self.model_variant = model_variant
        self.generator = None
        self.logger = get_logger("hunyuan_server")
        self._cancel_requested = False
        self._is_generating = False

    def initialize(self):
        """Load the model and prepare for generation requests."""
        log_info(f"Initializing Hunyuan server with variant: {self.model_variant}", self.logger)
        self.generator = HunyuanGenerator(self.model_variant)
        self.generator.load()
        log_info("Hunyuan model loaded and ready", self.logger)

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
        image_path = request.get("imagePath")
        mask_path = request.get("maskPath")
        output_path = request.get("outputPath")
        steps = request.get("steps", 50)
        resolution = request.get("resolution", 384)

        if not image_path or not os.path.exists(image_path):
            return {"success": False, "error": "Image not found", "messageId": message_id}

        if not output_path:
            return {"success": False, "error": "Output path required", "messageId": message_id}

        # Reset cancel flag
        self._cancel_requested = False
        self._is_generating = True

        try:
            # Load image
            self.send_progress(message_id, "loading", 0.05, "Loading image...")
            image = load_image(image_path, convert_mode="RGBA")

            # Apply mask if provided
            if mask_path and os.path.exists(mask_path):
                self.send_progress(message_id, "loading", 0.1, "Applying mask...")
                mask_img = load_image(mask_path, convert_mode="L")
                image = extract_foreground(image, mask_img)

            # Progress callback for reporting status to Swift
            def progress_callback(status: str, value: float, detail: Optional[str] = None):
                if "Diffusion" in status:
                    stage = "diffusion"
                    step_detail = detail if detail else ""
                elif "Volume" in status or "Decoding" in status:
                    stage = "volume_decoding"
                    step_detail = detail if detail else ""
                elif "Saving" in status:
                    stage = "saving"
                    step_detail = detail if detail else ""
                else:
                    stage = "diffusion"
                    step_detail = detail if detail else ""
                self.send_progress(message_id, stage, value, step_detail)

            self.send_progress(message_id, "diffusion", 0.15, "Starting generation...")

            # Set global cancel file path for the patched tqdm to check
            global _cancel_file_path
            _cancel_file_path = Path(f"/tmp/modelr_cancel_{os.getpid()}")
            # Clean up any stale cancel file from previous runs
            if _cancel_file_path.exists():
                try:
                    _cancel_file_path.unlink()
                except:
                    pass

            # Cancel check function - checked at each diffusion step (backup)
            def should_cancel():
                if self._cancel_requested:
                    return True
                if _cancel_file_path and _cancel_file_path.exists():
                    return True
                return False

            result_path = self.generator.generate(
                image=image,
                output_path=output_path,
                num_steps=steps,
                octree_resolution=resolution,
                progress_callback=progress_callback,
                cancel_check=should_cancel
            )

            self._is_generating = False
            return {
                "success": True,
                "type": "complete",
                "messageId": message_id,
                "outputPath": result_path
            }

        except GenerationError as e:
            self._is_generating = False
            if "cancelled" in str(e).lower():
                log_info("Generation cancelled by user", self.logger)
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
            # Check if this was a cancellation that propagated differently
            if self._cancel_requested or "cancel" in str(e).lower():
                log_info("Generation cancelled (caught as Exception)", self.logger)
                return {
                    "success": False,
                    "type": "cancelled",
                    "messageId": message_id,
                    "error": "Generation cancelled"
                }
            log_error(f"Generation error: {e}", self.logger)
            log_debug(traceback.format_exc(), self.logger)
            return {
                "success": False,
                "type": "error",
                "messageId": message_id,
                "error": str(e)
            }

    def run(self):
        """Main server loop - single stdin reader with queue for cancel support."""
        import queue

        command_queue = queue.Queue()

        def stdin_reader():
            """Single thread that reads stdin using select for responsive cancel detection."""
            stdin_fd = sys.stdin.fileno()
            try:
                while True:
                    # Use select to check if data is available (100ms timeout for responsiveness)
                    ready, _, _ = select.select([stdin_fd], [], [], 0.1)
                    if ready:
                        # Read a line from stdin buffer (bypasses TextIOWrapper buffering)
                        line_bytes = sys.stdin.buffer.readline()
                        if not line_bytes:  # EOF
                            print("[HunyuanServer] stdin EOF, exiting reader", file=sys.stderr, flush=True)
                            break
                        line = line_bytes.decode('utf-8').strip()
                        if line:
                            print(f"[HunyuanServer] stdin got: {line[:80]}...", file=sys.stderr, flush=True)
                            command_queue.put(line)
            except Exception as e:
                print(f"[HunyuanServer] stdin_reader error: {e}", file=sys.stderr, flush=True)

        try:
            self.initialize()

            # Signal ready to Swift
            self.send_response({
                "success": True,
                "ready": True,
                "device": self.generator.device,
                "server": "hunyuan",
                "variant": self.model_variant
            })

            # Start the stdin reader thread
            reader_thread = threading.Thread(target=stdin_reader, daemon=True)
            reader_thread.start()

            while True:
                try:
                    # Get next command from queue (blocking)
                    line = command_queue.get()
                    request = json.loads(line)
                    command = request.get("command", "")

                    if command == "generate":
                        # Reset cancel flag
                        self._cancel_requested = False
                        self._is_generating = True

                        # Run generation in a thread so we can check for cancel requests
                        gen_result = [None]
                        gen_done = threading.Event()

                        def do_generate():
                            gen_result[0] = self.handle_generate(request)
                            gen_done.set()

                        gen_thread = threading.Thread(target=do_generate)
                        gen_thread.start()

                        # Poll for cancel commands while generating
                        # The cancel flag is checked directly in the diffusion step callback
                        while not gen_done.wait(timeout=0.05):
                            try:
                                cancel_line = command_queue.get_nowait()
                                print(f"[HunyuanServer] Got during gen: {cancel_line}", file=sys.stderr, flush=True)
                                cancel_req = json.loads(cancel_line)
                                if cancel_req.get("command") == "cancel":
                                    print("[HunyuanServer] CANCEL received - will stop at next step", file=sys.stderr, flush=True)
                                    self._cancel_requested = True
                                    _touch_cancel_file()
                            except queue.Empty:
                                pass
                            except json.JSONDecodeError:
                                pass

                        gen_thread.join()
                        self._is_generating = False
                        response = gen_result[0]

                    elif command == "cancel":
                        self._cancel_requested = True
                        # Ensure cancellation works even if the pipeline doesn't support callbacks.
                        _touch_cancel_file()
                        response = {
                            "success": True,
                            "type": "cancelled",
                            "message": "No active generation"
                        }
                    elif command == "ping":
                        response = {
                            "success": True,
                            "status": "pong",
                            "device": self.generator.device,
                            "variant": self.model_variant
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
    parser = argparse.ArgumentParser(description="Hunyuan3D-2.1 Shape Generation Wrapper")
    parser.add_argument("--server", action="store_true", help="Run as persistent server")
    parser.add_argument("--warmup", action="store_true", help="Pre-download model")
    parser.add_argument("--get-size", action="store_true", help="Query model download size")
    parser.add_argument(
        "--model",
        default="std",
        choices=["mini", "mini-fast", "mini-turbo", "std"],
        help="Model variant (mini, mini-fast, mini-turbo, or std)"
    )
    parser.add_argument("--image", help="Input image path")
    parser.add_argument("--mask", help="Mask image path")
    parser.add_argument("--output", help="Output path")
    parser.add_argument("--steps", type=int, default=50, help="Diffusion steps")
    parser.add_argument("--resolution", type=int, default=384, help="Octree resolution")

    args = parser.parse_args()

    if args.get_size:
        model_key_map = {
            "mini": "hunyuan-mini",
            "mini-fast": "hunyuan-mini",
            "mini-turbo": "hunyuan-mini",
            "std": "hunyuan-std",
        }
        model_key = model_key_map.get(args.model, "hunyuan-std")
        size_str = get_model_size_formatted(model_key)
        print(f"SIZE:{size_str}", flush=True)
        return

    if args.server:
        # Run as persistent server
        server = HunyuanServer(args.model)
        server.run()
        return

    if args.warmup:
        generator = HunyuanGenerator(args.model)
        generator.load()
        log_info("Warmup complete")
        return

    if args.image:
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
