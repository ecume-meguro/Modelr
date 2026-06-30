import Foundation
import MLX
import MLXRandom

/// On-device sampler schedule + noise, so no Python-dumped fixtures are needed.
public enum Sampler {
    /// FlowMatchEulerDiscrete sigmas: linspace(0,1,N) with a rational shift warp (shift=1 -> identity).
    /// Matches hy3dmlx.sampler.flow_match_sigmas exactly.
    public static func flowMatchSigmas(_ steps: Int, shift: Float = 1.0) -> MLXArray {
        let s = (0 ..< steps).map { i -> Float in
            let x = steps == 1 ? 0 : Float(i) / Float(steps - 1)
            return shift * x / (1 + (shift - 1) * x)
        }
        return MLXArray(s)
    }

    /// Standard-normal latent noise [1, numLatents, 64] for a given seed.
    public static func noise(numLatents: Int, channels: Int = 64, seed: UInt64) -> MLXArray {
        MLXRandom.normal([1, numLatents, channels], key: MLXRandom.key(seed)).asType(.float32)
    }
}
