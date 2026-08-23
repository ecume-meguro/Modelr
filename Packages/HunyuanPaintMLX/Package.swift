// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HunyuanPaintMLX",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HunyuanPaintMLX", targets: ["HunyuanPaintMLX"]),
        // Headless bake harness for sweeping bake parameters (Sources/mvbake).
        .executable(name: "mvbake", targets: ["mvbake"]),
    ],
    dependencies: [
        .package(path: "../../vendor/mlx-swift"),
    ],
    targets: [
        .target(
            name: "CXatlas",
            cxxSettings: [.unsafeFlags(["-std=c++14"])]
        ),
        .target(
            name: "HunyuanPaintMLX",
            dependencies: [
                "CXatlas",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
            ]
        ),
        .executableTarget(
            name: "mvbake",
            dependencies: ["HunyuanPaintMLX", .product(name: "MLX", package: "mlx-swift")]
        ),
    ]
)
