import XCTest
import simd
// MeshDecimator lives in Sources/Core, compiled into this test bundle — same module,
// no @testable import needed.

/// QEM decimation (DESIGN.md §4.5 paint prep): budget adherence, geometric fidelity,
/// watertightness, determinism, and robustness on degenerate input.
final class MeshDecimatorTests: XCTestCase {

    // MARK: - budget + geometric error (sample-based Hausdorff-ish)

    func testDecimatesDenseSphereBelowBudget() {
        let (pos, faces) = Self.icosphere(subdivisions: 4)   // 5120 faces, 2562 verts
        XCTAssertEqual(faces.count, 5120)
        let budget = 1200

        let out = MeshDecimator.decimate(positions: pos, faces: faces, faceBudget: budget)
        XCTAssertLessThanOrEqual(out.faces.count, budget, "must reach the face budget")
        XCTAssertGreaterThan(out.faces.count, budget / 2, "shouldn't over-collapse far past budget")
        XCTAssertGreaterThan(out.stats.collapses, 0)

        // Every output coordinate is finite (no NaN/inf leaked through).
        XCTAssertTrue(out.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })

        // Geometric fidelity #1: decimated vertices stay on the unit sphere.
        let radialError = out.positions.map { abs(simd_length($0) - 1) }.max() ?? 0
        XCTAssertLessThan(radialError, 0.08, "decimated verts drifted off the sphere: \(radialError)")

