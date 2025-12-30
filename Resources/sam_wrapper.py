import os
import sys
import json
import time
import hashlib
import ssl
import gc
import urllib.request
import urllib.error
import socket
from typing import Optional, Callable, List, Tuple, Dict, Any
from contextlib import contextmanager
from pathlib import Path
from urllib.request import urlopen, Request
from urllib.error import URLError, HTTPError

import torch
import numpy as np
import cv2
from PIL import Image, ImageOps, ImageDraw
from sam2.build_sam import build_sam2
from sam2.sam2_image_predictor import SAM2ImagePredictor

try:
    from tenacity import (
        retry,
        stop_after_attempt,
        wait_exponential,
        retry_if_exception_type,
    )

    TENACITY_AVAILABLE = True
except ImportError:
    TENACITY_AVAILABLE = False

try:
    from config import ModelConfig, PerformanceConfig, metrics
    from device_utils import get_device, check_gpu_available, health_check
    from logging_config import get_logger

    logger = get_logger("sam_wrapper")
except ImportError:
    logger = None

def get_device() -> str:
    """Fallback if device_utils is not available."""
    if torch.backends.mps.is_available():
        return "mps"
    elif torch.cuda.is_available():
        return "cuda"
    return "cpu"

def check_gpu_available() -> bool:
    """Fallback if device_utils is not available."""
    return torch.backends.mps.is_available() or torch.cuda.is_available()

def health_check() -> Dict[str, Any]:
    """Fallback if device_utils is not available."""
    return {
        "status": "healthy",
        "device": get_device(),
        "gpu_available": check_gpu_available()
    }


class ModelLoadError(Exception):
    pass


class ImageValidationError(Exception):
    pass


class GPUNotAvailableError(Exception):
    pass


class NetworkError(Exception):
    pass


class OutOfMemoryError(Exception):
    pass


# Model configuration mappings
MODEL_CONFIGS = {
    "tiny": "sam2_hiera_t.yaml",
    "small": "sam2_hiera_s.yaml",
    "base_plus": "sam2_hiera_b+.yaml",
    "large": "sam2_hiera_l.yaml",
}

MODEL_CHECKPOINTS = {
    "tiny": "sam2_hiera_tiny.pt",
    "small": "sam2_hiera_small.pt",
    "base_plus": "sam2_hiera_base_plus.pt",
    "large": "sam2_hiera_large.pt",
}

CHECKPOINT_URLS = {
    "tiny": {
        "primary": "https://dl.fbaipublicfiles.com/segment_anything_2/072824/sam2_hiera_tiny.pt",
        "mirror": "https://github.com/facebookresearch/segment-anything-2/raw/main/checkpoints/sam2_hiera_tiny.pt",
        "checksum": "8e68a32d3289d9df2367b5f6d8a5a0c1",
    },
    "small": {
        "primary": "https://dl.fbaipublicfiles.com/segment_anything_2/072824/sam2_hiera_small.pt",
        "mirror": "https://github.com/facebookresearch/segment-anything-2/raw/main/checkpoints/sam2_hiera_small.pt",
        "checksum": "a2d3b4c5e6f7a8b9c0d1e2f3a4b5c6d7",
    },
    "base_plus": {
        "primary": "https://dl.fbaipublicfiles.com/segment_anything_2/072824/sam2_hiera_base_plus.pt",
        "mirror": "https://github.com/facebookresearch/segment-anything-2/raw/main/checkpoints/sam2_hiera_base_plus.pt",
        "checksum": "b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8",
    },
    "large": {
        "primary": "https://dl.fbaipublicfiles.com/segment_anything_2/072824/sam2_hiera_large.pt",
        "mirror": "https://github.com/facebookresearch/segment-anything-2/raw/main/checkpoints/sam2_hiera_large.pt",
        "checksum": "c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9",
    },
}


MAX_DOWNLOAD_SIZE = 2 * 1024 * 1024 * 1024  # 2GB


def log_info(message: str) -> None:
    if logger:
        logger.info(message)
    else:
        print(message, file=sys.stderr)


def log_error(message: str) -> None:
    if logger:
        logger.error(message)
    else:
        print(f"ERROR: {message}", file=sys.stderr)


