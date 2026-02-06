import os
import sys
import json
import time
import gc
from typing import Optional, Callable, List, Tuple, Dict, Any
from pathlib import Path

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
    )
    from modelrv3_core.logging import log_info, log_error, log_debug, log_warning
    from modelrv3_core.exceptions import (
        ModelLoadError,
        ImageValidationError,
        OutOfMemoryError,
    )
    from modelrv3_core.download import (
        download_with_progress,
        compute_sha256,
        MAX_DOWNLOAD_SIZE,
    )

    logger = get_logger("sam_wrapper")
except ImportError:
    logger = None
    log_info = lambda x: print(x, file=sys.stderr)
    log_error = lambda x: print(f"ERROR: {x}", file=sys.stderr)
    log_warning = lambda x: print(f"WARNING: {x}", file=sys.stderr)
    log_debug = lambda x: None
    get_device = lambda: (
        "mps"
        if torch.backends.mps.is_available()
        else "cuda"
        if torch.cuda.is_available()
        else "cpu"
    )
    check_gpu_available = (
        lambda: torch.backends.mps.is_available() or torch.cuda.is_available()
    )
    ModelLoadError = Exception
    ImageValidationError = Exception
    OutOfMemoryError = Exception
    download_with_progress = None
    compute_sha256 = None
    MAX_DOWNLOAD_SIZE = 2 * 1024 * 1024 * 1024

    # Fallback validation functions
    def validate_image_path(path: str) -> None:
        """Validate that image path exists and is a supported format."""
        if not os.path.exists(path):
            raise FileNotFoundError(f"Image not found: {path}")
        ext = os.path.splitext(path)[1].lower()
        if ext not in ['.jpg', '.jpeg', '.png', '.bmp', '.tiff', '.webp']:
            raise ValueError(f"Unsupported image format: {ext}")

    def validate_image_dimensions(path: str) -> Tuple[int, int]:
        """Validate image dimensions and return (width, height)."""
        from PIL import Image as PILImage
        with PILImage.open(path) as img:
            return img.size  # Returns (width, height)

    def validate_coordinates(
        points: List[List[float]],
        box: Optional[List[float]],
        width: int,
        height: int
    ) -> Tuple[Optional[List[List[float]]], Optional[List[float]]]:
        """Validate that coordinates are within image bounds."""
        if points:
            for point in points:
                if len(point) >= 2:
                    x, y = point[0], point[1]
                    if x < 0 or x >= width or y < 0 or y >= height:
                        log_warning(f"Point ({x}, {y}) outside image bounds ({width}x{height})")
        if box is not None and len(box) >= 4:
            x1, y1, x2, y2 = box[:4]
            if x1 < 0 or y1 < 0 or x2 > width or y2 > height:
                log_warning(f"Box [{x1},{y1},{x2},{y2}] outside image bounds ({width}x{height})")
        return points, box

    def health_check() -> Dict[str, Any]:
        """Basic health check."""
        return {"status": "ok", "gpu_available": check_gpu_available()}

    class ModelConfig:
        @staticmethod
        def get_checkpoint_dir() -> str:
            return os.path.join(os.path.dirname(os.path.abspath(__file__)), "checkpoints")

    class PerformanceConfig:
        pass

    metrics = None


MODEL_CONFIGS = {
    "tiny": "configs/sam2.1/sam2.1_hiera_t.yaml",
    "small": "configs/sam2.1/sam2.1_hiera_s.yaml",
    "base_plus": "configs/sam2.1/sam2.1_hiera_b+.yaml",
    "large": "configs/sam2.1/sam2.1_hiera_l.yaml",
}

MODEL_CHECKPOINTS = {
    "tiny": "sam2.1_hiera_tiny.pt",
    "small": "sam2.1_hiera_small.pt",
    "base_plus": "sam2.1_hiera_base_plus.pt",
    "large": "sam2.1_hiera_large.pt",
}

CHECKPOINT_URLS = {
    "tiny": {
        "primary": "https://huggingface.co/facebook/sam2.1-hiera-tiny/resolve/main/sam2.1_hiera_tiny.pt",
        "mirror": "https://github.com/facebookresearch/segment-anything-2/raw/main/checkpoints/sam2.1_hiera_tiny.pt",
        "checksum": "7402e0d864fa82708a20fbd15bc84245c2f26dff0eb43a4b5b93452deb34be69",
    },
    "small": {
        "primary": "https://huggingface.co/facebook/sam2.1-hiera-small/resolve/main/sam2.1_hiera_small.pt",
        "mirror": "https://github.com/facebookresearch/segment-anything-2/raw/main/checkpoints/sam2.1_hiera_small.pt",
        "checksum": "95949964d4e548409021d47b22712d5f1abf2564cc0c3c765ba599a24ac7dce3",
    },
    "base_plus": {
        "primary": "https://huggingface.co/facebook/sam2.1-hiera-base-plus/resolve/main/sam2.1_hiera_base_plus.pt",
        "mirror": "https://github.com/facebookresearch/segment-anything-2/raw/main/checkpoints/sam2.1_hiera_base_plus.pt",
        "checksum": "a2345aede8715ab1d5d31b4a509fb160c5a4af1970f199d9054ccfb746c004c5",
    },
    "large": {
        "primary": "https://huggingface.co/facebook/sam2.1-hiera-large/resolve/main/sam2.1_hiera_large.pt",
        "mirror": "https://github.com/facebookresearch/segment-anything-2/raw/main/checkpoints/sam2.1_hiera_large.pt",
        "checksum": "8b36b71d5cafc83a0975d14d0afae81c3915804e12cc896b0665eaabcc445d56",
    },
}


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

        if download_with_progress and download_with_progress(
            url, path, wrapped_progress_callback
        ):
            print("", file=sys.stderr)

            if "checksum" in config and compute_sha256:
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
    checkpoint_name = MODEL_CHECKPOINTS.get(model_type, "sam2.1_hiera_tiny.pt")

    try:
        checkpoint_dir = (
            ModelConfig.get_checkpoint_dir()
            if logger
            else os.path.join(script_dir, "checkpoints")
        )
    except Exception:
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
            model_cfg = MODEL_CONFIGS.get(
                self.model_type, "configs/sam2.1/sam2.1_hiera_t.yaml"
            )
            checkpoint_path = get_checkpoint_path(self.model_type, self.script_dir)

            if not download_checkpoint(checkpoint_path, self.model_type):
                raise ModelLoadError(
                    f"Failed to download checkpoint for model type: {self.model_type}"
                )

            try:
                self.device = get_device()
            except Exception:
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


