#!/usr/bin/env python3
"""
End-to-End test for SAM3 MLX segmentation.

Tests the full pipeline:
1. Load model
2. Set image
3. Run prediction with point prompt
4. Verify mask is generated

Run: python test_e2e_sam.py
"""
import os
import sys
import json
import time
import subprocess
import tempfile
from pathlib import Path

# Add current directory to path
sys.path.insert(0, str(Path(__file__).parent))


def create_test_image():
    """Create a simple test image with PIL."""
    from PIL import Image, ImageDraw

    # Create 512x512 image with a distinct object (circle in center)
    img = Image.new("RGB", (512, 512), color=(200, 200, 200))
    draw = ImageDraw.Draw(img)

    # Draw a blue circle in the center
    center = (256, 256)
    radius = 100
    draw.ellipse(
        [center[0] - radius, center[1] - radius,
         center[0] + radius, center[1] + radius],
        fill=(50, 50, 200)
    )

    # Save to temp file
    with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as f:
        img.save(f.name)
        return f.name


def test_cli_mode():
    """Test CLI mode (single-shot segmentation)."""
    print("\n" + "=" * 60)
    print("TEST: CLI Mode")
    print("=" * 60)

    test_image = create_test_image()
    output_mask = tempfile.mktemp(suffix=".png")

    try:
        # Test point mode - click center of image where circle is
        cmd = [
            sys.executable,
            str(Path(__file__).parent / "sam_wrapper.py"),
            test_image,
            "256", "256",  # Center point
            output_mask
        ]

        print(f"Running: {' '.join(cmd)}")
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)

        print(f"stdout: {result.stdout}")
        print(f"stderr: {result.stderr}")
        print(f"Return code: {result.returncode}")

        if result.returncode == 0 and os.path.exists(output_mask):
            print(f"SUCCESS: Mask generated at {output_mask}")
            # Check mask file size
            mask_size = os.path.getsize(output_mask)
            print(f"Mask file size: {mask_size} bytes")
            return True
        else:
            print("FAILED: CLI mode failed")
            return False

    except subprocess.TimeoutExpired:
        print("FAILED: Timeout")
        return False
    except Exception as e:
        print(f"FAILED: {e}")
        return False
    finally:
        # Cleanup
        if os.path.exists(test_image):
            os.unlink(test_image)
        if os.path.exists(output_mask):
            os.unlink(output_mask)


