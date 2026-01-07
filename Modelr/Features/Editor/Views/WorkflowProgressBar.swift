import SwiftUI

struct WorkflowProgressBar: View {
    @Binding var currentStep: WorkflowStep
    let canMoveToNext: Bool
    
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(WorkflowStep.allCases, id: \.self) { step in
                StepView(
                    step: step,
                    isCurrent: currentStep == step,
                    isCompleted: currentStep > step,
                    isLocked: step > currentStep && !canMoveToNext && step.rawValue > currentStep.rawValue + 1,
                    isNextAvailable: step.rawValue == currentStep.rawValue + 1 && canMoveToNext
                )
                .onTapGesture {
                    if step <= currentStep || (step.rawValue == currentStep.rawValue + 1 && canMoveToNext) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                            currentStep = step
                        }
                    }
                }
                
                if step != .generate {
                    ConnectorView(isCompleted: currentStep > step, isActive: currentStep == step)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 5)
        )
    }
}

struct StepView: View {
    let step: WorkflowStep
    let isCurrent: Bool
    let isCompleted: Bool
    let isLocked: Bool
    let isNextAvailable: Bool
    
    @State private var isHovering = false
    
    private var circleColor: Color {
        if isCompleted {
            return .green
        } else if isCurrent {
            return .accentColor
        } else if isNextAvailable {
            return .accentColor.opacity(0.4)
        } else {
            return Color.gray.opacity(0.2)
        }
    }
    
    private var iconColor: Color {
        if isCompleted || isCurrent {
            return .white
        } else if isNextAvailable {
            return .accentColor
        } else {
            return .secondary
        }
    }
    
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                // Background circle
                Circle()
                    .fill(circleColor)
                    .frame(width: 40, height: 40)
                    .shadow(color: isCurrent ? .accentColor.opacity(0.4) : .clear, radius: 8, y: 4)
                
                // Pulse animation for current step
                if isCurrent {
                    Circle()
                        .stroke(Color.accentColor.opacity(0.3), lineWidth: 2)
                        .frame(width: 50, height: 50)
                        .scaleEffect(isHovering ? 1.1 : 1.0)
                        .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: isHovering)
                }
                
                // Icon
                if isCompleted {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                } else {
                    Image(systemName: step.icon)
                        .font(.system(size: 16, weight: isCurrent ? .semibold : .regular))
                        .foregroundColor(iconColor)
                }
            }
            .frame(width: 50, height: 50) // Fixed frame to contain pulse
            .scaleEffect(isHovering && !isLocked ? 1.05 : 1.0)
            .animation(.spring(response: 0.25), value: isHovering)
            
            Text(step.title)
                .font(.system(size: 12, weight: isCurrent ? .semibold : .medium))
                .foregroundColor(isCurrent ? .primary : .secondary)
                .fixedSize() // Prevent truncation
        }
        .frame(width: 80)
        .opacity(isLocked ? 0.5 : 1.0)
        .contentShape(Rectangle()) // Improve hit testing
        .onHover { hovering in
            isHovering = hovering
        }
        .onAppear {
            if isCurrent {
                isHovering = true
            }
        }
    }
}

struct ConnectorView: View {
    let isCompleted: Bool
    let isActive: Bool
    
    var body: some View {
        ZStack {
            // Background track
            Capsule()
                .fill(Color.gray.opacity(0.15))
                .frame(height: 4)
            
            // Progress fill
            GeometryReader { geo in
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.green, .accentColor],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: isCompleted ? geo.size.width : (isActive ? geo.size.width * 0.5 : 0), height: 4)
                    .animation(.spring(response: 0.4), value: isCompleted)
                    .animation(.spring(response: 0.4), value: isActive)
            }
            .frame(height: 4)
        }
        .frame(height: 50) // Match StepView top section height
        .frame(maxWidth: .infinity)
        .padding(.horizontal, -14) // Overlap slightly with circles
    }
}
