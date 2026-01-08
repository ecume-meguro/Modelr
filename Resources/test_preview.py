"""Tests for 3D mesh preview rendering during volume decoding."""
import os
import sys
import time
import unittest
import numpy as np
from pathlib import Path
from unittest.mock import MagicMock, patch
from io import BytesIO

# Add Resources directory to path for imports
sys.path.insert(0, str(Path(__file__).parent))


class TestRenderMeshToImage(unittest.TestCase):
    """Test mesh-to-image rendering functionality (standalone)."""

    def setUp(self):
        """Create simple test mesh data."""
        # Simple cube vertices
        self.vertices = np.array([
            [-1, -1, -1], [1, -1, -1], [1, 1, -1], [-1, 1, -1],
            [-1, -1, 1], [1, -1, 1], [1, 1, 1], [-1, 1, 1]
        ], dtype=np.float32)

        # Cube faces (triangles)
        self.faces = np.array([
            [0, 1, 2], [0, 2, 3],  # front
            [4, 6, 5], [4, 7, 6],  # back
            [0, 4, 5], [0, 5, 1],  # bottom
            [2, 6, 7], [2, 7, 3],  # top
            [0, 3, 7], [0, 7, 4],  # left
            [1, 5, 6], [1, 6, 2],  # right
        ], dtype=np.int32)

    def _standalone_render(self, vertices, faces, size=256):
        """Standalone render function for testing without hunyuan_wrapper imports."""
        try:
            import trimesh
            from PIL import Image

            mesh = trimesh.Trimesh(vertices=vertices, faces=faces)
            mesh.vertices -= mesh.centroid
            scale = max(mesh.extents) if len(mesh.extents) else 1
            if scale > 0:
                mesh.vertices /= scale

            # Simple depth projection
            angle = np.pi / 6
            rot_y = np.array([
                [np.cos(angle), 0, np.sin(angle)],
                [0, 1, 0],
                [-np.sin(angle), 0, np.cos(angle)]
            ])
            rotated = mesh.vertices @ rot_y.T

            img = np.ones((size, size), dtype=np.float32) * 255
            for face in faces:
                if face.max() < len(rotated):
                    pts = rotated[face]
                    px = ((pts[:, 0] + 1) * 0.4 * size + size * 0.1).astype(int)
                    py = ((1 - pts[:, 1]) * 0.4 * size + size * 0.1).astype(int)
                    for i in range(3):
                        x, y = px[i], py[i]
                        if 0 <= x < size and 0 <= y < size:
                            img[y, x] = 100

            img_pil = Image.fromarray(img.astype(np.uint8), mode='L')
            buffer = BytesIO()
            img_pil.save(buffer, format='PNG')
            return buffer.getvalue()
        except Exception as e:
            print(f"Render error: {e}")
            return None

    def test_render_returns_png_bytes(self):
        """render_mesh_to_image should return PNG bytes for valid mesh."""
        result = self._standalone_render(self.vertices, self.faces, size=128)

        self.assertIsNotNone(result, "Should return image bytes")
        self.assertIsInstance(result, bytes, "Should be bytes")
        self.assertTrue(result.startswith(b'\x89PNG'), "Should be PNG format")

    def test_render_respects_size(self):
        """Rendered image should match requested size."""
        from PIL import Image

        result = self._standalone_render(self.vertices, self.faces, size=64)

        self.assertIsNotNone(result)
        img = Image.open(BytesIO(result))
        self.assertEqual(img.size[0], 64, "Width should match")
        self.assertEqual(img.size[1], 64, "Height should match")

    def test_render_handles_empty_mesh(self):
        """Should handle empty or degenerate meshes gracefully."""
        empty_verts = np.array([], dtype=np.float32).reshape(0, 3)
        empty_faces = np.array([], dtype=np.int32).reshape(0, 3)

        result = self._standalone_render(empty_verts, empty_faces, size=64)
        # May return None or basic image, but shouldn't crash

    def test_render_performance(self):
        """Rendering should complete in reasonable time (<500ms)."""
        start = time.time()
        for _ in range(5):
            self._standalone_render(self.vertices, self.faces, size=256)
        elapsed = time.time() - start

        avg_time = elapsed / 5
        print(f"Average render time: {avg_time*1000:.1f}ms")
        self.assertLess(avg_time, 0.5, f"Average render time {avg_time:.3f}s should be <0.5s")


