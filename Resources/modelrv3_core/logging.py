"""Logging utilities for ModelrV3."""

import logging
import logging.handlers
import os
from datetime import datetime
from pathlib import Path

LOG_DIR = Path.home() / "Library" / "Logs" / "ModelrV3"
LOG_DIR.mkdir(parents=True, exist_ok=True)

LOG_FILE = LOG_DIR / "modelrv3.log"
LOG_LEVELS = ["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"]


def setup_logging(log_level: str = "INFO", log_to_file: bool = True) -> logging.Logger:
    logger = logging.getLogger("ModelrV3")
    logger.setLevel(getattr(logging, log_level.upper(), logging.INFO))
    logger.handlers.clear()

    formatter = logging.Formatter(
        "%(asctime)s - %(name)s - %(levelname)s - [%(filename)s:%(lineno)d] - %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    console_handler = logging.StreamHandler()
    console_handler.setFormatter(formatter)
    logger.addHandler(console_handler)

    if log_to_file:
        file_handler = logging.handlers.RotatingFileHandler(
            LOG_FILE, maxBytes=10 * 1024 * 1024, backupCount=5
        )
        file_handler.setFormatter(formatter)
        logger.addHandler(file_handler)

    return logger


def get_logger(name: str = "ModelrV3") -> logging.Logger:
    if not logging.getLogger("ModelrV3").handlers:
        setup_logging()
    return logging.getLogger(f"ModelrV3.{name}")


class LoggerMixin:
    """Mixin class that provides logging functionality."""

    @property
    def logger(self) -> logging.Logger:
        return get_logger(self.__class__.__module__)


def log_info(message: str, logger: logging.Logger = None) -> None:
    if logger:
        logger.info(message)
    else:
        print(message, file=__import__("sys").stderr)


def log_error(message: str, logger: logging.Logger = None) -> None:
    if logger:
        logger.error(message)
    else:
        print(f"ERROR: {message}", file=__import__("sys").stderr)


def log_debug(message: str, logger: logging.Logger = None) -> None:
    if logger:
        logger.debug(message)


def log_warning(message: str, logger: logging.Logger = None) -> None:
    if logger:
        logger.warning(message)
    else:
        print(f"WARNING: {message}", file=__import__("sys").stderr)
