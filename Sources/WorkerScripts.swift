import Foundation

/// The two out-of-process MLX worker scripts, written to Application Support at
/// launch and run by GenerationService. Kept as constants (not bundled resources)
/// so the app stays a single self-contained binary.
enum WorkerScripts {
    /// Shape (Hunyuan3D-Shape-MLX): image -> binary .mesh, streams preview/points.
    static let shape = """
        import os, sys, time, threading, struct, argparse
        import numpy as np
        import mlx.core as mx

        def _watch_parent():
            # macOS has no PR_SET_PDEATHSIG: if our parent (the app) dies we get
            # reparented to launchd (pid 1). Exit hard so the GPU is released.
            while True:
                if os.getppid() == 1:
                    os._exit(1)
                time.sleep(1.0)
        threading.Thread(target=_watch_parent, daemon=True).start()

        from hy3dmlx.pipeline import Hunyuan3DShapePipeline
        from hy3dmlx.sampler import flow_match_sigmas, consistency_sigmas

        NUM_CHUNKS = 8000

        def write_mesh(mesh, path):
            # compact binary: int32 nVerts, int32 nFaces, then verts(f32 N*3),
            # normals(f32 N*3), faces(i32 M*3). Loads far faster than a text OBJ.
            verts = np.ascontiguousarray(mesh.vertices, dtype="<f4")
            normals = np.ascontiguousarray(mesh.vertex_normals, dtype="<f4")
            faces = np.ascontiguousarray(mesh.faces, dtype="<i4")
            with open(path, "wb") as fh:
                fh.write(struct.pack("<ii", verts.shape[0], faces.shape[0]))
                fh.write(verts.tobytes())
                fh.write(normals.tobytes())
                fh.write(faces.tobytes())

        def main():
            ap = argparse.ArgumentParser()
            ap.add_argument("image")
            ap.add_argument("--weights", required=True)
            ap.add_argument("--out", required=True)
            ap.add_argument("--steps", type=int, default=30)
            ap.add_argument("--guidance", type=float, default=5.0)
            ap.add_argument("--octree", type=int, default=256)
            ap.add_argument("--seed", type=int, default=0)
            ap.add_argument("--dtype", default="float16", choices=["float32", "float16"])
            ap.add_argument("--quantize", type=int, default=0, choices=[0, 4, 8])
            ap.add_argument("--preview-octree", type=int, default=48)
            a = ap.parse_args()

            dtype = {"float32": mx.float32, "float16": mx.float16}[a.dtype]
            pipe = Hunyuan3DShapePipeline.from_pretrained(a.weights, dtype=dtype,
                                                          quantize=(a.quantize or None))

            print("[dino] encoding", flush=True)
            cond = pipe.encode_image(a.image, 0.15)

            # Distilled (turbo) checkpoints: single forward with a guidance token +
            # consistency schedule (few steps). Standard: CFG + flow-match schedule.
            guidance_embed = bool(getattr(pipe.dit, "guidance_embed", False))
            sched = pipe.cfg.get("scheduler", {}).get("target", "")
            if "Consistency" in sched:
                pcm = pipe.cfg["scheduler"].get("params", {}).get("pcm_timesteps", 100)
                sig, sig_full = consistency_sigmas(a.steps, pcm_timesteps=pcm)
            else:
                sig, sig_full = flow_match_sigmas(a.steps)

            if guidance_embed:
                cond1 = cond[:1]
                gvec = mx.full((1,), a.guidance, dtype=dtype)
                def velocity_fn(x, t):
                    tt = mx.broadcast_to(t.reshape(1), (x.shape[0],))
                    gg = mx.broadcast_to(gvec, (x.shape[0],))
                    return pipe.dit(x, tt, cond1, guidance=gg)
            else:
                def velocity_fn(x, t):
                    tt = mx.broadcast_to(t.reshape(1), (x.shape[0],))
                    return pipe.dit(x, tt, cond)

            latents = mx.random.normal((1, *pipe.vae.latent_shape), dtype=mx.float32,
                                       key=mx.random.key(a.seed)).astype(dtype)
            out_dir = os.path.dirname(a.out)
            n = len(sig)

            # live preview meshes — a meshable surface emerges ~40% through denoising,
            # so the first lands in the first half and the rest refine it (cheap at octree 48).
            preview_at = sorted({max(1, int(round(n * f))) for f in (0.4, 0.55, 0.7, 0.85)})
            pidx = 0
            def preview(lat):
                kv = pipe.vae.decode(lat / pipe.vae.scale_factor)
                mx.eval(kv)
                grid, bn, bx, gs = pipe.vae.query_grid(kv, bounds=1.01,
                                                       octree_resolution=a.preview_octree, num_chunks=NUM_CHUNKS)
                return pipe._grid_to_mesh(grid, bn, bx, gs, 0.0)

            # ---- denoise loop (reimplements sampler.denoise; handles CFG + turbo) ----
            for i in range(n):
                dt = float(sig_full[i + 1] - sig[i])
                if dt == 0.0:
                    continue
                t = mx.array(float(sig[i]), dtype=dtype)
                if guidance_embed:
                    v = velocity_fn(latents, t)
                else:
                    v = velocity_fn(mx.concatenate([latents, latents], axis=0), t)
                    vc, vu = mx.split(v, 2, axis=0)
                    v = vu + a.guidance * (vc - vu)
                latents = latents + dt * v
                mx.eval(latents)
                print(f"\\r[denoise] {i + 1}/{n}", end="", flush=True)
                if (i + 1) in preview_at:
                    try:
                        m = preview(latents)
                        p = os.path.join(out_dir, f"preview_{pidx}.mesh")
                        write_mesh(m, p)
                        pidx += 1
                        print(f"\\n[preview] {p}", flush=True)
                    except Exception as e:
                        print(f"\\n[preview-skip] {e}", flush=True)

            # ---- final, full-resolution decode with per-chunk grid progress ----
            print("\\n[vae] decoding", flush=True)
            kv = pipe.vae.decode(latents / pipe.vae.scale_factor)
            mx.eval(kv)

            EXTRACT = 2      # sample 1 of every N chunks for the live point cloud
            WRITE = 6        # stream a points file every N chunks (granular buildup)
            THRESH = 0.1     # near-surface band (field ~[-1.1, 1.1], surface at 0)
            CAP = 400000     # max streamed points (high enough not to truncate detailed shapes)
            st = {"n": 0, "k": 0, "pts": [], "npts": 0}
            orig_decoder = pipe.vae.geo_decoder
            def counting_decoder(q, kvv):
                st["n"] += 1
                logits = orig_decoder(q, kvv)
                if st["n"] % EXTRACT == 0 and st["npts"] < CAP:
                    mx.eval(logits)
                    pts = np.asarray(q[0].astype(mx.float32))             # [P, 3] world coords
                    sdf = np.asarray(logits[0, :, 0].astype(mx.float32))  # [P]
                    near = pts[np.abs(sdf) < THRESH]
                    if near.shape[0] > 0:
                        st["pts"].append(near)
                        st["npts"] += int(near.shape[0])
                print(f"\\r[grid] {st['n']}", end="", flush=True)
                if st["n"] % WRITE == 0 and st["pts"]:
                    allp = np.concatenate(st["pts"], axis=0).astype("<f4")
                    pth = os.path.join(out_dir, f"points_{st['k']}.bin")
                    allp.tofile(pth)
                    st["k"] += 1
                    print(f"\\n[points] {pth}", flush=True)
                return logits
            pipe.vae.geo_decoder = counting_decoder
            try:
                # FlashVDM-style octree decode: refines only the near-surface band (fast).
                grid, bmin, bmax, gsize = pipe.vae.query_grid_octree(
                    kv, bounds=1.01, octree_resolution=a.octree, num_chunks=None, mc_level=0.0)
            finally:
                pipe.vae.geo_decoder = orig_decoder

            # final flush so the point cloud reaches its complete state before the mesh
            if st["pts"]:
                allp = np.concatenate(st["pts"], axis=0).astype("<f4")
                pth = os.path.join(out_dir, f"points_{st['k']}.bin")
                allp.tofile(pth)
                st["k"] += 1
                print(f"\\n[points] {pth}", flush=True)

            print("\\n[mesh] extracting", flush=True)
            mesh = pipe._grid_to_mesh(grid, bmin, bmax, gsize, 0.0)
            write_mesh(mesh, a.out)
            print(f"wrote {a.out}", flush=True)

        if __name__ == "__main__":
            main()
        """

