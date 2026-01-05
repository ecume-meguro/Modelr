"""
ModelrV3 Shared Python Core Module

Consolidates common utilities used across all wrapper modules.
Provides exception classes, logging, validation, device detection, and utilities.
"""

from .exceptions import (
    ModelLoadError,
    ImageValidationError,
    GenerationError,
    OutOfMemoryError,
    NetworkError,
    ProtocolError,
)

from .logging import (
    setup_logging,
    get_logger,
    log_info,
    log_error,
    log_debug,
    log_warning,
)

from .validators import (
    validate_image_path,
    validate_coordinates,
    validate_output_dir,
    validate_mask_compatibility,
    validate_image_dimensions,
)

from .device import (
    get_device,
    check_gpu_available,
    health_check,
)

from .download import (
    download_with_progress,
    compute_sha256,
)

from .config import (
    ModelConfig,
    PerformanceConfig,
    metrics,
)

from .image import (
    load_image,
    save_mask_rgba,
    extract_foreground,
)

__all__ = [
    "ModelLoadError",
    "ImageValidationError",
    "GenerationError",
    "OutOfMemoryError",
    "NetworkError",
    "ProtocolError",
    "setup_logging",
    "get_logger",
    "log_info",
    "log_error",
    "log_debug",
    "log_warning",
    "validate_image_path",
    "validate_coordinates",
    "validate_output_dir",
    "validate_mask_compatibility",
    "validate_image_dimensions",
    "get_device",
    "check_gpu_available",
    "health_check",
    "download_with_progress",
    "compute_sha256",
    "ModelConfig",
    "PerformanceConfig",
    "metrics",
    "load_image",
    "save_mask_rgba",
    "extract_foreground",
]
