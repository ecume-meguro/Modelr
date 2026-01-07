"""Validation utilities for Modelr."""

from pathlib import Path
from typing import List, Optional, Tuple
from PIL import Image
from .exceptions import ImageValidationError
from .logging import log_debug


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

        for i in range(len(points)):
            x, y = points[i]
            points[i] = [max(0, min(max_x, x)), max(0, min(max_y, y))]

    if box:
        if len(box) != 4:
            raise ImageValidationError(f"Box must have 4 coordinates, got {len(box)}")

        x1, y1, x2, y2 = box
        x1 = max(0, min(max_x, x1))
        y1 = max(0, min(max_y, y1))
        x2 = max(0, min(max_x, x2))
        y2 = max(0, min(max_y, y2))

        nx1, nx2 = min(x1, x2), max(x1, x2)
        ny1, ny2 = min(y1, y2), max(y1, y2)

        box[0], box[1], box[2], box[3] = nx1, ny1, nx2, ny2


def validate_output_dir(output_dir: str) -> None:
    path = Path(output_dir)
    if not path.exists():
        try:
            path.mkdir(parents=True, exist_ok=True)
        except Exception as e:
            raise ImageValidationError(f"Failed to create output directory: {e}")

    if not path.is_dir():
        raise ImageValidationError(f"Output path is not a directory: {output_dir}")


def validate_mask_compatibility(image_path: str, mask_path: str, logger=None) -> None:
    try:
        with Image.open(image_path) as img, Image.open(mask_path) as mask:
            img_size = img.size
            mask_size = mask.size

            if (
                abs(img_size[0] - mask_size[0]) > 10
                or abs(img_size[1] - mask_size[1]) > 10
            ):
                warning_msg = f"Image size {img_size} and mask size {mask_size} differ significantly"
                if logger:
                    logger.warning(warning_msg)
                else:
                    print(f"WARNING: {warning_msg}", file=__import__("sys").stderr)
    except Exception as e:
        raise ImageValidationError(f"Failed to validate mask compatibility: {e}")


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
