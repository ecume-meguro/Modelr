"""Tests for SAM2.1 wrapper functionality."""
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import patch, MagicMock

# Add Resources directory to path for imports
sys.path.insert(0, str(Path(__file__).parent))

import sam_wrapper


class TestModelConfigs(unittest.TestCase):
    """Test model configuration mappings."""

    def test_model_configs_exist(self):
        """All model configs should be defined."""
        expected_types = ["tiny", "small", "base_plus", "large"]
        for model_type in expected_types:
            self.assertIn(model_type, sam_wrapper.MODEL_CONFIGS)
            self.assertIn(model_type, sam_wrapper.MODEL_CHECKPOINTS)
            self.assertIn(model_type, sam_wrapper.CHECKPOINT_URLS)

    def test_model_configs_use_sam21_paths(self):
        """Model configs should use SAM2.1 config paths."""
        for model_type, config_path in sam_wrapper.MODEL_CONFIGS.items():
            self.assertTrue(
                config_path.startswith("configs/sam2.1/"),
                f"{model_type} config should use configs/sam2.1/ prefix, got: {config_path}"
            )
            self.assertIn("sam2.1_hiera", config_path)

    def test_model_checkpoints_use_sam21(self):
        """Model checkpoints should use SAM2.1 checkpoint names."""
        for model_type, checkpoint in sam_wrapper.MODEL_CHECKPOINTS.items():
            self.assertTrue(
                checkpoint.startswith("sam2.1_"),
                f"{model_type} checkpoint should start with sam2.1_, got: {checkpoint}"
            )

    def test_checkpoint_urls_are_valid(self):
        """Checkpoint URLs should be HTTPS and point to valid sources."""
        for model_type, config in sam_wrapper.CHECKPOINT_URLS.items():
            self.assertIn("primary", config)
            self.assertIn("mirror", config)
            self.assertIn("checksum", config)

            self.assertTrue(config["primary"].startswith("https://"))
            self.assertTrue(config["mirror"].startswith("https://"))
            self.assertEqual(len(config["checksum"]), 64)  # SHA256 hex length


class TestSam2ConfigsAvailable(unittest.TestCase):
    """Test that SAM2.1 configs are available in the installed package."""

    def test_sam2_package_has_configs(self):
        """The sam2 package should have SAM2.1 config files."""
        try:
            import sam2
            sam2_path = Path(sam2.__file__).parent

            for model_type, config_path in sam_wrapper.MODEL_CONFIGS.items():
                full_path = sam2_path / config_path
                self.assertTrue(
                    full_path.exists(),
                    f"Config file not found for {model_type}: {full_path}"
                )
        except ImportError:
            self.skipTest("sam2 package not installed")


class TestModelLoading(unittest.TestCase):
    """Test model loading functionality."""

    @unittest.skipIf(
        not os.path.exists(os.path.expanduser(
            "~/Library/Application Support/ModelrV3/checkpoints/sam2.1_hiera_base_plus.pt"
        )),
        "Checkpoint not downloaded"
    )
    def test_build_sam2_model(self):
        """Test that SAM2.1 model can be built with correct config."""
        import torch
        from sam2.build_sam import build_sam2

        model_cfg = sam_wrapper.MODEL_CONFIGS["base_plus"]
        checkpoint_path = os.path.expanduser(
            "~/Library/Application Support/ModelrV3/checkpoints/sam2.1_hiera_base_plus.pt"
        )
        device = "mps" if torch.backends.mps.is_available() else "cpu"

        model = build_sam2(model_cfg, checkpoint_path, device=device)
        self.assertIsNotNone(model)
        self.assertEqual(type(model).__name__, "SAM2Base")


class TestValidation(unittest.TestCase):
    """Test input validation functions."""

    def test_validate_coordinates_clamps_points(self):
        """Points should be clamped to image bounds."""
        points = [[-10, -10], [2000, 2000]]
        sam_wrapper.validate_coordinates(points, None, 100, 100)

        self.assertEqual(points[0], [0, 0])
        self.assertEqual(points[1], [100, 100])

    def test_validate_coordinates_clamps_box(self):
        """Box should be clamped and normalized."""
        box = [-10, -10, 200, 200]
        sam_wrapper.validate_coordinates(None, box, 100, 100)

        self.assertEqual(box, [0, 0, 100, 100])

    def test_validate_coordinates_normalizes_box_order(self):
        """Box with reversed coordinates should be normalized."""
        box = [80, 80, 20, 20]  # x2 < x1, y2 < y1
        sam_wrapper.validate_coordinates(None, box, 100, 100)

        self.assertEqual(box, [20, 20, 80, 80])


if __name__ == "__main__":
    unittest.main(verbosity=2)