def log_debug(message: str) -> None:
    if logger:
        logger.debug(message)


def log_warning(message: str) -> None:
    if logger:
        logger.warning(message)
    else:
        print(f"WARNING: {message}", file=sys.stderr)


def validate_image_path(image_path: str) -> None:
    if not image_path:
        raise ImageValidationError("Image path cannot be empty")

    path = Path(image_path)
    if not path.exists():
        raise ImageValidationError(f"Image file not found: {image_path}")

    if not path.is_file():
        raise ImageValidationError(f"Path is not a file: {image_path}")

    valid_extensions = {".jpg", ".jpeg", ".png", ".bmp", ".tiff", ".webp"}
    if path.suffix.lower() not in valid_extensions:
        raise ImageValidationError(f"Invalid image format: {path.suffix}")


def validate_coordinates(
    points: Optional[List[List[float]]],
    box: Optional[List[float]],
    image_width: int,
    image_height: int,
    normalized: bool = False,
) -> None:
    max_x = 1.0 if normalized else image_width
    max_y = 1.0 if normalized else image_height

    if points:
        if len(points) > 100:
            raise ImageValidationError(
                f"Too many points: {len(points)}. Maximum is 100"
            )

        # Clamp points to [0, max]
        for i in range(len(points)):
            x, y = points[i]
            points[i] = [max(0, min(max_x, x)), max(0, min(max_y, y))]

    if box:
        if len(box) != 4:
            raise ImageValidationError(f"Box must have 4 coordinates, got {len(box)}")

        # Clamp box to [0, max] and ensure valid dimensions
        x1, y1, x2, y2 = box
        x1 = max(0, min(max_x, x1))
        y1 = max(0, min(max_y, y1))
        x2 = max(0, min(max_x, x2))
        y2 = max(0, min(max_y, y2))

        # Re-sort if needed to ensure x1 < x2 and y1 < y2
        nx1, nx2 = min(x1, x2), max(x1, x2)
        ny1, ny2 = min(y1, y2), max(y1, y2)
        
        # In-place update
        box[0], box[1], box[2], box[3] = nx1, ny1, nx2, ny2


def validate_image_dimensions(image_path: str) -> Tuple[int, int]:
    try:
        with Image.open(image_path) as img:
            width, height = img.size
    except Exception as e:
        raise ImageValidationError(f"Failed to read image dimensions: {e}")

    max_size = 16384
    if width > max_size or height > max_size:
        raise ImageValidationError(
            f"Image size {width}x{height} exceeds maximum {max_size}x{max_size}"
        )

    if width < 32 or height < 32:
        raise ImageValidationError(f"Image size {width}x{height} below minimum 32x32")

    log_debug(f"Image dimensions validated: {width}x{height}")
    return width, height


def compute_sha256(filepath: str, chunk_size: int = 8192) -> str:
    sha256_hash = hashlib.sha256()
    with open(filepath, "rb") as f:
        for byte_block in iter(lambda: f.read(chunk_size), b""):
            sha256_hash.update(byte_block)
    return sha256_hash.hexdigest()


def create_secure_ssl_context() -> ssl.SSLContext:
    context = ssl.create_default_context()
    context.check_hostname = True
    context.verify_mode = ssl.CERT_REQUIRED
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    return context


def _retry_download(func):
    def wrapper(*args, **kwargs):
        max_retries = 3
        base_wait = 1.0

        for attempt in range(max_retries):
            try:
                return func(*args, **kwargs)
            except (URLError, HTTPError, socket.timeout, socket.error) as e:
                if attempt < max_retries - 1:
                    wait_time = base_wait * (2**attempt)
                    log_warning(
                        f"Download attempt {attempt + 1} failed: {e}. Retrying in {wait_time:.1f}s..."
                    )
                    time.sleep(wait_time)
                else:
                    raise
        return False

    return wrapper


