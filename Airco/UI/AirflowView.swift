import SwiftUI

/// Air direction: bar-style controls for up/down, left/right and the sideways pattern, plus the unit's own 3D auto.
struct AirflowView: View {
    @ObservedObject var unit: AirconUnit
    @State private var aimedPosition = 3          // remembered left/right position for the "Aimed" pattern

    private var auto: Bool { unit.shownEntrust }
    private var lr: Int { unit.shownLR }
    private var pattern: String {
        switch lr {
        case 0: return "swing"
        case 6: return "spread"
        case 7: return "focus"
        default: return "aim"
        }
    }

    var body: some View {
        let acc = Theme.accent(unit.airKind ?? "cool")
        ScrollView {
            VStack(spacing: 0) {
                SceneView(kind: unit.online ? (unit.airKind ?? "cool") : nil, vane: unit.shownVane, lr: unit.shownLR,
                          fan: unit.shownFan, auto3d: unit.shownEntrust, setpoint: String(format: "%.1f°", unit.temp))
                    .opacity(unit.online ? 1 : 0.45)

                VStack(spacing: 14) {
                    if let w = unit.warning {
                        WarningBanner(text: w, isError: unit.commandError != nil)
                    }

                    // Up and down: 0 swing, 1 wide ... 4 straight down
                    SegBar(title: "Up and down",
                           items: [
                            SegItem(id: 0, label: "Swing", icon: symbolIcon("arrow.up.and.down")),
                            SegItem(id: 1, label: "Wide", icon: symbolIcon("arrow.right", rotation: 10)),
                            SegItem(id: 2, label: "Mid", icon: symbolIcon("arrow.right", rotation: 36)),
                            SegItem(id: 3, label: "Steep", icon: symbolIcon("arrow.right", rotation: 62)),
                            SegItem(id: 4, label: "Down", icon: symbolIcon("arrow.right", rotation: 86))
                           ],
                           selected: unit.shownVane, accent: acc.text, disabled: auto || !unit.online) { v in
                        unit.ask(Change(vane: v))
                    }
                    .opacity(auto ? 0.4 : 1)

                    if unit.caps.windDirectionLR {
                        // Left and right: positions 1 (left) ... 5 (right)
                        SegBar(title: "Left and right",
                               items: [
                                SegItem(id: 1, label: "Left", icon: symbolIcon("arrow.down", rotation: 35)),
                                SegItem(id: 2, label: "L-mid", icon: symbolIcon("arrow.down", rotation: 17)),
                                SegItem(id: 3, label: "Center", icon: symbolIcon("arrow.down")),
                                SegItem(id: 4, label: "R-mid", icon: symbolIcon("arrow.down", rotation: -17)),
                                SegItem(id: 5, label: "Right", icon: symbolIcon("arrow.down", rotation: -35))
                               ],
                               selected: pattern == "aim" ? lr : nil, accent: acc.text, disabled: auto || !unit.online) { p in
                            aimedPosition = p
                            unit.ask(Change(lr: p))
                        }
                        .opacity(auto ? 0.4 : 1)

                        SegBar(title: "Sideways pattern",
                               items: [
                                SegItem(id: 0, label: "Aimed", icon: symbolIcon("scope")),
                                SegItem(id: 1, label: "Swing", icon: symbolIcon("arrow.left.and.right")),
                                SegItem(id: 2, label: "Spread", icon: symbolIcon("arrow.up.left.and.arrow.down.right")),
                                SegItem(id: 3, label: "Focus", icon: symbolIcon("arrow.down.right.and.arrow.up.left"))
                               ],
                               selected: ["aim": 0, "swing": 1, "spread": 2, "focus": 3][pattern] ?? 0,
                               accent: acc.text, disabled: auto || !unit.online) { k in
                            switch k {
                            case 1: unit.ask(Change(lr: 0))
                            case 2: unit.ask(Change(lr: 6))
                            case 3: unit.ask(Change(lr: 7))
                            default: unit.ask(Change(lr: aimedPosition))
                            }
                        }
                        .opacity(auto ? 0.4 : 1)
                    }

                    if unit.caps.entrust {
                        HStack(spacing: 12) {
                            Image(systemName: "cube.transparent").font(.system(size: 17, weight: .semibold))
                                .foregroundColor(Theme.blue)
                                .frame(width: 34, height: 34)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
                            VStack(alignment: .leading, spacing: 1) {
                                Text("3D auto airflow").font(.system(size: 15, weight: .semibold))
                                Text(auto ? "On: the aircon aims the air itself" : "Let the aircon aim the air itself")
                                    .font(.system(size: 12)).foregroundColor(Theme.ink2)
                            }
                            Spacer()
                            SwitchPill(isOn: auto, tint: Theme.blue, label: "3D auto airflow") {
                                unit.ask(Change(entrust: !auto))
                            }
                            .disabled(!unit.online)
                        }
                        .padding(.horizontal, 14).frame(minHeight: 56)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.chip))
                    }
                }
                .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 30)
                .background(
                    RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color.white)
                        .shadow(color: Color.black.opacity(0.07), radius: 15, y: -5)
                )
                .offset(y: -24)
                .padding(.bottom, -24)
            }
        }
        .background(Theme.airflowBG.ignoresSafeArea())
        .navigationTitle("Air direction")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if (1...5).contains(unit.shownLR) { aimedPosition = unit.shownLR } }
    }
}
