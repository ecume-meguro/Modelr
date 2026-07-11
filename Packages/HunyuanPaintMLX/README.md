# HunyuanPaintMLX — mlx-swift port

Native **Swift** (mlx-swift) port of the Hunyuan3D **paint diffusion core**, for shippable
macOS/iOS apps (Metal runs in the App Store sandbox). The Python package in the repo root is the
parity reference; this package re-implements each module against
[`mlx-swift`](https://github.com/ml-explore/mlx-swift), loading the **same converted weights**.

Because mlx-swift calls the **same MLX Metal backend** as Python MLX, identical weights + op order
give **bit-identical** output. Parity is transitive: **Swift == Python MLX (CUDA-parity) == CUDA**.

## parity panel (`swift run -c release paint-cli`)

| Module | cosine | maxabs | notes |
|---|---|---|---|
| VAE decode | 0.9999999 | **0.0** | bit-exact |
| VAE encode_mean | 0.9999999 | **0.0** | bit-exact |
| RealESRGAN x4 | 0.9999999 | **0.0** | bit-exact |
| DDIM trajectory | 1.0000000 | **0.0** | bit-exact (acp recomputed in Double) |
| UniPC trajectory | 1.0000000 | 3.6e-7 | 157 dB |
| SD2.1 UNet backbone | 1.0000000 | 3.2e-6 | 127 dB |
| DINOv2-giant (40-layer ViT) | 1.0000001 | 1.8e-5 | 145 dB |
| **2.1 PBR UNet** (material/ref/MV-RoPE/DINO) | 1.0000000 | 8.2e-5 | 106 dB — matches Python's own CUDA tolerance |
| **Full PBR diffusion e2e** (prepare + CFG loop + UniPC) | 1.0000000 | 6.0e-4 | 99 dB |

The only non-bit-exact precompute is the PoseRoPE **voxel index** quantization (numpy fp16 vs MLX
fp16): ≤1 off-by-one per cell — the same fp16 boundary residual Python itself carries vs CUDA. The
neural diffusion path is cosine-1.0 parity.

## layout
- `Sources/HunyuanPaintMLX/`
  - `Layers2D.swift` — GroupNorm (fp32), Conv2d, Linear, Resnet(+temb), Up/Downsample, VAEAttn
  - `VAE.swift` — AutoencoderKL (encode/decode)
  - `RealESRGAN.swift` — RRDBNet x4
  - `Scheduler.swift` — DDIM + UniPC multistep
  - `Attention.swift` — timestep embed, Attention, FeedForward, BasicTransformerBlock (2.5D MA/RA), Transformer2D
  - `UNet.swift` — SD2.1 UNet2DConditionModel (down/mid/up)
  - `PBRAttention.swift` — 3D PoseRoPE, material (MDA) / reference (RA) / multiview attn, PBR block
  - `PBRWrapper.swift` — ImageProjModel, voxel indices, dual-pass `prepare`, the diffusion step
  - `Dinov2.swift` — DINOv2-giant (ViT + SwiGLU)
- `Sources/paint-cli/main.swift` — the parity gate (loads fixtures, compares to Python)
- `*.py` dumpers + `fixtures/*.safetensors` — Python-dumped weights + reference IO

Functional style: weights live in a `[String: MLXArray]` dict keyed by the Python MLX module path;
forward functions index it. `IntOrPair` takes a tuple init: `IntOrPair((0,1))`.

## build & run
```bash
# one-time on macOS 26/27: xcodebuild -downloadComponent MetalToolchain
# (re)dump fixtures from repo root:  uv run python swift/dump_*.py
cd swift && swift run -c release paint-cli
```

## not ported (native host glue, out of scope for the diffusion core)
Mesh I/O (Model I/O), xatlas UV-unwrap, the Metal cr-rasterizer (reuse `gpu_raster`), bake, inpaint.
