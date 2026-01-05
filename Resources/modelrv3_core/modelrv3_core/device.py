"""Device detection utilities for ModelrV3."""

import torch
from typing import Optional
from .logging import get_logger

logger = get_logger("device_utils")


def get_device(device_override: Optional[str] = None) -> str:
    from .config import ModelConfig

    device = device_override or ModelConfig.DEVICE

    if device == "auto":
        if torch.backends.mps.is_available():
            device = "mps"
            logger.info("Auto-detected MPS (Apple Silicon) device")
        elif torch.cuda.is_available():
            device = "cuda"
            logger.info("Auto-detected CUDA (NVIDIA) device")
        else:
            device = "cpu"
            logger.info("No GPU available, using CPU")
    else:
        logger.info(f"Using manually specified device: {device}")

    return device


def check_gpu_available() -> bool:
    if torch.backends.mps.is_available():
        logger.debug("MPS (Apple Silicon) available")
        return True
    if torch.cuda.is_available():
        logger.debug("CUDA (NVIDIA) available")
        return True
    logger.debug("No GPU available")
    return False


def get_gpu_memory_info() -> dict:
    info = {"device": "cpu", "total_gb": 0, "allocated_gb": 0, "reserved_gb": 0}

    device = get_device()
    if device == "cuda":
        if torch.cuda.is_available():
            info["device"] = "cuda"
            info["total_gb"] = torch.cuda.get_device_properties(0).total_memory / 1e9
            info["allocated_gb"] = torch.cuda.memory_allocated(0) / 1e9
            info["reserved_gb"] = torch.cuda.memory_reserved(0) / 1e9
    elif device == "mps":
        info["device"] = "mps"
        info["total_gb"] = "unknown (MPS doesn't expose memory info)"
        info["allocated_gb"] = "unknown"
        info["reserved_gb"] = "unknown"

    return info


def health_check() -> dict:
    health = {
        "status": "healthy",
        "torch_version": torch.__version__,
        "device": get_device(),
        "gpu_available": check_gpu_available(),
        "gpu_memory": get_gpu_memory_info(),
        "timestamp": None,
    }

    try:
        from datetime import datetime

        health["timestamp"] = datetime.now().isoformat()

        test_tensor = torch.zeros(1, device=health["device"])
        test_tensor @= 2
        del test_tensor
    except Exception as e:
        health["status"] = "unhealthy"
        health["error"] = str(e)
        logger.error(f"Health check failed: {e}")

    return health
