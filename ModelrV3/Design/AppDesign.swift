import SwiftUI

// MARK: - Modelr Design System
// Native macOS design with glass-like materials and refined typography

enum AppDesign {
    // MARK: - Spacing Constants (8pt Grid System)

    enum Spacing {
        static let p2: CGFloat = 2
        static let p4: CGFloat = 4
        static let p6: CGFloat = 6
        static let p8: CGFloat = 8
        static let p10: CGFloat = 10
        static let p12: CGFloat = 12
        static let p16: CGFloat = 16
        static let p24: CGFloat = 24
        static let p32: CGFloat = 32
        static let p48: CGFloat = 48
        static let p64: CGFloat = 64
        
        // Aliases for compatibility
        static let xs = p4
        static let sm = p8
        static let md = p12
        static let lg = p16
        static let xl = p24
        static let xxl = p32
    }

    // MARK: - Font Sizes

    enum FontSize {
        static let caption: CGFloat = 10
        static let subheadline: CGFloat = 11
        static let body: CGFloat = 13
        static let headline: CGFloat = 14
        static let title3: CGFloat = 16
        static let title2: CGFloat = 22
        static let title1: CGFloat = 28
        static let largeTitle: CGFloat = 34
        
        // Legacy aliases
        static let xs: CGFloat = 10
        static let sm: CGFloat = 11
        static let md: CGFloat = 13
        static let lg: CGFloat = 14
        static let xl: CGFloat = 16
        static let xxl: CGFloat = 22
    }

    // MARK: - Semantic Colors

    static let accent = Color.accentColor
    static let success = Color.green
    static let warning = Color.orange
    static let destructive = Color.red
    static let secondary = Color.secondary
    static let tertiary = Color.secondary.opacity(0.7)
    
    /// Standard mask overlay color
    static let maskColor = Color.accentColor
    
    /// Destructive/Eraser mask color
    static let eraserColor = Color.red

    // Neon colors for mask regions
    static let neonColors: [Color] = [
        Color(red: 0x39/255, green: 0xFF/255, blue: 0x14/255),
        Color(red: 0xFF/255, green: 0x10/255, blue: 0xF0/255),
        Color(red: 0xFF/255, green: 0xFF/255, blue: 0x00/255),
        Color(red: 0x00/255, green: 0xCA/255, blue: 0xFF/255),
        Color(red: 0xFF/255, green: 0x7E/255, blue: 0x00/255),
        Color(red: 0xB9/255, green: 0x15/255, blue: 0xCC/255),
        Color(red: 0xFF/255, green: 0x00/255, blue: 0x4D/255),
        Color(red: 0x00/255, green: 0xFF/255, blue: 0xFF/255),
        Color(red: 0xDF/255, green: 0xFF/255, blue: 0x00/255),
        Color(red: 0xFF/255, green: 0x00/255, blue: 0xFF/255),
    ]

    // MARK: - Typography

    struct HeaderText: View {
        let text: String
        var size: CGFloat = FontSize.title2

        var body: some View {
            Text(text)
                .font(.system(size: size, weight: .bold))
                .tracking(-0.5)
                .foregroundStyle(.primary)
        }
    }

    struct SubheaderText: View {
        let text: String

