import SwiftUI

struct SplashScreenView: View {
    @ObservedObject var env: PythonEnvironment
    @State private var animate = false
    @State private var progress: Double = 0
    @State private var imageDisplaySize: CGSize = .zero

    var body: some View {
        ZStack {
            LinearGradient(gradient: Gradient(colors: [Color(NSColor.windowBackgroundColor), Color(red: 0.1, green: 0.25, blue: 0.5).opacity(0.4)]), startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Spacer()

                if let testImage = env.selfTestImage {
                    VStack(spacing: 12) {
                        // Header text
                        if env.selfTest3DModelURL != nil {
                            Text("3D Model Generated")
                                .font(.headline)
                                .foregroundColor(.secondary)
                        } else if env.selfTestAwaitingClick {
                            Text(env.selfTestPrompt)
                                .font(.headline)
                                .foregroundColor(env.selfTestAttempts > 0 ? .orange : .secondary)
                                .multilineTextAlignment(.center)
                        } else if env.selfTestMask != nil {
                            Text("Visual Self-Test")
                                .font(.headline)
                                .foregroundColor(.secondary)
                        }

                        if let modelURL = env.selfTest3DModelURL {
                            // Show 3D model viewer
                            ModelViewerContainer(modelURL: modelURL)
                                .frame(width: 500, height: 400)
                                .shadow(radius: 10)
                        } else {
                            // Interactive test image
                            GeometryReader { geo in
                                let imageSize = testImage.size
                                let aspectRatio = imageSize.width / imageSize.height
                                let displayHeight: CGFloat = 400
                                let displayWidth = displayHeight * aspectRatio
                                let offsetX = (geo.size.width - displayWidth) / 2
                                let offsetY = (geo.size.height - displayHeight) / 2

                                ZStack {
                                    // Base image
                                    Image(nsImage: testImage)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(height: displayHeight)

                                    // Mask overlay
                                    if let mask = env.selfTestMask {
                                        Image(nsImage: mask)
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .frame(height: displayHeight)
                                            .opacity(0.6)
                                            .allowsHitTesting(false)
                                    }

                                    // Click point indicator
                                    if let clickPoint = env.selfTestClickPoint {
                                        Circle()
                                            .fill(Color.red)
                                            .frame(width: 16, height: 16)
                                            .overlay(Circle().stroke(Color.white, lineWidth: 2))
                                            .shadow(radius: 3)
                                            .position(
                                                x: clickPoint.x * displayWidth,
                                                y: clickPoint.y * displayHeight
                                            )
                                    }
                                }
                                .frame(width: displayWidth, height: displayHeight)
                                .cornerRadius(12)
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gray.opacity(0.2), lineWidth: 1))
                                .shadow(radius: 10)
                                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                                .contentShape(Rectangle())
                                .onTapGesture { location in
                                    guard env.selfTestAwaitingClick else { return }

                                    // Calculate normalized coordinates
                                    let relativeX = (location.x - offsetX) / displayWidth
                                    let relativeY = (location.y - offsetY) / displayHeight

                                    // Bounds check
                                    guard relativeX >= 0, relativeX <= 1,
                                          relativeY >= 0, relativeY <= 1 else {
                                        return
                                    }

                                    let normalizedPoint = CGPoint(x: relativeX, y: relativeY)

                                    Task {
                                        await env.runSelfTestWithClick(normalizedPoint: normalizedPoint)
                                    }
                                }
                                .onHover { isHovering in
                                    if isHovering && env.selfTestAwaitingClick {
                                        NSCursor.pointingHand.push()
                                    } else {
                                        NSCursor.pop()
                                    }
                                }
                            }
                            .frame(height: 420)
                        }
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
                } else if !env.setupStarted {
                    // Show "Begin Setup" button before setup starts
                    Button(action: {
                        Task {
                            await env.setup()
                        }
                    }) {
                        Text("Begin Setup")
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

                    if env.canSkipSetup {
                        Button(action: {
                            env.skipSetup()
                        }) {
                            Text("Skip Setup")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                        .transition(.opacity)
                    }
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
