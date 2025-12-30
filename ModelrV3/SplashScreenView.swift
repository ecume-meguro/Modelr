import SwiftUI

struct SplashScreenView: View {
    @ObservedObject var env: PythonEnvironment
    @State private var animate = false
    @State private var progress: Double = 0
    
    var body: some View {
        ZStack {
            LinearGradient(gradient: Gradient(colors: [Color(NSColor.windowBackgroundColor), Color.blue.opacity(0.1)]), startPoint: .topLeading, endPoint: .bottomTrailing)
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
                                    .opacity(0.8)
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
                            .fill(LinearGradient(gradient: Gradient(colors: [.blue, .purple]), startPoint: .topLeading, endPoint: .bottomTrailing))
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
                        Text("Finish Setup")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 40)
                            .padding(.vertical, 12)
                            .background(Color.blue)
                            .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
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
