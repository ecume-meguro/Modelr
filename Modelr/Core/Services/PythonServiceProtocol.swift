import Foundation

protocol PythonServiceProtocol: ObservableObject {
    var isProcessing: Bool { get }
    var status: String { get set }

    func setup() async
    func setImage(path: String) async throws -> CGSize
    func setImageIfNeeded(path: String) async throws -> CGSize
    func predict(points: [SAMPoint], box: SAMBox?, imageSize: CGSize) async throws -> (masks: [URL], primaryMask: URL, scores: [Double], confidenceMap: URL?)
    func removeBackground() async throws -> URL
    func resetPredictor() async throws
    func generate3DModel(
        imagePath: String,
        maskPath: String,
        steps: Int,
        resolution: Int,
        modelVariant: String,
        guidanceScale: Double,
        boxV: Double,
        mcLevel: Double,
        progress: @escaping (String) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) async
}