        // Geometric fidelity #2: one-sided Hausdorff — every original vertex is near
        // some surviving vertex (bounded by the coarsened edge length).
        let hausdorff = Self.maxNearestDistance(from: pos, to: out.positions)
        XCTAssertLessThan(hausdorff, 0.15, "Hausdorff-ish error too large: \(hausdorff)")
    }

    // MARK: - watertightness preserved on a closed mesh

    func testWatertightnessPreservedOnClosedSphere() {
        let (pos, faces) = Self.icosphere(subdivisions: 4)
        XCTAssertTrue(Self.isClosedManifold(faces), "precondition: input sphere is watertight")

        let out = MeshDecimator.decimate(positions: pos, faces: faces, faceBudget: 900)
        XCTAssertLessThanOrEqual(out.faces.count, 900)
        XCTAssertTrue(Self.isClosedManifold(out.faces),
                      "decimation opened a hole / created a non-manifold edge")
        // No index out of range, no degenerate (repeated-index) faces survived.
        for f in out.faces {
            XCTAssertTrue(f.x != f.y && f.y != f.z && f.x != f.z)
            XCTAssertLessThan(Int(max(f.x, f.y, f.z)), out.positions.count)
        }
    }

    func testWatertightnessPreservedOnClosedTorus() {
        let (pos, faces) = Self.torus(rings: 48, sides: 24)   // 2304 faces, closed genus-1
        XCTAssertTrue(Self.isClosedManifold(faces))

        let out = MeshDecimator.decimate(positions: pos, faces: faces, faceBudget: 700)
        XCTAssertLessThanOrEqual(out.faces.count, 700)
        XCTAssertTrue(Self.isClosedManifold(out.faces), "torus lost watertightness")
    }

    // MARK: - no-op under budget

    func testNoOpWhenAtOrUnderBudget() {
        let (pos, faces) = Self.icosphere(subdivisions: 2)    // 320 faces
        // Budget above the face count → unchanged.
        let over = MeshDecimator.decimate(positions: pos, faces: faces, faceBudget: 10_000)
        XCTAssertEqual(over.positions, pos)
        XCTAssertEqual(over.faces, faces)
        XCTAssertEqual(over.stats.collapses, 0)
        // Budget exactly equal → still unchanged (only decimate when strictly over).
        let equal = MeshDecimator.decimate(positions: pos, faces: faces, faceBudget: faces.count)
        XCTAssertEqual(equal.faces, faces)
        XCTAssertEqual(equal.stats.collapses, 0)
    }

    // MARK: - determinism (same input → identical output)

    func testDeterministicAcrossRuns() {
        let (pos, faces) = Self.icosphere(subdivisions: 4)
        let a = MeshDecimator.decimate(positions: pos, faces: faces, faceBudget: 1500)
        let b = MeshDecimator.decimate(positions: pos, faces: faces, faceBudget: 1500)
        XCTAssertEqual(a.positions, b.positions, "positions diverged between identical runs")
        XCTAssertEqual(a.faces, b.faces, "faces diverged between identical runs")
        // Same guarantee through the serialize path (byte-identical output file).
        let sa = MeshDecimator.serialize(positions: a.positions, faces: a.faces)
        let sb = MeshDecimator.serialize(positions: b.positions, faces: b.faces)
        XCTAssertEqual(sa, sb)
    }

    func testDeterministicOnOpenMesh() {
        // Open (boundary) mesh: a disc-like fan. Boundary penalty accumulation must be
        // order-stable, so repeated runs still match bit-for-bit.
        var pos: [SIMD3<Float>] = [SIMD3(0, 0, 0)]
        let rim = 60
        for i in 0..<rim {
            let a = Float(i) / Float(rim) * 2 * .pi
            pos.append(SIMD3(cos(a), sin(a), 0))
        }
        var faces: [SIMD3<UInt32>] = []
        for i in 0..<rim { faces.append(SIMD3(0, UInt32(1 + i), UInt32(1 + (i + 1) % rim))) }
        // subdivide once to give the decimator something to chew on
        (pos, faces) = Self.subdivide(pos, faces)
        let a = MeshDecimator.decimate(positions: pos, faces: faces, faceBudget: faces.count / 2)
        let b = MeshDecimator.decimate(positions: pos, faces: faces, faceBudget: faces.count / 2)
        XCTAssertEqual(a.positions, b.positions)
        XCTAssertEqual(a.faces, b.faces)
    }

    // MARK: - degenerate input (needle triangles) doesn't crash or emit NaN

    func testDegenerateNeedleInputIsSafe() {
        // A run of nearly-collinear vertices → zero-area needle triangles.
        var pos: [SIMD3<Float>] = []
        for i in 0..<40 { pos.append(SIMD3(Float(i), Float(i % 2) * 1e-7, 0)) }
        var faces: [SIMD3<UInt32>] = []
        for i in 0..<(pos.count - 2) { faces.append(SIMD3(UInt32(i), UInt32(i + 1), UInt32(i + 2))) }

        let out = MeshDecimator.decimate(positions: pos, faces: faces, faceBudget: 8)
        // The contract is "doesn't crash, no NaN" — geometry may collapse to little.
        XCTAssertTrue(out.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
        for f in out.faces { XCTAssertLessThan(Int(max(f.x, f.y, f.z)), out.positions.count) }
    }

    func testValidMeshWithDegenerateFacesMixedIn() {
        var (pos, faces) = Self.icosphere(subdivisions: 3)   // 1280 faces
        // Append a degenerate (zero-area, repeated-index) face and a needle triangle.
        let base = UInt32(pos.count)
        pos.append(SIMD3(5, 0, 0)); pos.append(SIMD3(5, 1e-8, 0)); pos.append(SIMD3(5, 2e-8, 0))
        faces.append(SIMD3(base, base, base + 1))            // repeated index
        faces.append(SIMD3(base, base + 1, base + 2))        // needle
        let out = MeshDecimator.decimate(positions: pos, faces: faces, faceBudget: 400)
        XCTAssertTrue(out.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
        XCTAssertLessThanOrEqual(out.faces.count, 400)
    }

    // MARK: - file entry point (.mesh round trip + outcomes)

    func testFileDecimationRoundTrip() throws {
        let (pos, faces) = Self.icosphere(subdivisions: 4)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdz-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("in.mesh")
        let dst = dir.appendingPathComponent("out.mesh")
        try MeshDecimator.serialize(positions: pos, faces: faces).write(to: src)

        // Over budget → decimated file written and re-parseable.
        let outcome = MeshDecimator.decimateMeshFile(at: src, faceBudget: 1000, to: dst)
        guard case .decimated(let stats) = outcome else {
            return XCTFail("expected .decimated, got \(outcome)")
        }
        XCTAssertEqual(stats.inputFaces, 5120)
        XCTAssertLessThanOrEqual(stats.outputFaces, 1000)
        let reparsed = try XCTUnwrap(MeshDecimator.parse(Data(contentsOf: dst)))
        XCTAssertEqual(reparsed.faces.count, stats.outputFaces)
        XCTAssertEqual(reparsed.positions.count, stats.outputVerts)

        // Under budget → .unchanged (caller keeps the original, no rewrite required).
        let noop = MeshDecimator.decimateMeshFile(at: src, faceBudget: 999_999, to: dst)
        guard case .unchanged = noop else { return XCTFail("expected .unchanged, got \(noop)") }
    }

    func testFileDecimationUnreadable() throws {
        let dir = FileManager.default.temporaryDirectory
        let src = dir.appendingPathComponent("garbage-\(UUID().uuidString).mesh")
        try Data([1, 2, 3, 4]).write(to: src)                // too short to be a mesh
        defer { try? FileManager.default.removeItem(at: src) }
        let outcome = MeshDecimator.decimateMeshFile(at: src, faceBudget: 100,
                                                     to: dir.appendingPathComponent("x.mesh"))
        guard case .unreadable = outcome else { return XCTFail("expected .unreadable, got \(outcome)") }
    }

    // MARK: - synthetic mesh generators + metrics

    /// Recursively-subdivided icosahedron projected to the unit sphere: a dense,
    /// watertight, manifold test mesh. `subdivisions` n → 20·4ⁿ faces.
    static func icosphere(subdivisions: Int) -> ([SIMD3<Float>], [SIMD3<UInt32>]) {
        let t = Float((1.0 + 5.0.squareRoot()) / 2.0)
        var verts: [SIMD3<Float>] = [
            SIMD3(-1, t, 0), SIMD3(1, t, 0), SIMD3(-1, -t, 0), SIMD3(1, -t, 0),
            SIMD3(0, -1, t), SIMD3(0, 1, t), SIMD3(0, -1, -t), SIMD3(0, 1, -t),
            SIMD3(t, 0, -1), SIMD3(t, 0, 1), SIMD3(-t, 0, -1), SIMD3(-t, 0, 1),
        ].map { simd_normalize($0) }
        var faces: [(Int, Int, Int)] = [
            (0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11),
            (1, 5, 9), (5, 11, 4), (11, 10, 2), (10, 7, 6), (7, 1, 8),
            (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9),
            (4, 9, 5), (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1),
        ]
        var mid: [UInt64: Int] = [:]
        func midpoint(_ a: Int, _ b: Int) -> Int {
            let key = (UInt64(min(a, b)) << 32) | UInt64(max(a, b))
            if let m = mid[key] { return m }
            verts.append(simd_normalize((verts[a] + verts[b]) * 0.5))
            mid[key] = verts.count - 1
            return verts.count - 1
        }
        for _ in 0..<subdivisions {
            var next: [(Int, Int, Int)] = []
            next.reserveCapacity(faces.count * 4)
            for (a, b, c) in faces {
                let ab = midpoint(a, b), bc = midpoint(b, c), ca = midpoint(c, a)
                next.append((a, ab, ca)); next.append((b, bc, ab))
                next.append((c, ca, bc)); next.append((ab, bc, ca))
            }
            faces = next
        }
        return (verts, faces.map { SIMD3(UInt32($0.0), UInt32($0.1), UInt32($0.2)) })
    }

    /// Closed torus grid (wraps both ways) — watertight genus-1 test mesh.
    static func torus(rings: Int, sides: Int, R: Float = 1.0, r: Float = 0.35)
    -> ([SIMD3<Float>], [SIMD3<UInt32>]) {
        var verts: [SIMD3<Float>] = []
        for i in 0..<rings {
            let u = Float(i) / Float(rings) * 2 * .pi
            for j in 0..<sides {
                let v = Float(j) / Float(sides) * 2 * .pi
                verts.append(SIMD3((R + r * cos(v)) * cos(u), (R + r * cos(v)) * sin(u), r * sin(v)))
            }
        }
        func idx(_ i: Int, _ j: Int) -> UInt32 { UInt32((i % rings) * sides + (j % sides)) }
        var faces: [SIMD3<UInt32>] = []
        for i in 0..<rings {
            for j in 0..<sides {
                let a = idx(i, j), b = idx(i + 1, j), c = idx(i + 1, j + 1), d = idx(i, j + 1)
                faces.append(SIMD3(a, b, c)); faces.append(SIMD3(a, c, d))
            }
        }
        return (verts, faces)
    }

    /// One 1→4 triangle subdivision (no sphere projection) — used to thicken an open mesh.
    static func subdivide(_ pos: [SIMD3<Float>], _ faces: [SIMD3<UInt32>])
    -> ([SIMD3<Float>], [SIMD3<UInt32>]) {
        var verts = pos
        var mid: [UInt64: Int] = [:]
        func midpoint(_ a: UInt32, _ b: UInt32) -> UInt32 {
            let key = (UInt64(min(a, b)) << 32) | UInt64(max(a, b))
            if let m = mid[key] { return UInt32(m) }
            verts.append((verts[Int(a)] + verts[Int(b)]) * 0.5)
            mid[key] = verts.count - 1
            return UInt32(verts.count - 1)
        }
        var out: [SIMD3<UInt32>] = []
        for f in faces {
            let ab = midpoint(f.x, f.y), bc = midpoint(f.y, f.z), ca = midpoint(f.z, f.x)
            out.append(SIMD3(f.x, ab, ca)); out.append(SIMD3(f.y, bc, ab))
            out.append(SIMD3(f.z, ca, bc)); out.append(SIMD3(ab, bc, ca))
        }
        return (verts, out)
    }

    /// Every edge shared by exactly two faces ⇒ closed, 2-manifold (watertight).
    static func isClosedManifold(_ faces: [SIMD3<UInt32>]) -> Bool {
        var count: [UInt64: Int] = [:]
        func key(_ a: UInt32, _ b: UInt32) -> UInt64 { (UInt64(min(a, b)) << 32) | UInt64(max(a, b)) }
        for f in faces {
            count[key(f.x, f.y), default: 0] += 1
            count[key(f.y, f.z), default: 0] += 1
            count[key(f.z, f.x), default: 0] += 1
        }
        return !count.isEmpty && count.values.allSatisfy { $0 == 2 }
    }

    /// One-sided max-nearest-vertex distance (a sampled Hausdorff proxy).
    static func maxNearestDistance(from a: [SIMD3<Float>], to b: [SIMD3<Float>]) -> Float {
        var worst: Float = 0
        for p in a {
            var best = Float.greatestFiniteMagnitude
            for q in b { best = min(best, simd_distance(p, q)) }
            worst = max(worst, best)
        }
        return worst
    }
}
