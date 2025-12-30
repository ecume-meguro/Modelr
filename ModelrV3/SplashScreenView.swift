import SwiftUI

struct SplashScreenView: View {
    @ObservedObject var env: PythonEnvironment
    @State private var animate = false
    @State private var progress: Double = 0
    
    var body: some View {
        ZStack {
            LinearGradient(gradient: Gradient(colors: [Color(NSColor.windowBackgroundColor), Color(red: 0.1, green: 0.25, blue: 0.5).opacity(0.4)]), startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            
            VStack(spacing: 20) {
                Spacer()
                
                if let testImage = env.selfTestImage {
                    VStack {
                        Text("Visual Self-Test")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        
                        ZStack {
                            Image(nsImage: testImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(height: 400)
                                .cornerRadius(12)
                            
                            if let mask = env.selfTestMask {
                                Image(nsImage: mask)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(height: 400)
                                    .opacity(0.9)
                            }
                        }
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gray.opacity(0.2), lineWidth: 1))
                        .shadow(radius: 10)
                    }
                    .transition(.scale.combined(with: .opacity))
                } else {
                    // App Icon Placeholder
                    ZStack {
                        RoundedRectangle(cornerRadius: 24)
                            .fill(LinearGradient(gradient: Gradient(colors: [Color(red: 0.1, green: 0.3, blue: 0.7), .purple]), startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 80, height: 80)
                        
                        Image(systemName: "ai.generator.fill")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 40, height: 40)
                            .foregroundColor(.white)
                    }
                    .scaleEffect(animate ? 1.0 : 0.8)
                    .opacity(animate ? 1.0 : 0)
                }
                
                VStack(spacing: 8) {
                    Text("Modelr V3")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    
                    if !env.canProceed {
                        Picker("Model", selection: $env.selectedModel) {
                            Text("Tiny").tag("tiny")
                            Text("Small").tag("small")
                            Text("Base Plus").tag("base_plus")
                            Text("Large").tag("large")
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 300)
                        .padding(.vertical, 10)
                        .disabled(env.status != "Choose a model to begin" && env.status != "Setup failed" && env.status != "Error: uv not found")
                    } else {
                        Text("Model: \(env.selectedModel.replacingOccurrences(of: "_", with: " ").capitalized)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    Text(env.status)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .id(env.status)
                        .transition(.opacity)
                }
                
                if env.canProceed {
                    Button(action: {
                        withAnimation {
                            env.isSetup = true
                        }
                    }) {
                        Text("Open Editor")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 48)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(Color(red: 0.1, green: 0.3, blue: 0.7))
                                    .shadow(color: Color.blue.opacity(0.3), radius: 10, x: 0, y: 5)
                            )
                    }
                    .buttonStyle(.plain)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                } else if env.status == "Choose a model to begin" || env.status == "Setup failed" || env.status == "Error: uv not found" {
                    Button(action: {
                        Task {
                            await env.setup()
                        }
                    }) {
                        Text("Start Setup")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 48)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(Color(red: 0.1, green: 0.3, blue: 0.7))
                                    .shadow(color: Color.blue.opacity(0.3), radius: 10, x: 0, y: 5)
                            )
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                } else {
                    ProgressView(value: progress, total: 1.0)
                        .progressViewStyle(.linear)
                        .frame(width: 200)
                        .padding(.top, 10)
                }
                
                Spacer()
            }
            .padding()
        }
        .onAppear {
            withAnimation(.spring()) {
                animate = true
            }
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
                if progress < 0.95 {
                    progress += 0.002
                }
            }
        }
    }
}