        var body: some View {
            Text(text.uppercased())
                .font(.system(size: 10, weight: .medium))
                .tracking(2.0)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Checkerboard Background
    
    struct Checkerboard: View {
        let size: CGFloat = 12
        let color1 = Color.primary.opacity(0.05)
        let color2 = Color.primary.opacity(0.1)

        var body: some View {
            Canvas { context, size in
                let rows = Int(size.height / self.size) + 1
                let cols = Int(size.width / self.size) + 1
                
                for row in 0..<rows {
                    for col in 0..<cols {
                        if (row + col) % 2 == 0 {
                            context.fill(Path(CGRect(x: CGFloat(col) * self.size, y: CGFloat(row) * self.size, width: self.size, height: self.size)), with: .color(color1))
                        } else {
                            context.fill(Path(CGRect(x: CGFloat(col) * self.size, y: CGFloat(row) * self.size, width: self.size, height: self.size)), with: .color(color2))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Primary Button (Tinted)

    struct GlassButton: View {
        let title: String
        let icon: String?
        let isDisabled: Bool
        let action: () -> Void

        init(_ title: String, icon: String? = nil, disabled: Bool = false, action: @escaping () -> Void) {
            self.title = title
            self.icon = icon
            self.isDisabled = disabled
            self.action = action
        }

        var body: some View {
            Button(action: action) {
                if let icon = icon {
                    Label(title, systemImage: icon)
                        .font(.system(size: FontSize.body, weight: .semibold))
                } else {
                    Text(title)
                        .font(.system(size: FontSize.body, weight: .semibold))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isDisabled)
            .shadow(color: isDisabled ? .clear : accent.opacity(0.15), radius: 8, y: 2)
        }
    }

    // MARK: - Secondary Button

    struct GlassButtonSecondary: View {
        let title: String
        let icon: String?
        let destructive: Bool
        let isDisabled: Bool
        let action: () -> Void

        init(_ title: String, icon: String? = nil, destructive: Bool = false, disabled: Bool = false, action: @escaping () -> Void) {
            self.title = title
            self.icon = icon
            self.destructive = destructive
            self.isDisabled = disabled
            self.action = action
        }

        var body: some View {
            Button(action: action) {
                if let icon = icon {
                    Label(title, systemImage: icon)
                        .font(.system(size: FontSize.body))
                } else {
                    Text(title)
                        .font(.system(size: FontSize.body))
                }
            }
            .buttonStyle(.bordered)
            .tint(destructive ? .red : nil)
            .disabled(isDisabled)
        }
    }

    // MARK: - Toggle Button

    struct GlassToggle: View {
        let title: String
        let icon: String
        let isSelected: Bool
        let tint: Color
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Label(title, systemImage: icon)
                    .font(.system(size: FontSize.body, weight: isSelected ? .semibold : .regular))
            }
            .buttonStyle(.bordered)
            .tint(isSelected ? tint : nil)
        }
    }

    // MARK: - Inline Button

    struct InlineButton: View {
        let title: String
        let icon: String?
        let action: () -> Void

        init(_ title: String, icon: String? = nil, action: @escaping () -> Void) {
            self.title = title
            self.icon = icon
            self.action = action
        }

        var body: some View {
            Button(action: action) {
                HStack(spacing: Spacing.p4) {
                    if let icon = icon {
                        Image(systemName: icon)
                            .font(.system(size: FontSize.caption))
                    }
                    Text(title)
                        .font(.system(size: FontSize.subheadline, weight: .medium))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Section Label

    struct SectionLabel: View {
        let text: String

        init(_ text: String) {
            self.text = text
        }

        var body: some View {
            Text(text.uppercased())
                .font(.system(size: FontSize.caption, weight: .bold))
                .foregroundStyle(.secondary)
                .tracking(1.0)
        }
    }

    // MARK: - Slider Row

    struct SliderRow: View {
        let label: String
        @Binding var value: CGFloat
        let range: ClosedRange<CGFloat>
        var step: CGFloat = 1
        var valueSuffix: String = ""

        var body: some View {
            VStack(alignment: .leading, spacing: Spacing.p4) {
                HStack {
                    Text(label)
                        .font(.system(size: FontSize.subheadline))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(value))\(valueSuffix)")
                        .font(.system(size: FontSize.subheadline, weight: .medium, design: .monospaced))
                }

                Slider(value: $value, in: range, step: step)
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Completed Row

    struct CompletedRow: View {
        let text: String

        init(_ text: String) {
            self.text = text
        }

        var body: some View {
            HStack(spacing: Spacing.p8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: FontSize.body))
                    .foregroundStyle(success)
                Text(text)
                    .font(.system(size: FontSize.body))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Warning Message

    struct WarningMessage: View {
        let text: String

        var body: some View {
            HStack(spacing: Spacing.p8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(warning)
                Text(text)
                    .font(.system(size: FontSize.subheadline))
                    .foregroundStyle(warning)
            }
            .padding(Spacing.p12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(warning.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(warning.opacity(0.3), lineWidth: 1)
            }
        }
    }

    // MARK: - Hint Text

    struct HintText: View {
        let text: String

        init(_ text: String) {
            self.text = text
        }

        var body: some View {
            Text(text)
                .font(.system(size: FontSize.caption))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Loading Indicator

    struct LoadingIndicator: View {
        let text: String

        var body: some View {
            HStack(spacing: Spacing.p12) {
                ProgressView()
                    .controlSize(.small)
                Text(text)
                    .font(.system(size: FontSize.subheadline))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(Spacing.p12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Step Indicator

    struct StepIndicator: View {
        let number: Int
        let title: String
        let isActive: Bool
        let isDone: Bool

        var body: some View {
            HStack(spacing: Spacing.p12) {
                ZStack {
                    Circle()
                        .fill(isDone ? success : (isActive ? accent : Color.secondary.opacity(0.2)))
                        .frame(width: 24, height: 24)

                    if isDone {
                        Image(systemName: "checkmark")
                            .font(.system(size: FontSize.caption, weight: .bold))
                            .foregroundStyle(.white)
                    } else {
                        Text("\(number)")
                            .font(.system(size: FontSize.caption, weight: .bold, design: .monospaced))
                            .foregroundStyle(isActive ? .white : .secondary)
                    }
                }

                Text(title)
                    .font(.system(size: FontSize.body, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? .primary : .secondary)
            }
        }
    }

    // MARK: - Styled Text Field

    struct StyledTextField: View {
        let placeholder: String
        @Binding var text: String
        var onSubmit: (() -> Void)? = nil

        var body: some View {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: FontSize.body))
                .padding(.horizontal, Spacing.p12)
                .padding(.vertical, Spacing.p8)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                }
                .onSubmit { onSubmit?() }
        }
    }
}

// MARK: - View Modifiers

extension View {
    func glassCard() -> some View {
        self
            .padding(AppDesign.Spacing.p16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
            }
    }

    func glassBackground() -> some View {
        self
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
            }
    }
}