def test_server_mode():
    """Test server mode (persistent process with JSON protocol)."""
    print("\n" + "=" * 60)
    print("TEST: Server Mode")
    print("=" * 60)

    test_image = create_test_image()
    output_dir = tempfile.mkdtemp()

    try:
        # Start server process
        cmd = [
            sys.executable,
            str(Path(__file__).parent / "sam_wrapper.py"),
            "--server",
            "--output-dir", output_dir
        ]

        print(f"Starting server: {' '.join(cmd)}")

        proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1
        )

        def send_and_receive(request):
            """Send JSON request and receive response."""
            request_str = json.dumps(request) + "\n"
            print(f"-> Sending: {request_str.strip()}")
            proc.stdin.write(request_str)
            proc.stdin.flush()

            response_str = proc.stdout.readline()
            print(f"<- Received: {response_str.strip()}")
            return json.loads(response_str)

        # Wait for ready signal
        print("Waiting for ready signal...")
        ready_line = proc.stdout.readline()
        print(f"<- {ready_line.strip()}")
        ready_response = json.loads(ready_line)

        if not ready_response.get("ready"):
            print("FAILED: Server did not signal ready")
            return False

        print(f"Server ready on device: {ready_response.get('device', 'unknown')}")

        # Test 1: Set image
        print("\n--- Test: set_image ---")
        response = send_and_receive({
            "command": "set_image",
            "imagePath": test_image
        })

        if not response.get("success"):
            print(f"FAILED: set_image failed: {response.get('error')}")
            return False

        print(f"Image set: {response.get('width')}x{response.get('height')}")

        # Test 2: Predict with point prompt
        print("\n--- Test: predict (point) ---")
        response = send_and_receive({
            "command": "predict",
            "points": [[256, 256]],  # Center point where circle is
            "labels": [1]
        })

        if not response.get("success"):
            print(f"FAILED: predict failed: {response.get('error')}")
            return False

        masks = response.get("masks", [])
        scores = response.get("scores", [])
        inference_time = response.get("inferenceTimeMs", 0)

        print(f"Prediction complete in {inference_time}ms")
        print(f"Generated {len(masks)} mask(s)")
        print(f"Scores: {scores}")

        if not masks:
            print("FAILED: No masks generated")
            return False

        # Verify mask file exists
        primary_mask = masks[0]
        if not os.path.exists(primary_mask):
            print(f"FAILED: Mask file not found: {primary_mask}")
            return False

        mask_size = os.path.getsize(primary_mask)
        print(f"Primary mask: {primary_mask} ({mask_size} bytes)")

        # Test 3: Predict with box prompt
        print("\n--- Test: predict (box) ---")
        response = send_and_receive({
            "command": "predict",
            "box": [156, 156, 356, 356]  # Box around circle
        })

        if not response.get("success"):
            print(f"FAILED: predict with box failed: {response.get('error')}")
            return False

        print(f"Box prediction: {len(response.get('masks', []))} masks")

        # Test 4: Ping
        print("\n--- Test: ping ---")
        response = send_and_receive({"command": "ping"})

        if response.get("status") != "pong":
            print("FAILED: ping failed")
            return False

        print("Ping: pong")

        # Test 5: Exit
        print("\n--- Test: exit ---")
        response = send_and_receive({"command": "exit"})

        if response.get("status") != "exiting":
            print("FAILED: exit failed")
            return False

        print("Exit: graceful shutdown")

        # Wait for process to terminate
        proc.wait(timeout=5)

        print("\nSUCCESS: All server mode tests passed!")
        return True

    except subprocess.TimeoutExpired:
        print("FAILED: Timeout")
        proc.kill()
        return False
    except Exception as e:
        import traceback
        print(f"FAILED: {e}")
        traceback.print_exc()
        return False
    finally:
        # Cleanup
        if os.path.exists(test_image):
            os.unlink(test_image)
        # Cleanup output dir
        import shutil
        if os.path.exists(output_dir):
            shutil.rmtree(output_dir, ignore_errors=True)


def test_model_loading():
    """Test that model loads successfully."""
    print("\n" + "=" * 60)
    print("TEST: Model Loading (--test mode)")
    print("=" * 60)

    try:
        cmd = [
            sys.executable,
            str(Path(__file__).parent / "sam_wrapper.py"),
            "--test"
        ]

        print(f"Running: {' '.join(cmd)}")
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=180)

        print(result.stdout)
        if result.stderr:
            print(f"stderr: {result.stderr}")

        if result.returncode == 0:
            print("SUCCESS: Model loading test passed")
            return True
        else:
            print(f"FAILED: Return code {result.returncode}")
            return False

    except subprocess.TimeoutExpired:
        print("FAILED: Timeout (180s)")
        return False
    except Exception as e:
        print(f"FAILED: {e}")
        return False


def main():
    print("=" * 60)
    print("SAM3 MLX End-to-End Tests")
    print("=" * 60)
    print(f"Python: {sys.version}")
    print(f"Working directory: {os.getcwd()}")
    print(f"Script directory: {Path(__file__).parent}")

    results = {}

    # Run tests
    results["model_loading"] = test_model_loading()
    results["server_mode"] = test_server_mode()
    # results["cli_mode"] = test_cli_mode()  # Optional, depends on args parsing

    # Summary
    print("\n" + "=" * 60)
    print("SUMMARY")
    print("=" * 60)

    all_passed = True
    for test_name, passed in results.items():
        status = "PASS" if passed else "FAIL"
        print(f"  {test_name}: {status}")
        if not passed:
            all_passed = False

    if all_passed:
        print("\nAll tests passed!")
        sys.exit(0)
    else:
        print("\nSome tests failed!")
        sys.exit(1)


if __name__ == "__main__":
    main()
