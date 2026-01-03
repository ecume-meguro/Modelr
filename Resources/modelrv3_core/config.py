"""Configuration for ModelrV3."""

import os
from pathlib import Path
from typing import Tuple

CACHE_DIR = Path.home() / "Library" / "Application Support" / "ModelrV3"
CACHE_DIR.mkdir(parents=True, exist_ok=True)

CHECKPOINT_DIR = CACHE_DIR / "checkpoints"
CHECKPOINT_DIR.mkdir(parents=True, exist_ok=True)

LOG_DIR = Path.home() / "Library" / "Logs" / "ModelrV3"
LOG_DIR.mkdir(parents=True, exist_ok=True)

HUNYUAN_CACHE_DIR = CACHE_DIR / "Hunyuan3D"
HUNYUAN_CACHE_DIR.mkdir(parents=True, exist_ok=True)

os.environ["HY3DGEN_MODELS"] = str(HUNYUAN_CACHE_DIR)
os.environ["HF_HOME"] = str(HUNYUAN_CACHE_DIR / "hf_home")
os.environ["HUGGINGFACE_HUB_CACHE"] = str(HUNYUAN_CACHE_DIR / "hf_cache")
os.environ["TORCH_HOME"] = str(HUNYUAN_CACHE_DIR / "torch_home")


class ModelConfig:
    MODEL_TYPE: str = "base_plus"
    DEVICE: str = "auto"
    MAX_IMAGE_SIZE: int = 16384
    MASK_COLOR: Tuple[int, int, int, int] = (50, 100, 200, 255)
    DEFAULT_STEPS: int = 50
    DEFAULT_RESOLUTION: int = 512
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