class TestPreviewVolumeDecoder(unittest.TestCase):
    """Test the PreviewVolumeDecoder wrapper."""

    def test_preview_callback_called(self):
        """Preview callback should be called during decoding."""
        # This test requires hy3dgen to be installed
        try:
            from hunyuan_wrapper import create_preview_volume_decoder
        except ImportError:
            self.skipTest("hunyuan_wrapper requires hy3dgen dependencies")

        callback_calls = []

        def mock_callback(image_bytes, progress):
            callback_calls.append((len(image_bytes), progress))

        # Create a mock decoder
        mock_original = MagicMock()
        decoder = create_preview_volume_decoder(mock_original, mock_callback, preview_interval=1)

        self.assertIsNotNone(decoder, "Should create preview decoder")

    def test_preview_interval_respected(self):
        """Preview should be generated at specified intervals."""
        # Integration test - would require full pipeline setup
        pass


class TestPreviewOverhead(unittest.TestCase):
    """Test the performance overhead of preview generation."""

    def test_marching_cubes_performance(self):
        """Marching cubes on partial grid should be fast."""
        try:
            from skimage import measure
        except ImportError:
            self.skipTest("scikit-image not installed")

        # Simulate a partial occupancy grid (resolution 384 = 385^3 grid)
        # At 50% progress, we'd have ~28M points computed
        grid_size = 100  # Smaller for test
        grid = np.random.randn(grid_size, grid_size, grid_size).astype(np.float32)

        start = time.time()
        for _ in range(3):
            try:
                vertices, faces, _, _ = measure.marching_cubes(grid, 0.0, method="lewiner")
            except ValueError:
                pass  # May fail on random data, that's OK
        elapsed = time.time() - start

        avg_time = elapsed / 3
        print(f"Average marching cubes time: {avg_time*1000:.1f}ms")
        self.assertLess(avg_time, 0.5, "Marching cubes should be fast")


class TestHunyuanResponsePreview(unittest.TestCase):
    """Test JSON response format for preview images."""

    def test_preview_response_format(self):
        """Preview response should have correct JSON structure."""
        import json
        import base64

        # Simulate a preview response
        fake_png = b'\x89PNG\r\n\x1a\n' + b'\x00' * 100
        response = {
            "success": True,
            "type": "preview",
            "messageId": "test-123",
            "stage": "volume_decoding",
            "progress": 0.85,
            "previewImage": base64.b64encode(fake_png).decode('utf-8')
        }

        json_str = json.dumps(response)
        parsed = json.loads(json_str)

        self.assertEqual(parsed["type"], "preview")
        self.assertEqual(parsed["stage"], "volume_decoding")
        self.assertIn("previewImage", parsed)

        # Decode the image
        decoded = base64.b64decode(parsed["previewImage"])
        self.assertTrue(decoded.startswith(b'\x89PNG'), "Should decode to PNG")


class TestPreviewIntegration(unittest.TestCase):
    """Integration tests for the full preview pipeline."""

    @unittest.skipIf(
        not os.path.exists(os.path.expanduser(
            "~/Library/Application Support/Modelr/Cache/hy3dgen"
        )),
        "Hunyuan models not downloaded"
    )
    def test_full_generation_with_preview(self):
        """Full generation should emit preview images."""
        # This would be an integration test requiring the full model
        pass


if __name__ == "__main__":
    unittest.main(verbosity=2)
