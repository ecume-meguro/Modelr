"""Base server class for persistent model workers."""

import sys
import json
import time
import os
import traceback
import numpy as np
from typing import Dict, Any, Optional, Tuple, List
from .logging import get_logger, log_info, log_error, log_debug, log_warning
from .image import load_image

class BaseModelServer:
    """
    Standardizes the persistent worker loop and common command handling.
    Inherit from this class and implement perform_prediction.
    """
    
    def __init__(self, name: str, model_type: str = "default"):
        self.name = name
        self.model_type = model_type
        self.logger = get_logger(name)
        self.current_image_np = None
        self.image_set = False
        self.inference_state = None
        self.device = "cpu"
        self.processor = None
        
    def load_model(self) -> Tuple[Any, str]:
        """Implement model loading logic here."""
        raise NotImplementedError("load_model must be implemented by subclass")
        
    def initialize(self):
        """Initialize the server and load the model."""
        log_info(f"Initializing {self.name} server...", self.logger)
        self.processor, self.device = self.load_model()
        log_info(f"{self.name} model loaded on {self.device}", self.logger)
        
    def handle_set_image(self, request: Dict[str, Any]) -> Dict[str, Any]:
        """Common handling for setting a new image."""
        image_path = request.get("imagePath")
        if not image_path or not os.path.exists(image_path):
            return {"success": False, "error": "Image not found"}
        
        try:
            image = load_image(image_path)
            self.current_image_np = np.array(image)
            
            # Subclasses can override this to prepare internal state
            self.inference_state = self.prepare_image(image)
            self.image_set = True
            
            h, w = self.current_image_np.shape[:2]
            return {"success": True, "width": w, "height": h}
        except Exception as e:
            log_error(f"Error setting image: {e}", self.logger)
            return {"success": False, "error": str(e)}
            
    def prepare_image(self, image: Any) -> Any:
        """Optional hook to process image after loading."""
        return None

    def handle_predict(self, request: Dict[str, Any]) -> Dict[str, Any]:
        """Dispatch to subclass prediction implementation."""
        if not self.image_set:
            return {"success": False, "error": "No image set"}
            
        start_time = time.time()
        try:
            response = self.perform_prediction(request)
            inference_time = int((time.time() - start_time) * 1000)
            if response.get("success", False):
                response["inferenceTimeMs"] = inference_time
            return response
        except Exception as e:
            log_error(f"Prediction error: {e}", self.logger)
            log_debug(traceback.format_exc(), self.logger)
            return {"success": False, "error": str(e)}

    def perform_prediction(self, request: Dict[str, Any]) -> Dict[str, Any]:
        """Subclasses must implement this."""
        raise NotImplementedError("perform_prediction must be implemented by subclass")

    def run(self):
        """Standard JSON communication loop."""
        try:
            self.initialize()

            # Signal ready to Swift with a known messageId for the UnifiedProcessBridge
            print(json.dumps({
                "messageId": "READY",
                "success": True,
                "ready": True,
                "device": self.device,
                "server": self.name
            }), flush=True)

            for line in sys.stdin:
                line = line.strip()
                if not line:
                    continue

                try:
                    request = json.loads(line)
                    command = request.get("command", "")
                    message_id = request.get("messageId")  # Echo back messageId

                    if command == "set_image":
                        response = self.handle_set_image(request)
                    elif command == "predict":
                        response = self.handle_predict(request)
                    elif command == "ping":
                        response = {"success": True, "status": "pong", "device": self.device}
                    elif command == "exit":
                        exit_response = {"success": True, "status": "exiting"}
                        if message_id:
                            exit_response["messageId"] = message_id
                        print(json.dumps(exit_response), flush=True)
                        break
                    else:
                        response = self.handle_custom_command(command, request)

                    # Always include messageId in response if it was in request
                    if message_id:
                        response["messageId"] = message_id
                    print(json.dumps(response), flush=True)

                except json.JSONDecodeError as e:
                    print(json.dumps({"success": False, "error": f"Invalid JSON: {e}"}), flush=True)
                except Exception as e:
                    log_error(f"Loop error: {e}", self.logger)
                    print(json.dumps({"success": False, "error": str(e)}), flush=True)

        except Exception as e:
            log_error(f"Fatal server error: {e}", self.logger)
            log_error(traceback.format_exc(), self.logger)
            sys.exit(1)

    def handle_custom_command(self, command: str, request: Dict[str, Any]) -> Dict[str, Any]:
        """Override to handle additional commands."""
        return {"success": False, "error": f"Unknown command: {command}"}