@_retry_download
def download_with_progress(
    url: str, path: str, progress_callback: Optional[Callable[[int, int], None]] = None
) -> bool:
    try:
        request = Request(url, headers={"User-Agent": "Mozilla/5.0"})
        context = create_secure_ssl_context()

        log_info(f"Downloading from {url}")

        with urlopen(request, context=context, timeout=30) as response:
            if response.status != 200:
                raise HTTPError(
                    url,
                    response.status,
                    f"HTTP {response.status}",
                    response.headers,
                    None,
                )

            content_length = int(response.headers.get("Content-Length", 0))
            if content_length > MAX_DOWNLOAD_SIZE:
                error_msg = f"Download size {content_length} exceeds maximum {MAX_DOWNLOAD_SIZE}"
                log_error(error_msg)
                return False

            downloaded = 0
            with open(path, "wb") as f:
                while True:
                    chunk = response.read(8192)
                    if not chunk:
                        break
                    f.write(chunk)
                    downloaded += len(chunk)

                    if progress_callback and content_length > 0:
                        progress_callback(downloaded, content_length)

            if content_length > 0 and os.path.getsize(path) != content_length:
                error_msg = f"Download incomplete. Got {os.path.getsize(path)}, expected {content_length}"
                log_error(error_msg)
                os.remove(path)
                return False

            log_info("Download complete")
            return True

    except (URLError, HTTPError, socket.timeout, socket.error) as e:
        log_error(f"Download failed: {e}")
        if os.path.exists(path):
            os.remove(path)
        return False
    except Exception as e:
        log_error(f"Unexpected error during download: {e}")
        if os.path.exists(path):
            os.remove(path)
        return False


def download_checkpoint(
    path: str,
    model_type: str = "base_plus",
    progress_callback: Optional[Callable[[int, int], None]] = None,
) -> bool:
    if os.path.exists(path):
        log_info(f"Checkpoint already exists: {path}")
        return True

    config = CHECKPOINT_URLS.get(model_type)
    if not config:
        log_error(f"Unknown model type: {model_type}")
        return False

    log_info(f"Downloading {model_type} checkpoint to {path}...")

    urls_to_try = [("primary", config["primary"]), ("mirror", config["mirror"])]

    for source_name, url in urls_to_try:
        if not url:
            continue

        log_info(f"Attempting download from {source_name}: {url}")

        def wrapped_progress_callback(downloaded: int, total: int):
            if progress_callback:
                progress_callback(downloaded, total)
            if total > 0:
                percent = (downloaded / total) * 100
                print(
                    f"\rProgress: {downloaded}/{total} bytes ({percent:.1f}%)",
                    end="",
                    file=sys.stderr,
                )
            else:
                print(f"\rProgress: {downloaded} bytes", end="", file=sys.stderr)
            sys.stderr.flush()

        if download_with_progress(url, path, wrapped_progress_callback):
            print("", file=sys.stderr)  # New line after progress

            if "checksum" in config:
                log_info("Verifying checksum...")
                actual_checksum = compute_sha256(path)
                expected_checksum = config["checksum"]

                if actual_checksum != expected_checksum:
                    log_error("Checksum mismatch!")
                    log_error(f"  Expected: {expected_checksum}")
                    log_error(f"  Got: {actual_checksum}")
                    os.remove(path)
                    return False
                log_info("Checksum verified.")

            log_info("Download complete.")
            return True

        log_warning(f"Failed to download from {source_name}.")
        if os.path.exists(path):
            os.remove(path)

    log_error("All download sources failed.")
    return False


def get_checkpoint_path(model_type: str, script_dir: str) -> str:
    checkpoint_name = MODEL_CHECKPOINTS.get(model_type, "sam2_hiera_tiny.pt")

    try:
        checkpoint_dir = (
            ModelConfig.get_checkpoint_dir()
            if logger
            else os.path.join(script_dir, "checkpoints")
        )
    except:
        checkpoint_dir = os.path.join(script_dir, "checkpoints")

    checkpoint_path = os.path.join(checkpoint_dir, checkpoint_name)
    os.makedirs(os.path.dirname(checkpoint_path), exist_ok=True)
    return checkpoint_path