def server_mode(model_type: str, script_dir: str, output_dir: str) -> None:
    """Persistent server mode for fast iterative refinement."""
    log_info(f"Starting SAM2 server mode (model_type={model_type})")

    try:
        if not check_gpu_available():
            log_warning("No GPU available, inference will be slower")

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
                        labels = request.get("labels", [])
                        box = request.get("box")

                        try:
                            if current_image_np is not None:
                                points, box = validate_coordinates(
                                    points,
                                    box,
                                    current_image_np.shape[1],
                                    current_image_np.shape[0],
                                )

                            input_points = np.array(points) if points else None
                            if labels and len(labels) == len(points):
                                input_labels = np.array(labels, dtype=np.int32)
                            else:
                                input_labels = (
                                    np.ones(len(points), dtype=np.int32)
                                    if points
                                    else None
                                )
                            input_box = np.array(box) if box else None

                            with torch.inference_mode():
                                masks, scores, low_res_logits = predictor.predict(
                                    point_coords=input_points,
                                    point_labels=input_labels,
                                    box=input_box,
                                    multimask_output=True,
                                )

                            mask_paths = []
                            for i, mask in enumerate(masks):
                                mask_path = os.path.join(output_dir, f"mask_{i}.png")
                                save_mask(mask, mask_path)
                                mask_paths.append(mask_path)

                            if current_image_np is not None:
                                save_debug_image(
                                    current_image_np, points or [], box, output_dir
                                )

                            # Generate confidence heatmap from best mask's logits
                            confidence_map_path = None
                            try:
                                import torch.nn.functional as F

                                best_idx = np.argmax(scores)
                                # low_res_logits shape: (num_masks, 1, H, W) where H,W are low-res
                                logits = low_res_logits[best_idx]  # Shape: (1, H, W)

                                # Convert to tensor and upsample to image size
                                logits_tensor = torch.from_numpy(logits).float()
                                if len(logits_tensor.shape) == 2:
                                    logits_tensor = logits_tensor.unsqueeze(0).unsqueeze(0)
                                elif len(logits_tensor.shape) == 3:
                                    logits_tensor = logits_tensor.unsqueeze(0)

                                h, w = current_image_np.shape[:2]
                                upsampled = F.interpolate(
                                    logits_tensor,
                                    size=(h, w),
                                    mode='bilinear',
                                    align_corners=False
                                ).squeeze()

                                # Apply sigmoid to get probability, then convert to colormap
                                confidence = torch.sigmoid(upsampled).numpy()

                                # Create a heatmap: blue (low confidence) -> red (high confidence)
                                # Using a simple colormap
                                confidence_uint8 = (confidence * 255).astype(np.uint8)

                                # Apply colormap (COLORMAP_JET: blue->green->yellow->red)
                                heatmap = cv2.applyColorMap(confidence_uint8, cv2.COLORMAP_JET)

                                # Make it semi-transparent by adding alpha channel
                                # Alpha = confidence level (more confident = more visible)
                                alpha = (confidence * 200 + 55).astype(np.uint8)  # Range 55-255
                                heatmap_rgba = np.dstack([heatmap, alpha])

                                confidence_map_path = os.path.join(output_dir, "confidence_map.png")
                                cv2.imwrite(confidence_map_path, heatmap_rgba)
                                log_debug(f"Confidence map saved to: {confidence_map_path}")
                            except Exception as e:
                                log_warning(f"Failed to generate confidence map: {e}")

                            elapsed_ms = int((time.time() - start_time) * 1000)

                            sorted_indices = np.argsort(scores)[::-1].tolist()
                            sorted_mask_paths = [mask_paths[i] for i in sorted_indices]
                            sorted_scores = [float(scores[i]) for i in sorted_indices]

                            response = {
                                "success": True,
                                "masks": sorted_mask_paths,
                                "scores": sorted_scores,
                                "selectedIndex": 0,
                                "inferenceTimeMs": elapsed_ms,
                                "confidenceMapPath": confidence_map_path,
                            }
                            log_info(
                                f"Prediction complete: top score={sorted_scores[0]:.4f}, time={elapsed_ms}ms, masks={len(masks)}"
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
                    except Exception:
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


if __name__ == "__main__":
    if "--server" in sys.argv:
        model_type = "tiny"
        for i, arg in enumerate(sys.argv):
            if arg == "--model" and i + 1 < len(sys.argv):
                model_type = sys.argv[i + 1]
                break

        script_dir = os.path.dirname(os.path.abspath(__file__))

        output_dir = script_dir
        for i, arg in enumerate(sys.argv):
            if arg == "--output-dir" and i + 1 < len(sys.argv):
                output_dir = sys.argv[i + 1]
                break

        server_mode(model_type, script_dir, output_dir)
    else:
        cli_mode()
