import SwiftUI

struct GeneratePanel: View {
    @ObservedObject var viewModel: EditorViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Prerequisites check
            if viewModel.maskImage == nil {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32))
                        .foregroundColor(.orange)
                    Text("Segment First")
                        .font(.headline)
                    Text("Use the Segment tab to select an object before generating a 3D model.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                // Model info
                VStack(alignment: .leading, spacing: 8) {
                    Text("Hunyuan3D-2")
                        .font(.headline)
                    
                    Text(GeneratorModel.hunyuan.description)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Divider()
                
                // Quality Presets
                VStack(alignment: .leading, spacing: 8) {
                    Text("Quality Preset")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    Picker("Quality", selection: $viewModel.selectedQualityPreset) {
                        ForEach(QualityPreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: viewModel.selectedQualityPreset) { _, newValue in
                        viewModel.generateSteps = Double(newValue.steps)
                        viewModel.generateResolution = Double(newValue.resolution)
                    }
                    
                    Text(viewModel.selectedQualityPreset.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .italic()
                        .padding(.top, 4)
                }
                
                Divider()
                
                // Advanced Settings
                VStack(alignment: .leading, spacing: 12) {
                    Text("Advanced Settings")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    // Steps
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Diffusion Steps")
                                .font(.subheadline)
                            Spacer()
                            Text("\(Int(viewModel.generateSteps))")
                                .font(.subheadline.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $viewModel.generateSteps, in: 20...100, step: 1)
                    }
                    
                    // Resolution
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Resolution")
                                .font(.subheadline)
                            Spacer()
                            Text("\(Int(viewModel.generateResolution))")
                                .font(.subheadline.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $viewModel.generateResolution, in: 128...512, step: 64)
                    }
                    
                    Text("Est. time: \(viewModel.estimatedGenerationTime)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Divider()
                
                Spacer()
                
                // Generate Button
                VStack(spacing: 12) {
                    if !viewModel.isGenerating {
                        Button(action: { viewModel.startGeneration() }) {
                            HStack {
                                Image(systemName: "cube.fill")
                                Text("Generate 3D Model")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(.purple)
                    }
                    
                    if let error = viewModel.generationError {
                        VStack(spacing: 8) {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                Text("Generation Failed")
                                    .font(.subheadline.bold())
                            }
                            .foregroundColor(.red)
                            
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding()
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(8)
                    }
                    
                    Button(action: { viewModel.clearAll() }) {
                        Label("Start Over", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(.red)
                }
            }
        }
        .padding()
    }
}
