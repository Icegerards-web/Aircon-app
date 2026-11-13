import SwiftUI

struct UnitView: View {
    @ObservedObject var unit: AirconUnit
    @State private var showDetails = false

    var body: some View {
        let acc = Theme.accent(unit.airKind)
        let range = unit.tempRange
        ScrollView {
            VStack(spacing: 0) {
                ZStack(alignment: .bottom) {
                    SceneView(kind: unit.online ? unit.airKind : nil, vane: unit.shownVane, lr: unit.shownLR,
                              fan: unit.shownFan, auto3d: unit.shownEntrust, setpoint: String(format: "%.1f°", unit.temp))
                        .opacity(unit.online ? 1 : 0.45)
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Room").font(.system(size: 12)).foregroundColor(Color(hex: 0x4A515C))
                            Text(tempString(unit.roomTemp)).font(.system(size: 20, weight: .semibold))
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("Outside").font(.system(size: 12)).foregroundColor(Color(hex: 0x4A515C))
                            Text(tempString(unit.outdoorTemp)).font(.system(size: 20, weight: .semibold))
                        }
                    }
                    .padding(.horizontal, 20).padding(.bottom, 34)
                    .allowsHitTesting(false)
                }

                VStack(spacing: 14) {
                    // status + power
                    HStack {
                        HStack(spacing: 8) {
                            if unit.isSending { Spinner(color: statusFG(acc)) }
                            else { Circle().fill(statusFG(acc)).frame(width: 8, height: 8) }
                            Text(unit.statusText).font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundColor(statusFG(acc))
                        .padding(.horizontal, 12).frame(height: 32)
                        .background(Capsule().fill(unit.shownPower && !unit.isSending && unit.online ? acc.soft : Theme.chip))
                        Spacer()
                        Button { unit.ask(Change(power: !unit.shownPower)) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "power").font(.system(size: 15, weight: .bold))
                                Text(unit.shownPower ? "On" : "Off").font(.system(size: 15, weight: .semibold))
                            }
                            .padding(.horizontal, 16).frame(height: 44)
                            .foregroundColor(unit.shownPower ? .white : Theme.ink)
                            .background(Capsule().fill(unit.shownPower ? acc.fill : Theme.chip))
                        }
                        .buttonStyle(.plain)
                        .disabled(!unit.online)
                        .accessibilityLabel("Power")
                    }

                    if !unit.online {
                        WarningBanner(text: "Can't reach this unit: " + (unit.error ?? "no answer"), isError: true)
                    } else if let w = unit.warning {
                        WarningBanner(text: w, isError: unit.commandError != nil)
                    }

                    // temperature
                    HStack {
                        RoundButton(symbol: "minus", size: 56, disabled: unit.shownTemp <= range.0 || !unit.online, label: "Colder") { step(-0.5) }
                        Spacer()
                        VStack(spacing: 4) {
                            HStack(alignment: .top, spacing: 2) {
                                Text(String(format: "%.1f", unit.shownTemp))
                                    .font(.system(size: 64, weight: .light)).monospacedDigit()
                                Text("°C").font(.system(size: 20, weight: .medium)).padding(.top, 8)
                            }
                            .foregroundColor(unit.shownPower ? Theme.ink : Color(hex: 0x9AA1AC))
                            Text("\(modeNames[unit.shownMode]) range \(Int(range.0)) to \(Int(range.1))°")
                                .font(.system(size: 13)).foregroundColor(Theme.ink2)
                        }
                        Spacer()
                        RoundButton(symbol: "plus", size: 56, disabled: unit.shownTemp >= range.1 || !unit.online, label: "Warmer") { step(0.5) }
                    }
                    .padding(.horizontal, 4)

                    SegBar(title: "Mode",
                           items: (0..<5).map { SegItem(id: $0, label: modeNames[$0], icon: modeIcon($0)) },
                           selected: unit.shownMode, accent: acc.text, disabled: !unit.online) { m in
                        let r = unit.caps.setpointRange(mode: m)
                        // keep the temperature inside the new mode's range
                        unit.ask(Change(mode: m, temp: min(r.1, max(r.0, unit.shownTemp))))
                    }

                    SegBar(title: "Fan speed",
                           items: (0..<5).map { SegItem(id: $0, label: fanNames[$0], icon: $0 == 0 ? letterIcon("A") : AnyView(FanBars(level: $0))) },
                           selected: unit.shownFan, accent: acc.text, disabled: !unit.online) { f in
                        unit.ask(Change(fan: f))
                    }

                    NavigationLink {
                        AirflowView(unit: unit)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "wind").font(.system(size: 17, weight: .semibold))
                                .foregroundColor(acc.text)
                                .frame(width: 34, height: 34)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
                            Text("Air direction").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.ink)
                            Spacer()
                            Text(airflowSummary).font(.system(size: 14)).foregroundColor(Theme.ink2)
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundColor(Theme.ink3)
                        }
                        .padding(.leading, 10).padding(.trailing, 14).frame(minHeight: 52)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.chip))
                    }
                    .buttonStyle(.plain)
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
        .background(Theme.unitBG.ignoresSafeArea())
        .navigationTitle(unit.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showDetails = true } label: { Image(systemName: "info.circle") }
                    .accessibilityLabel("Details")
            }
        }
        .sheet(isPresented: $showDetails) { DetailsView(unit: unit) }
        .refreshable { await unit.refresh() }
    }

    private func statusFG(_ acc: Theme.Accent) -> Color {
        if !unit.online { return Theme.bad }
        return unit.shownPower && !unit.isSending ? acc.text : Color(hex: 0x4A515C)
    }

    private func step(_ d: Double) {
        let r = unit.tempRange
        unit.ask(Change(temp: min(r.1, max(r.0, unit.shownTemp + d))), debounce: true)
    }

    private var airflowSummary: String {
        if unit.shownEntrust { return "3D auto" }
        let ud = vaneNames[safe: unit.shownVane] ?? "–"
        if unit.caps.windDirectionLR { return "\(ud) · \(lrNames[safe: unit.shownLR] ?? "–")" }
        return ud
    }
}
