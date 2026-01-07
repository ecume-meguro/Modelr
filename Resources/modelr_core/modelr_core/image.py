"""Image processing utilities for Modelr."""

import os
import numpy as np
import cv2
from PIL import Image, ImageOps
from typing import Tuple, Optional, List

def load_image(path: str, convert_mode: str = "RGB") -> Image.Image:
    """Load an image and handle EXIF orientation."""
    image = Image.open(path)
    image = ImageOps.exif_transpose(image)
    return image.convert(convert_mode)

def save_mask_rgba(mask: np.ndarray, output_path: str, color: Tuple[int, int, int] = (50, 100, 200)) -> str:
    """
    Save a boolean or 0-1 mask as an RGBA PNG with a specific tint.
    The alpha channel contains the mask content.
    """
    # Handle MLX or Torch tensors if passed
    if hasattr(mask, "tolist"):
        mask = np.array(mask)
    
    # Squeeze to 2D
    while len(mask.shape) > 2:
        mask = mask.squeeze(0)
        
    mask_255 = (mask * 255).astype(np.uint8)
    h, w = mask_255.shape
    
    # Create RGBA array (OpenCV uses BGRA)
    rgba = np.zeros((h, w, 4), dtype=np.uint8)
    rgba[:, :, 0] = color[2] # B
    rgba[:, :, 1] = color[1] # G
    rgba[:, :, 2] = color[0] # R
    rgba[:, :, 3] = mask_255
    
    os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)
    cv2.imwrite(output_path, rgba)
    return output_path

def extract_foreground(image: Image.Image, mask: Image.Image) -> Image.Image:
    """Apply a mask to an image to extract the foreground.

    The mask can be:
    - Grayscale (L): values directly used as alpha
    - RGB: converted to grayscale, white=foreground, black=background
    - RGBA: uses luminance of RGB channels (not alpha) for compatibility

    Transparent areas are set to white RGB to avoid black edges being
    interpreted as geometry by 3D generation models.
    """
    image_rgba = image.convert("RGBA")

    # Convert mask to grayscale - this handles RGB, RGBA, and L modes correctly
    # For RGB/RGBA masks: white (255,255,255) -> 255, black (0,0,0) -> 0
    mask_gray = mask.convert("L")

    if mask_gray.size != image_rgba.size:
        mask_gray = mask_gray.resize(image_rgba.size, Image.Resampling.LANCZOS)

    image_array = np.array(image_rgba)
    mask_array = np.array(mask_gray)

    # Set transparent areas to clear (0,0,0,0)
    transparent_mask = mask_array < 128
    image_array[transparent_mask, 0] = 0  # R
    image_array[transparent_mask, 1] = 0  # G
    image_array[transparent_mask, 2] = 0  # B
    image_array[transparent_mask, 3] = 0  # A

    return Image.fromarray(image_array, "RGBA")
