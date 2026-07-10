#!/usr/bin/env swift
// Regenerates the file-level constants in Sources/Core/ModelCatalog.swift from
// model_manifest.json (produced at HF upload time from the staged bundles).
//
// Usage:  swift scripts/gen_catalog.swift model_manifest.json
//
// Paste the printed array over `ModelCatalog.all`. Display names/details are
// preserved by hand; only repos, revisions, and file lists are data-driven.

import Foundation

struct ManifestFile: Decodable { let path: String; let bytes: Int64; let sha256: String }
struct ManifestRepo: Decodable { let revision: String?; let files: [ManifestFile] }
struct Manifest: Decodable { let repos: [String: ManifestRepo] }

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "model_manifest.json"
guard let data = FileManager.default.contents(atPath: path) else {
    FileHandle.standardError.write("cannot read \(path)\n".data(using: .utf8)!)
    exit(1)
}
let manifest = try JSONDecoder().decode(Manifest.self, from: data)

// repo suffix → (case name, display name, detail)
let slots: [(suffix: String, id: String, name: String, detail: String)] = [
    ("shape-small", ".shapeSmall", "Shape · Small", "Hunyuan3D 2mini · 0.6B · ~5 s per shape"),
    ("shape-large", ".shapeLarge", "Shape · Large", "Hunyuan3D 2.0 turbo · 1.1B distilled · ~17 s per shape"),
    ("paint-small", ".paintSmall", "Paint · Small", "Color texture (SD2.1) · 2048 atlas"),
    ("paint-large", ".paintLarge", "Paint · Large", "PBR texture (albedo + metallic-roughness) · 4096 atlas"),
]

func grouped(_ n: Int64) -> String {
    let f = NumberFormatter(); f.numberStyle = .decimal; f.groupingSeparator = "_"
    return f.string(from: NSNumber(value: n)) ?? "\(n)"
}

print("    static let all: [CatalogModel] = [")
for slot in slots {
    guard let (repo, entry) = manifest.repos.first(where: { $0.key.hasSuffix(slot.suffix) }) else {
        FileHandle.standardError.write("manifest missing repo for \(slot.suffix)\n".data(using: .utf8)!)
        exit(1)
    }
    let revision = entry.revision.map { "\"\($0)\"" } ?? "nil"
    print("        CatalogModel(")
    print("            id: \(slot.id),")
    print("            displayName: \"\(slot.name)\",")
    print("            detail: \"\(slot.detail)\",")
    print("            repo: \"\(repo)\",")
    print("            revision: \(revision),")
    print("            files: [")
    for f in entry.files.sorted(by: { $0.path < $1.path }) {
        print("                CatalogFile(path: \"\(f.path)\", bytes: \(grouped(f.bytes)),")
        print("                            sha256: \"\(f.sha256)\"),")
    }
    print("            ]),")
}
print("    ]")
