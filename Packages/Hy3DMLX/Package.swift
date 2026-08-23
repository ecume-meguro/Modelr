// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Hy3DMLX",
    platforms: [.macOS(.v26), .iOS(.v18)],
    products: [
        .library(name: "Hy3DMLX", targets: ["Hy3DMLX"]),
    ],
    dependencies: [
        .package(path: "../../vendor/mlx-swift"),
    ],
    targets: [
        .target(
            name: "Hy3DMLX",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
            ]
        ),
    ]
)
