import logging
import logging.handlers
import os
from datetime import datetime
from pathlib import Path

LOG_DIR = Path.home() / "Library" / "Logs" / "Modelr"
LOG_DIR.mkdir(parents=True, exist_ok=True)

LOG_FILE = LOG_DIR / "modelr.log"
LOG_LEVELS = ["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"]


def setup_logging(log_level: str = "INFO", log_to_file: bool = True) -> logging.Logger:
    logger = logging.getLogger("Modelr")
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


def get_logger(name: str = "Modelr") -> logging.Logger:
    if not logging.getLogger("Modelr").handlers:
        setup_logging()
    return logging.getLogger(f"Modelr.{name}")


logger = get_logger()
