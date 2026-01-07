# Modelr

A macOS application for interactive image segmentation and 3D model generation using Meta's SAM2 and Tencent's Hunyuan3D-2.

## Features

- **Interactive Segmentation**: Point, bounding box, lasso, and paint tools for precise object selection
- **Real-time Feedback**: Persistent Python worker for fast iterative refinement (~50ms per prediction)
- **3D Generation**: Convert masked images to 3D models using Hunyuan3D-2
- **Image Preprocessing**: Crop and lasso-delete tools to prepare images
- **Native macOS**: Built with SwiftUI, leveraging Metal Performance Shaders (MPS)
- **Self-Testing**: Automated validation during setup to ensure models are working correctly

## Screenshots

_Coming soon - Screenshots will be added in future releases_

## Requirements

- macOS 14.0+
- Xcode 15.0+
- Python 3.10+ (managed automatically via uv)
- Apple Silicon (M1/M2/M3) recommended for GPU acceleration

## Installation

### Quick Start

1. Clone the repository:

   ```bash
   git clone https://github.com/yourusername/Modelr.git
   cd Modelr
   ```

2. Install dependencies and build:

   ```bash
   make build
   ```

3. Run the application:
   ```bash
   make run
   ```

### Manual Installation

1. Install [uv](https://github.com/astral-sh/uv) (Python package manager):

   ```bash
   curl -LsSf https://astral.sh/uv/install.sh | sh
   ```

2. Generate Xcode project:

   ```bash
   xcodegen generate
   ```

3. Open and build in Xcode:
   ```bash
   open ModelrV3.xcodeproj
   ```

## Quick Start Guide

1. **Launch Modelr** - The app will automatically download and set up required Python models on first run
2. **Load an Image** - Drag and drop or paste an image into the editor
3. **Preprocess (Optional)** - Use crop or lasso-delete tools to prepare the image
4. **Segment** - Select a tool (point, box, lasso, or paint) to select your object
5. **Generate 3D** - Click "Generate 3D Model" in the Generate tab
6. **View Result** - Interact with your 3D model in the built-in viewer

## Architecture Overview

Modelr follows a clean architecture with clear separation of concerns:

```
┌─────────────────────────────────────────────────────────────┐
│                    SwiftUI Views                           │
│  ┌──────────────┐  ┌──────────────┐  ┌─────────────────┐  │
│  │  ContentView │  │ SplashScreen  │  │  ZoomableScroll │  │
│  └──────────────┘  └──────────────┘  └─────────────────┘  │
└─────────────────────────┬───────────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────────┐
│                    App Store (TCA)                          │
│  ┌──────────────┐  ┌──────────────┐  ┌─────────────────┐  │
│  │   AppState   │  │  AppAction   │  │  AppReducer    │  │
│  └──────────────┘  └──────────────┘  └─────────────────┘  │
└─────────────────────────┬───────────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────────┐
│               PythonEnvironment (ViewModel)                 │
│  - Persistent worker management                            │
│  - SAM2 inference coordination                            │
│  - Hunyuan3D generation                                  │
└─────────────────────────┬───────────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────────┐
│                    Python Backend                          │
│  ┌──────────────┐              ┌──────────────────┐        │
│  │ sam_wrapper  │ (stdin/stdout) │ hunyuan_wrapper │        │
│  │    (SAM2)    │◄─────────────►│   (Hunyuan3D)   │        │
│  └──────────────┘              └──────────────────┘        │
└─────────────────────────────────────────────────────────────┘
```

### Key Components

- **Views**: SwiftUI interface components
- **Store**: TCA-style state management
- **PythonEnvironment**: Coordinates with Python backend
- **Python Wrappers**: SAM2 and Hunyuan3D model execution

## Development Setup

### Prerequisites

```bash
# Install uv
curl -LsSf https://astral.sh/uv/install.sh | sh

# Install Xcode command line tools
xcode-select --install
```

### Build Commands

```bash
# Generate Xcode project
make generate

# Build the project
make build

# Run the app
make run

# Run tests
make test

# Clean build artifacts
make clean
```

### Directory Structure

```
Modelr/
├── Modelr/                 # Main Swift application
│   ├── Core/
│   │   ├── Errors/          # Error definitions
│   │   ├── Models/          # Data models
│   │   ├── Services/        # Service protocols
│   │   └── Store/           # TCA state management
│   ├── Views/               # SwiftUI views
│   ├── ContentView.swift     # Main editor
│   ├── PythonEnvironment.swift  # Python coordination
│   └── ModelrV3App.swift   # App entry point (ModelrApp)
├── Resources/               # Python scripts and configs
│   ├── sam_wrapper.py       # SAM2 wrapper
│   ├── hunyuan_wrapper.py  # Hunyuan3D wrapper
│   ├── pyproject.toml      # SAM2 dependencies
│   └── pyproject_hunyuan.toml  # Hunyuan3D dependencies
├── docs/                   # Documentation
└── Makefile               # Build commands
```

## Troubleshooting

### Setup Issues

**Problem**: "uv binary not found"

- **Solution**: Ensure uv is installed and in your PATH

**Problem**: "Python worker failed to start"

- **Solution**: Check that `~/Library/Application Support/Modelr` exists and has correct permissions

### Model Download Issues

**Problem**: Models fail to download during setup

- **Solution**: Check your internet connection and HuggingFace access

**Problem**: Slow model downloads

- **Solution**: Progress monitoring is built into the setup UI. Be patient for first-time setup (~500MB total)

### Runtime Issues

**Problem**: "Prediction failed" errors

- **Solution**: Try resetting the predictor by clearing annotations and reloading the image

**Problem**: 3D generation fails

- **Solution**: Ensure you have enough RAM (8GB+ recommended) and disk space

### Performance Issues

**Problem**: Slow segmentation

- **Solution**: Use "base_plus" model (default) for best performance. Switch to "tiny" for older Macs.

**Problem**: 3D generation takes too long

- **Solution**: Reduce "Diffusion Steps" or "Mesh Resolution" in the Generate tab

## License

[Add your license here - e.g., MIT, Apache 2.0, etc.]

## Contributing

Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on contributing to Modelr.

## Acknowledgments

- [SAM2](https://github.com/facebookresearch/segment-anything-2) - Meta's Segment Anything Model 2
- [Hunyuan3D-2](https://github.com/tencent/Hunyuan3D-2) - Tencent's 3D generation model
- [uv](https://github.com/astral-sh/uv) - Fast Python package manager
- [SwiftUI](https://developer.apple.com/xcode/swiftui/) - Apple's UI framework
