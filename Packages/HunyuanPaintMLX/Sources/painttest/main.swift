import Foundation
import CoreGraphics
import ImageIO
import simd
import HunyuanPaintMLX

func loadShapeMesh(_ path: String) -> LoadedMesh? {
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)), d.count >= 8 else { return nil }
    let n = Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset:0,as:Int32.self) })
    let m = Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset:4,as:Int32.self) })
    let vB=n*12, nB=n*12, fB=m*12
    guard d.count >= 8+vB+nB+fB else { return nil }
    var verts=[Float](repeating:0,count:n*3), faces=[UInt32](repeating:0,count:m*3)
    d.withUnsafeBytes { raw in
        for i in 0..<(n*3){verts[i]=raw.loadUnaligned(fromByteOffset:8+i*4,as:Float.self)}
        let fo=8+vB+nB; for i in 0..<(m*3){faces[i]=raw.loadUnaligned(fromByteOffset:fo+i*4,as:UInt32.self)}
    }
    print("shape mesh: \(n)v \(m)f"); fflush(stdout)
    return LoadedMesh(vertices: verts, faces: faces)
}
func writeTmesh(_ r: PaintResult, _ path: String) {
    let verts=r.vertices, faces=r.faces, uvs=r.uvs
    let n=verts.count/3, m=faces.count/3
    var normals=[Float](repeating:0,count:n*3)
    func v(_ i:Int)->SIMD3<Float>{SIMD3(verts[i*3],verts[i*3+1],verts[i*3+2])}
    for f in 0..<m { let a=Int(faces[f*3]),b=Int(faces[f*3+1]),c=Int(faces[f*3+2]); let fn=simd_cross(v(b)-v(a),v(c)-v(a)); for i in [a,b,c]{normals[i*3]+=fn.x;normals[i*3+1]+=fn.y;normals[i*3+2]+=fn.z} }
    for i in 0..<n { let vv=SIMD3<Float>(normals[i*3],normals[i*3+1],normals[i*3+2]); let l=simd_length(vv); let u=l>1e-12 ? vv/l:SIMD3<Float>(0,0,1); normals[i*3]=u.x;normals[i*3+1]=u.y;normals[i*3+2]=u.z }
    var d=Data()
    func aF(_ x:Float){var y=x.bitPattern.littleEndian;withUnsafeBytes(of:&y){d.append(contentsOf:$0)}}
    func aI(_ x:Int32){var y=x.littleEndian;withUnsafeBytes(of:&y){d.append(contentsOf:$0)}}
    func aU(_ x:UInt32){var y=x.littleEndian;withUnsafeBytes(of:&y){d.append(contentsOf:$0)}}
    aI(Int32(n));aI(Int32(m))
    for i in 0..<(n*3){aF(verts[i])}; for i in 0..<(n*3){aF(normals[i])}; for i in 0..<(n*2){aF(uvs[i])}; for i in 0..<(m*3){aU(faces[i])}
    try! d.write(to: URL(fileURLWithPath: path))
}

let base = "/Users/xzm/Library/Application Support/Modelr/projects/0A6666F4-7F1E-443C-A438-DA383CF173AB"
let meshPath = "\(base)/gen_57C09148-8E05-4028-81C0-4116C092B3DC.mesh"
let imgPath = "\(base)/input.png"
let wRoot = "/Users/xzm/Projects/Hunyuan-3D-Paint-MLX/weights"

guard let loaded = loadShapeMesh(meshPath) else { print("FAIL load mesh"); exit(1) }
let pipe = PaintPipeline(weightsRoot: wRoot, res: 384, steps: 6, tex: 1024, superRes: false)

print("--- cancel test (cancel after 2 paint steps) ---"); fflush(stdout)
var ps = 0
let cr = pipe.paintRGB(mesh: loaded, imagePath: imgPath, onProgress: { s,_ in if s.hasPrefix("Painting"){ps+=1} }, isCancelled: { ps >= 2 })
print("cancel -> \(cr==nil ? "nil (OK)" : "NON-NIL (FAIL)")"); fflush(stdout)

print("--- full paint (res=384 steps=6 tex=1024 no-SR) ---"); fflush(stdout)
var views = 0
let t0 = Date()
guard let r = pipe.paintRGB(mesh: loaded, imagePath: imgPath,
    onProgress: { s,f in print("  [\(Int((f ?? 0)*100))%] \(s)"); fflush(stdout) },
    isCancelled: { false },
    onViews: { d in views += 1 }) else { print("FAIL nil result"); exit(1) }
let nv = r.vertices.count/3
print("painted in \(Int(-t0.timeIntervalSinceNow))s: \(nv)v \(r.faces.count/3)f uvs=\(r.uvs.count/2) albedo=\(r.albedoPNG.count)B viewGrids=\(views)"); fflush(stdout)
print("VALIDATE uvs==verts: \(r.uvs.count == nv*2)   faces-in-range: \(Int(r.faces.max() ?? 0) < nv)")
if let src = CGImageSourceCreateWithData(r.albedoPNG as CFData, nil), let cg = CGImageSourceCreateImageAtIndex(src,0,nil) {
    print("  albedo PNG decodes: \(cg.width)x\(cg.height)")
} else { print("  albedo PNG FAILED decode") }
writeTmesh(r, "/tmp/modelr_paint_test.tmesh")
let td = try! Data(contentsOf: URL(fileURLWithPath: "/tmp/modelr_paint_test.tmesh"))
let tn=Int(td.withUnsafeBytes{$0.loadUnaligned(fromByteOffset:0,as:Int32.self)}); let tm=Int(td.withUnsafeBytes{$0.loadUnaligned(fromByteOffset:4,as:Int32.self)})
let exp = 8 + tn*12 + tn*12 + tn*8 + tm*12
print("  tmesh: \(tn)v \(tm)f file \(td.count)B expected \(exp) -> \(td.count==exp ? "OK":"MISMATCH")")
print("DONE")
