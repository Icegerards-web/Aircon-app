import SwiftUI

// MARK: - Colours (from the approved design)

enum Theme {
    static let ink = Color(hex: 0x0F1218)
    static let ink2 = Color(hex: 0x5A616D)
    static let ink3 = Color(hex: 0x8A919C)
    static let chip = Color(hex: 0xF0F1F4)
    static let homeBG = Color(hex: 0xF2F3F6)
    static let unitBG = Color(hex: 0xF7F9FB)
    static let airflowBG = Color(hex: 0xEEF1F5)
    static let line = Color(hex: 0xECEEF2)
    static let ok = Color(hex: 0x22A06B)
    static let okText = Color(hex: 0x1E7F4F)
    static let bad = Color(hex: 0xB5412F)
    static let warnBG = Color(hex: 0xFFF4D6)
    static let warnText = Color(hex: 0x7A5200)
    static let badBG = Color(hex: 0xFCE9E5)
    static let blue = Color(hex: 0x1A6FE0)

    struct Accent {
        let fill: Color
        let text: Color
        let soft: Color
    }

    static func accent(_ kind: String?) -> Accent {
        switch kind ?? "" {
        case "cool": return Accent(fill: Color(hex: 0x1A6FE0), text: Color(hex: 0x1A6FE0), soft: Color(hex: 0xE7F0FD))
        case "heat": return Accent(fill: Color(hex: 0xE2580F), text: Color(hex: 0xB8430C), soft: Color(hex: 0xFDEEE4))
        case "fan": return Accent(fill: Color(hex: 0x55657A), text: Color(hex: 0x4B5A6D), soft: Color(hex: 0xEDF0F4))
        case "dry": return Accent(fill: Color(hex: 0x0F8A78), text: Color(hex: 0x0B7666), soft: Color(hex: 0xE3F5F2))
        default: return Accent(fill: Color(hex: 0x1A6FE0), text: Color(hex: 0x4A515C), soft: Color(hex: 0xF0F1F4))
        }
    }
}

// MARK: - iOS-style switch

struct SwitchPill: View {
    let isOn: Bool
    let tint: Color
    var label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? tint : Color(hex: 0xC9CED6))
                Circle().fill(Color.white).frame(width: 27, height: 27)
                    .shadow(color: Color.black.opacity(0.18), radius: 2, y: 1)
                    .padding(2)
            }
            .frame(width: 51, height: 31)
            .animation(.easeOut(duration: 0.2), value: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

// MARK: - A row of options, like the Mode and Fan speed bars

struct SegItem: Identifiable {
    let id: Int
    let label: String
    let icon: AnyView
}

struct SegBar: View {
    let title: String
    let items: [SegItem]
    let selected: Int?
    let accent: Color
    var disabled = false
    let onPick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.ink2)
                .padding(.leading, 4)
            HStack(spacing: 4) {
                ForEach(items) { item in
                    let sel = item.id == selected
                    Button { onPick(item.id) } label: {
                        VStack(spacing: 3) {
                            item.icon.frame(height: 20)
                            Text(item.label).font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .foregroundColor(sel ? accent : Color(hex: 0x4A515C))
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(sel ? Color.white : Color.clear)
                                .shadow(color: Color.black.opacity(sel ? 0.08 : 0), radius: 3, y: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.label)
                    .accessibilityAddTraits(sel ? .isSelected : [])
                }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.chip))
            .disabled(disabled)
        }
    }
}

// MARK: - icons

func symbolIcon(_ name: String, rotation: Double = 0) -> AnyView {
    return AnyView(
        Image(systemName: name)
            .font(.system(size: 17, weight: .semibold))
            .rotationEffect(.degrees(rotation))
    )
}

func letterIcon(_ letter: String) -> AnyView {
    return AnyView(Text(letter).font(.system(size: 18, weight: .semibold, design: .rounded)))
}

/// Fan speed: 1 to 4 rising bars (Auto shows an "A").
struct FanBars: View {
    let level: Int
    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(1..<5) { i in
                RoundedRectangle(cornerRadius: 1.2)
                    .frame(width: 3, height: CGFloat(4 + i * 3))
                    .opacity(i <= level ? 1 : 0.25)
            }
        }
        .frame(height: 18, alignment: .bottom)
    }
}

func modeIcon(_ i: Int) -> AnyView {
    switch i {
    case 0: return letterIcon("A")
    case 1: return symbolIcon("snowflake")
    case 2: return symbolIcon("sun.max")
    case 3: return symbolIcon("fan")
    default: return symbolIcon("drop")
    }
}

func statusSymbol(_ kind: String?) -> String {
    switch kind ?? "" {
    case "cool": return "snowflake"
    case "heat": return "sun.max"
    case "fan": return "fan"
    case "dry": return "drop"
    default: return "power"
    }
}

// MARK: - small pieces

struct RoundButton: View {
    let symbol: String
    var size: CGFloat = 44
    var disabled = false
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundColor(Theme.ink)
                .frame(width: size, height: size)
                .background(Circle().fill(Theme.chip))
                .opacity(disabled ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(label)
    }
}

struct Spinner: View {
    let color: Color
    @State private var spin = false
    var body: some View {
        Circle()
            .trim(from: 0, to: 0.75)
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 11, height: 11)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
    }
}

/// The yellow / red note above the controls (mismatch, busy unit, couldn't change that...).
struct WarningBanner: View {
    let text: String
    var isError = false
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isError ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(isError ? Theme.bad : Color(hex: 0xC98A00))
            Text(text).font(.system(size: 13)).foregroundColor(isError ? Theme.bad : Theme.warnText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(isError ? Theme.badBG : Theme.warnBG))
    }
}

struct CircleNavButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(Theme.ink)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.white.opacity(0.85)).shadow(color: Color.black.opacity(0.06), radius: 6, y: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

func tempString(_ v: Double?) -> String {
    guard let v = v else { return "–" }
    return String(format: "%.1f°", v)
}