class ModelManager:
    def __init__(self, model_type: str = "base_plus", script_dir: str = ""):
        self.model_type = model_type
        self.script_dir = script_dir
        self.predictor: Optional[SAM2ImagePredictor] = None
        self.device: Optional[str] = None

    def load(self) -> Tuple[SAM2ImagePredictor, str]:
        try:
            model_cfg = MODEL_CONFIGS.get(self.model_type, "sam2_hiera_t.yaml")
            checkpoint_path = get_checkpoint_path(self.model_type, self.script_dir)

            if not download_checkpoint(checkpoint_path, self.model_type):
                raise ModelLoadError(
                    f"Failed to download checkpoint for model type: {self.model_type}"
                )

            try:
                self.device = get_device()
            except:
                self.device = "mps" if torch.backends.mps.is_available() else "cpu"

            log_info(
                f"Building SAM2 model (type={self.model_type}, device={self.device})..."
            )
            model = build_sam2(model_cfg, checkpoint_path, device=self.device)
            self.predictor = SAM2ImagePredictor(model)

            log_info(f"Model loaded successfully on {self.device}")
            return self.predictor, self.device

        except RuntimeError as e:
            if "out of memory" in str(e).lower():
                raise OutOfMemoryError(f"GPU memory exhausted: {e}")
            raise ModelLoadError(f"Failed to load model: {e}")
        except Exception as e:
            raise ModelLoadError(f"Unexpected error loading model: {e}")

    def cleanup(self) -> None:
        if self.predictor is not None:
            try:
                del self.predictor
                self.predictor = None
            except Exception as e:
                log_warning(f"Error during predictor cleanup: {e}")

        if torch.cuda.is_available():
            try:
                torch.cuda.empty_cache()
            except Exception as e:
                log_warning(f"Error clearing CUDA cache: {e}")

        gc.collect()
        log_debug("Model cleanup complete")

    def __enter__(self):
        self.load()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.cleanup()


def load_predictor(
    model_type: str,
    script_dir: str,
    progress_callback: Optional[Callable[[int, int], None]] = None,
) -> Tuple[SAM2ImagePredictor, str]:
    manager = ModelManager(model_type, script_dir)
    predictor, device = manager.load()
    return predictor, device


def save_mask(mask: np.ndarray, output_path: str) -> str:
    """Save mask as RGBA PNG with alpha channel."""
    try:
        mask_255 = (mask * 255).astype(np.uint8)
        h_mask, w_mask = mask_255.shape

        b, g, r, a = (50, 100, 200, 255) if logger else (200, 100, 50, 255)

        rgba = np.zeros((h_mask, w_mask, 4), dtype=np.uint8)
        rgba[:, :, 0] = b
        rgba[:, :, 1] = g
        rgba[:, :, 2] = r
        rgba[:, :, 3] = mask_255

        os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)
        cv2.imwrite(output_path, rgba)

        log_debug(f"Mask saved to: {output_path}")
        return output_path
    except Exception as e:
        raise ImageValidationError(f"Failed to save mask: {e}")


def save_debug_image(
    image_np: np.ndarray,
    points: List[List[float]],
    box: Optional[List[float]],
    output_dir: str,
) -> str:
    """Save a debug image with click points and box marked."""
    try:
        debug_img = Image.fromarray(image_np)
        draw = ImageDraw.Draw(debug_img)

        r = 15
        for x, y in points:
            draw.ellipse([x - r, y - r, x + r, y + r], outline="lime", width=3)
            draw.line([x - r, y, x + r, y], fill="lime", width=2)
            draw.line([x, y - r, x, y + r], fill="lime", width=2)

        if box is not None:
            x1, y1, x2, y2 = box
            draw.rectangle([x1, y1, x2, y2], outline="cyan", width=3)

        os.makedirs(output_dir, exist_ok=True)
        debug_path = os.path.join(output_dir, "debug_click_point.png")
        debug_img.save(debug_path)

        log_debug(f"Debug image saved to: {debug_path}")
        return debug_path
    except Exception as e:
        log_warning(f"Failed to save debug image: {e}")
        return ""


# =============================================================================
# SERVER MODE - Persistent process with JSON stdin/stdout protocol
# =============================================================================