    /// Paint (Hunyuan-3D-Paint-MLX): mesh + image -> textured .tmesh, streams views.
    static let paint = """
    import os, sys, json, time, struct, argparse, threading
    import numpy as np
    from PIL import Image

    ap = argparse.ArgumentParser()
    ap.add_argument("mesh")
    ap.add_argument("image")
    ap.add_argument("--out", required=True)
    ap.add_argument("--repo", required=True)
    ap.add_argument("--weights", required=True)
    ap.add_argument("--res", type=int, default=512)
    ap.add_argument("--steps", type=int, default=15)
    ap.add_argument("--tex", type=int, default=2048)
    ap.add_argument("--faces", type=int, default=40000)
    ap.add_argument("--superres", type=int, default=1)
    a = ap.parse_args()

    def _watch():
        while True:
            if os.getppid() == 1:
                os._exit(1)
            time.sleep(1.0)
    threading.Thread(target=_watch, daemon=True).start()

    os.chdir(a.repo)
    sys.path.insert(0, a.repo)
    outdir = os.path.dirname(a.out)

    import mlx.core as mx
    import trimesh, xatlas
    import fast_simplification as fs
    from hy3dpaint_mlx.vae import AutoencoderKL
    from hy3dpaint_mlx.unet2p5d import UNet2p5DConditionModel
    from hy3dpaint_mlx.scheduler import UniPCScheduler
    from hy3dpaint_mlx.mesh_render import MeshRender
    from hy3dpaint_mlx.convert import load_torch_weights

    R, STEPS, TEX, GUID, SF = a.res, a.steps, a.tex, 2.0, 0.18215
    AZIMS = [0, 90, 180, 270, 0, 180]
    ELEVS = [0, 0, 0, 0, 90, -90]
    t0 = time.time()

    def log(s): print(s, flush=True)

    def read_mesh(path):
        with open(path, "rb") as f:
            nv, nf = struct.unpack("<ii", f.read(8))
            V = np.frombuffer(f.read(nv * 12), "<f4").reshape(nv, 3).astype(np.float32)
            f.read(nv * 12)
            F = np.frombuffer(f.read(nf * 12), "<i4").reshape(nf, 3).astype(np.int32)
        return V, F

    def prep_img(pil, size):
        pil = pil.resize((size, size))
        if pil.mode == "RGBA":
            bg = Image.new("RGB", pil.size, (255, 255, 255)); bg.paste(pil, mask=pil.getchannel("A")); pil = bg
        return np.asarray(pil.convert("RGB"), np.float32) / 255.0

    def write_tmesh(path, V, N, UV, F):
        V = np.ascontiguousarray(V, "<f4"); N = np.ascontiguousarray(N, "<f4")
        UV = np.ascontiguousarray(UV, "<f4"); F = np.ascontiguousarray(F, "<i4")
        with open(path, "wb") as fh:
            fh.write(struct.pack("<ii", V.shape[0], F.shape[0]))
            fh.write(V.tobytes()); fh.write(N.tobytes()); fh.write(UV.tobytes()); fh.write(F.tobytes())

    def main():
        log("stage: loading models")
        vae = AutoencoderKL.from_config(json.load(open(f"{a.weights}/vae/config.json")))
        load_torch_weights(vae, mx.load(f"{a.weights}/vae/diffusion_pytorch_model.safetensors"),
                           renames=[(".to_out.0.", ".to_out.")])
        unet = UNet2p5DConditionModel(json.load(open(f"{a.weights}/unet/config.json")))
        load_torch_weights(unet, mx.load(f"{a.weights}/unet/diffusion_pytorch_model.safetensors"),
                           renames=[("transformer_blocks.0.transformer.", "transformer_blocks.0.")])
        log(f"models loaded ({time.time()-t0:.0f}s)")

        log("stage: preparing mesh")
        V0, F0 = read_mesh(a.mesh)
        if F0.shape[0] > a.faces:
            V0, F0 = fs.simplify(V0, F0, target_count=a.faces)
            log(f"decimated -> {len(V0)} verts {len(F0)} faces ({time.time()-t0:.0f}s)")
        vmapping, indices, uvs = xatlas.parametrize(V0, F0)
        V = np.asarray(V0)[vmapping]; F = indices.astype(np.int64)
        log(f"uv-unwrapped: {V.shape[0]} verts, {F.shape[0]} faces ({time.time()-t0:.0f}s)")

        rend = MeshRender()
        rend.load_mesh(V, F)
        rend.set_uv(uvs, F)
        ctrl = [rend.render_control(e, az, R) for e, az in zip(ELEVS, AZIMS)]
        normals = [c[0] for c in ctrl]; positions = [c[1] for c in ctrl]
        ref_img = prep_img(Image.open(a.image), R)

        def enc(imgs):
            x = mx.array(np.stack(imgs)) * 2 - 1
            return vae.encode_mean(x) * SF

        normal_lat = enc(normals); position_lat = enc(positions); ref_lat = enc([ref_img])
        log(f"stage: controls encoded ({time.time()-t0:.0f}s)")

        # immediate preview: the 6-view geometry (control normals), before diffusion
        ngrid = (np.concatenate(normals, axis=1) * 255).astype(np.uint8)
        npath = os.path.join(outdir, "paint_views_0.png")
        Image.fromarray(ngrid).save(npath)
        print(f"[views] {npath}", flush=True)

        N = len(AZIMS); h = R // 8
        cam_gen = mx.array(np.arange(N)[None, :].astype(np.int32))
        cam_ref = mx.array(np.array([[0]], np.int32))
        gen_text = unet.unet.learned_text_clip_gen
        neg_text = mx.zeros_like(gen_text)
        zero_ref = mx.zeros_like(ref_lat)[None]
        nlat = normal_lat[None]; plat = position_lat[None]; rlat = ref_lat[None]

        sched = UniPCScheduler(); sched.set_timesteps(STEPS)
        mx.random.seed(0)
        latents = mx.random.normal((1, N, h, h, 4)) * sched.init_noise_sigma()
        ced = unet.compute_condition_embed(rlat)

        def emit_views(latents, idx):
            dec = vae.decode(latents[0] / SF)
            imgs = np.clip((np.asarray(dec) + 1) / 2, 0, 1)
            grid = np.concatenate([imgs[k] for k in range(N)], axis=1)
            p = os.path.join(outdir, f"paint_views_{idx}.png")
            Image.fromarray((grid * 255).astype(np.uint8)).save(p)
            print(f"[views] {p}", flush=True)
            return imgs

        for i, t in enumerate(sched.timesteps):
            ti = int(t)
            v_c = unet(latents, ti, gen_text, nlat, plat, rlat, cam_gen, cam_ref, mva_scale=1.0, ref_scale=1.0, condition_embed_dict=ced)
            v_u = unet(latents, ti, neg_text, nlat, plat, zero_ref, cam_gen, cam_ref, mva_scale=1.0, ref_scale=0.0, condition_embed_dict=None)
            v = v_u + GUID * (v_c - v_u)
            latents = sched.step(v, ti, latents); mx.eval(latents)
            log(f"step {i+1}/{STEPS}")
            if (i == 0 or (i + 1) % 2 == 0) and i + 1 < STEPS:
                emit_views(latents, i + 1)

        imgs = emit_views(latents, STEPS)
        views = [imgs[k] for k in range(N)]
        log(f"stage: baking texture ({time.time()-t0:.0f}s)")
        if a.superres:
            from hy3dpaint_mlx.realesrgan import load_rrdbnet, upscale
            srm = load_rrdbnet()
            views = [np.asarray(upscale(srm, v, tile=256)) for v in views]
        view_weights = [1.0, 0.1, 0.5, 0.1, 0.05, 0.05]
        texture, covered = rend.bake(views, ELEVS, AZIMS, texture_size=TEX, weights=view_weights)
        texture = rend.inpaint(texture, covered)

        uv = rend.vtx_uv.copy()  # already v-flipped by set_uv; SceneKit texcoords are top-left
        m = trimesh.Trimesh(vertices=V, faces=F, process=False)
        write_tmesh(a.out, V, m.vertex_normals, uv, F)
        tex_path = os.path.splitext(a.out)[0] + "_texture.png"
        Image.fromarray((np.clip(texture, 0, 1) * 255).astype(np.uint8)).save(tex_path)
        log(f"DONE {time.time()-t0:.0f}s -> {a.out}")

    if __name__ == "__main__":
        main()
    """
}
