"""Configuration for Modelr."""

import os
from pathlib import Path
from typing import Tuple

APP_SUPPORT_DIR = Path(os.environ.get("MODELR_APP_SUPPORT_DIR") or (Path.home() / "Library" / "Application Support" / "Modelr"))
APP_SUPPORT_DIR.mkdir(parents=True, exist_ok=True)

# Cache root (pure caches; Swift may override via environment variables)
CACHE_DIR = APP_SUPPORT_DIR / "Cache"
CACHE_DIR.mkdir(parents=True, exist_ok=True)

# Persistent checkpoints (heavy)
CHECKPOINT_DIR = Path(os.environ.get("MODELR_CHECKPOINTS_DIR") or (APP_SUPPORT_DIR / "Models" / "checkpoints"))
CHECKPOINT_DIR.mkdir(parents=True, exist_ok=True)

# Logs (Swift prefers Application Support/Logs)
LOG_DIR = Path(os.environ.get("MODELR_LOGS_DIR") or (APP_SUPPORT_DIR / "Logs"))
LOG_DIR.mkdir(parents=True, exist_ok=True)

# Unified models hub cache (HuggingFace/transformers)
MODELS_HUB_DIR = Path(
    os.environ.get("HUGGINGFACE_HUB_CACHE")
    or os.environ.get("TRANSFORMERS_CACHE")
    or (APP_SUPPORT_DIR / "Models" / "hub")
)
MODELS_HUB_DIR.mkdir(parents=True, exist_ok=True)

# Back-compat name used by existing wrappers
HUNYUAN_CACHE_DIR = MODELS_HUB_DIR

# Respect values provided by the Swift host process.
HY3DGEN_MODELS_DIR = APP_SUPPORT_DIR / "Models" / "hy3dgen"
HY3DGEN_MODELS_DIR.mkdir(parents=True, exist_ok=True)
os.environ.setdefault("HY3DGEN_MODELS", str(HY3DGEN_MODELS_DIR))
os.environ.setdefault("TORCH_HOME", str(CACHE_DIR / "torch"))

# Prefer HF_HOME if provided; otherwise default into the Hunyuan cache directory.
os.environ.setdefault("HF_HOME", str(APP_SUPPORT_DIR / "Models"))


import json

# Load project config
# Swift sets MODELR_CONFIG_PATH to keep config under Application Support/Config.
# Legacy MODELRV3_CONFIG_PATH supported for backward compatibility.
CONFIG_PATH_ENV = os.environ.get("MODELR_CONFIG_PATH") or os.environ.get("MODELRV3_CONFIG_PATH")
if CONFIG_PATH_ENV:
    CONFIG_PATH = Path(CONFIG_PATH_ENV)
else:
    PROJECT_ROOT = Path(__file__).parent.parent.parent
    CONFIG_PATH = PROJECT_ROOT / "Resources" / "project_config.json"

try:
    with open(CONFIG_PATH, "r") as f:
        _proj_config = json.load(f)
except Exception:
    _proj_config = {}

class ModelConfig:
    MODEL_TYPE: str = _proj_config.get("models", {}).get("sam2", {}).get("default_type", "base_plus")
    DEVICE: str = "auto"
    MAX_IMAGE_SIZE: int = _proj_config.get("limits", {}).get("max_image_size", 16384)
    MASK_COLOR: Tuple[int, int, int, int] = tuple(_proj_config.get("models", {}).get("sam2", {}).get("mask_color", [50, 100, 200, 255]))
    DEFAULT_STEPS: int = _proj_config.get("models", {}).get("hunyuan3d", {}).get("default_steps", 50)
    DEFAULT_RESOLUTION: int = _proj_config.get("models", {}).get("hunyuan3d", {}).get("default_resolution", 512)
    MAX_RETRIES: int = 3
    RETRY_MIN_WAIT: float = 1.0
    RETRY_MAX_WAIT: float = 10.0

    @classmethod
    def get_checkpoint_dir(cls) -> Path:
        return CHECKPOINT_DIR

    @classmethod
    def get_hunyuan_cache_dir(cls) -> Path:
        return HUNYUAN_CACHE_DIR

    @classmethod
    def get_log_dir(cls) -> Path:
        return LOG_DIR

    @classmethod
    def set_model_type(cls, model_type: str) -> None:
        valid_types = ["tiny", "small", "base_plus", "large"]
        if model_type not in valid_types:
            raise ValueError(
                f"Invalid model type: {model_type}. Must be one of {valid_types}"
            )
        cls.MODEL_TYPE = model_type

    @classmethod
    def set_device(cls, device: str) -> None:
        valid_devices = ["auto", "cpu", "mps", "cuda"]
        if device not in valid_devices:
            raise ValueError(
                f"Invalid device: {device}. Must be one of {valid_devices}"
            )
        cls.DEVICE = device


class PerformanceConfig:
    ENABLE_METRICS: bool = True
    INFERENCE_THRESHOLD_MS: int = 5000
    MEMORY_THRESHOLD_GB: float = 8.0
    CACHE_TTL_SECONDS: int = 3600


metrics = {
    "inference_times": [],
    "generation_times": [],
    "memory_usage": [],
    "cache_hits": 0,
    "cache_misses": 0,
}