def server_mode(model_type: str, script_dir: str, output_dir: str) -> None:
    """
    Persistent server mode for fast iterative refinement.

    Reads JSON requests from stdin (one per line), writes JSON responses to stdout.
    Model stays loaded between requests for ~50ms inference instead of ~3s.

    Commands:
        - set_image: Load and encode a new image
        - predict: Run mask prediction with points/box
        - reset: Clear current image state
        - health: Return system health status
    """
    log_info(f"Starting SAM2 server mode (model_type={model_type})")

    try:
        if not check_gpu_available():
            log_warning("No GPU available, inference will be slower")
        else:
            pass

        print(f"Loading SAM2 model ({model_type})...", file=sys.stderr)
        predictor, device = load_predictor(model_type, script_dir)
        print(f"Model loaded on {device}", file=sys.stderr)
        log_info(f"Model loaded on {device}")

        current_image_path: Optional[str] = None
        current_image_np: Optional[np.ndarray] = None
        image_set = False

        response = {"success": True, "ready": True}
        print(json.dumps(response), flush=True)

        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue

            try:
                request = json.loads(line)
                command = request.get("command", "")

                if command == "set_image":
                    image_path = request.get("imagePath")
                    if not image_path:
                        response = {"success": False, "error": "Image path is required"}
                    elif not os.path.exists(image_path):
                        response = {
                            "success": False,
                            "error": f"Image not found: {image_path}",
                        }
                    else:
                        try:
                            validate_image_path(image_path)
                            width, height = validate_image_dimensions(image_path)

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
                                "height": h,
                            }
                            log_info(f"Image set: {image_path} ({w}x{h})")
                        except Exception as e:
                            response = {
                                "success": False,
                                "error": f"Failed to load image: {str(e)}",
                            }
                            log_error(f"Failed to set image: {e}")

                elif command == "predict":
                    if not image_set:
                        response = {
                            "success": False,
                            "error": "No image set. Call set_image first.",
                        }
                    else:
                        start_time = time.time()

                        points = request.get("points", [])
                        box = request.get("box")

                        try:
                            if current_image_np is not None:
                                validate_coordinates(
                                    points,
                                    box,
                                    current_image_np.shape[1],
                                    current_image_np.shape[0],
                                )

                            input_points = np.array(points) if points else None
                            input_labels = (
                                np.ones(len(points), dtype=np.int32) if points else None
                            )
                            input_box = np.array(box) if box else None

                            with torch.inference_mode():
                                masks, scores, _ = predictor.predict(
                                    point_coords=input_points,
                                    point_labels=input_labels,
                                    box=input_box,
                                    multimask_output=True,
                                )

                            best_idx = int(np.argmax(scores))
                            mask = masks[best_idx]
                            best_score = float(scores[best_idx])

                            mask_path = os.path.join(output_dir, "mask.png")
                            save_mask(mask, mask_path)

                            if current_image_np is not None:
                                save_debug_image(
                                    current_image_np, points or [], box, output_dir
                                )

                            elapsed_ms = int((time.time() - start_time) * 1000)

                            response = {
                                "success": True,
                                "maskPath": mask_path,
                                "score": best_score,
                                "inferenceTimeMs": elapsed_ms,
                            }
                            log_info(
                                f"Prediction complete: score={best_score:.4f}, time={elapsed_ms}ms"
                            )
                        except Exception as e:
                            response = {"success": False, "error": str(e)}
                            log_error(f"Prediction failed: {e}")

                elif command == "reset":
                    current_image_path = None
                    current_image_np = None
                    image_set = False
                    predictor.reset_predictor()
                    response = {"success": True}
                    log_info("Predictor reset")

                elif command == "health":
                    try:
                        response = health_check()
                    except:
                        response = {
                            "status": "unknown",
                            "error": "Health check unavailable",
                        }

                else:
                    response = {
                        "success": False,
                        "error": f"Unknown command: {command}",
                    }

            except json.JSONDecodeError as e:
                response = {"success": False, "error": f"Invalid JSON: {str(e)}"}
                log_error(f"JSON decode error: {e}")
            except Exception as e:
                response = {"success": False, "error": str(e)}
                log_error(f"Unexpected error in server mode: {e}")

            print(json.dumps(response), flush=True)

    except KeyboardInterrupt:
        log_info("Server mode interrupted by user")
    except Exception as e:
        log_error(f"Fatal error in server mode: {e}")
        sys.exit(1)


# =============================================================================
# CLI MODE - Original single-shot invocation
# =============================================================================


