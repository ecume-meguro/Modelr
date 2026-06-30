# Modelr

A native macOS app for local **image → 3D shape** generation. Sidebar of projects;
drag an image into the left panel, watch the mesh form in the right panel. Built on
the local **Hunyuan3D-Shape-MLX** pipeline (pure MLX, no PyTorch in the path),
driven out-of-process and rendered with SceneKit.

## Using it

1. **+ New Project**, then **drag an image** onto the left panel — generation starts
   automatically.
2. The right panel shows the live reveal: a rotating point-cloud while denoising,
   then an accent-coloured **point cloud that materialises the surface** as the
   octree decode sweeps it, then the final mesh (orbit with the mouse).
3. **Model** and **Quality** are per-project, in the toolbar:

   | Model | | Quality |
   |---|---|---|
   | **Mini** — 2mini, 0.6B, fastest | | **Full** — fp16, best |
   | **Standard** — 2.0, 1.1B, best detail | | **8-bit** — near-lossless |
   | **Large** — 2.1, 3.3B MoE, largest | | **4-bit** — smallest, faster |

   Mini is the fast default (~15–20s). 2.0/2.1 are much heavier (minutes); 4-bit
   speeds them up a lot (e.g. 2.0: 254s → 79s, near-lossless).

## Build

```bash
brew install xcodegen        # if needed
xcodegen generate            # creates Modelr.xcodeproj from project.yml
open Modelr.xcodeproj         # ⌘R, or:
xcodebuild -scheme Modelr -configuration Debug build
```

Signed automatically with the local **Apple Development** identity (team
`W9C2P3N7Q2`, manual signing with the cert hash in `project.yml`). The app is
unsandboxed so it can launch the model worker and read dropped images.

## How it works

- **SwiftUI app** (`Sources/`) — sidebar/projects, drag-drop, SceneKit viewer.
- **Out-of-process worker** — `GenerationService` writes `modelr_worker.py` to
  Application Support and runs `…/.venv/bin/python3.12 -u modelr_worker.py …`
  (no shell, so signals reach it). The worker reimplements the FlowMatch denoise
  loop and calls `vae.query_grid_octree` (FlashVDM fast decode). Stage/progress
  and a streamed near-surface **point cloud** come back over stdout
  (`[denoise] i/n`, `[grid] n`, `[points] <path>`).
- **Process hygiene** ([`JobReaper.swift`](Sources/JobReaper.swift)) — workers run
  with a `getppid()==1` parent-death watchdog, a PID registry verified by resolved
  interpreter path before any SIGKILL, and a launch-time sweep, so a crash or
  force-quit never leaves an orphaned GPU process. A per-project generation token
  ([`ProjectStore.swift`](Sources/ProjectStore.swift)) keeps a cancelled run's late
  callbacks from clobbering its replacement.

Model paths and fixed parameters live in
[`PipelineConfig.swift`](Sources/PipelineConfig.swift); the engine is
`/Users/xzm/Projects/Hunyuan3D-Shape-MLX`.

## Storage

`~/Library/Application Support/Modelr/`
- `projects.json` — index (name, model, quantization)
- `projects/<uuid>/input.*`, `output.obj` — per-project files
- `running-pids.json`, `modelr_worker.py` — runtime