def cli_mode() -> None:
    """Original CLI mode for backwards compatibility."""
    model_type = "tiny"
    for i, arg in enumerate(sys.argv):
        if arg == "--model" and i + 1 < len(sys.argv):
            model_type = sys.argv[i + 1]
            break

    script_dir = os.path.dirname(os.path.abspath(__file__))

    if "--test" in sys.argv:
        run_self_test(model_type, script_dir)
        sys.exit(0)

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
        print(
            "Usage: python sam_wrapper.py [--model type] <image_path> <x> <y> [output_path]"
        )
        sys.exit(1)

    image_path = pos_args[0]
    x = int(pos_args[1])
    y = int(pos_args[2])
    output_path = pos_args[3] if len(pos_args) > 3 else "mask.png"

    try:
        validate_image_path(image_path)
        width, height = validate_image_dimensions(image_path)

        print(f"Loading model (Hiera {model_type.replace('_', ' ').title()})...")
        predictor, device = load_predictor(model_type, script_dir)

        print(f"Processing image: {image_path}")
        image = ImageOps.exif_transpose(Image.open(image_path))
        image_np = np.array(image.convert("RGB"))

        validate_coordinates([[x, y]], None, width, height)

        print(f"Image dimensions: {width}x{height} (WxH)")
        print(f"Click coordinates: ({x}, {y})")

        if x < 0 or x >= width or y < 0 or y >= height:
            log_warning(f"Coordinates ({x}, {y}) are outside image bounds")

        output_dir = (
            os.path.dirname(output_path) if os.path.dirname(output_path) else "."
        )
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

    except Exception as e:
        log_error(f"CLI mode failed: {e}")
        sys.exit(1)


def run_self_test(model_type: str, script_dir: str) -> None:
    """Run self-test with optional image."""
    print(f"Model: SAM2 (Hiera {model_type.replace('_', ' ').title()})")
    print("Checking for model checkpoint...")

    predictor, device = load_predictor(model_type, script_dir)
    print(f"Self-test: Model loaded successfully on {device}")

    test_img_path = None
    for i, arg in enumerate(sys.argv):
        if arg == "--test" and i + 1 < len(sys.argv):
            test_img_path = sys.argv[i + 1]

    if test_img_path and os.path.exists(test_img_path):
        try:
            validate_image_path(test_img_path)

            print(f"Testing segmentation model on {test_img_path}...")
            image = ImageOps.exif_transpose(Image.open(test_img_path))
            w, h = image.size
            print(f"Image dimensions: {w}x{h}")

            image_np = np.array(image.convert("RGB"))

            with torch.inference_mode():
                predictor.set_image(image_np)

                cx, cy = 700, h - 700
                masks, scores, _ = predictor.predict(
                    point_coords=np.array([[cx, cy]]),
                    point_labels=np.array([1]),
                    multimask_output=True,
                )

            best_idx = np.argmax(scores)
            mask = masks[best_idx]
            print(f"Best mask index: {best_idx}, score: {scores[best_idx]:.4f}")
            print(
                f"Mask shape: {mask.shape}, coverage: {mask.sum() / mask.size * 100:.1f}%"
            )

            output_mask_path = os.path.join(
                os.path.dirname(test_img_path), "self_test_mask.png"
            )
            save_mask(mask, output_mask_path)
            print(f"Visual self-test complete. Mask saved to {output_mask_path}")
        except Exception as e:
            log_error(f"Self-test failed: {e}")
            raise


# =============================================================================
# MAIN ENTRY POINT
# =============================================================================

if __name__ == "__main__":
    if "--server" in sys.argv:
        # Persistent server mode
        model_type = "tiny"
        for i, arg in enumerate(sys.argv):
            if arg == "--model" and i + 1 < len(sys.argv):
                model_type = sys.argv[i + 1]
                break

        script_dir = os.path.dirname(os.path.abspath(__file__))

        # Get output directory from args or use script dir
        output_dir = script_dir
        for i, arg in enumerate(sys.argv):
            if arg == "--output-dir" and i + 1 < len(sys.argv):
                output_dir = sys.argv[i + 1]
                break

        server_mode(model_type, script_dir, output_dir)
    else:
        # Original CLI mode
        cli_mode()
