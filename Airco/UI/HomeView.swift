import SwiftUI

struct HomeView: View {
    @EnvironmentObject var store: Store
    @State private var showSettings = false
    @State private var autoSearchTried = false
    @State private var showDiscovery = false
    @State private var path: [UUID] = []

    private var summary: String {
        let running = store.units.filter { $0.shownPower }.count
        let total = store.units.count
        if total == 0 { return "No aircons yet" }
        if running == 0 { return "Everything is off" }
        if running == total && total > 1 { return total == 2 ? "Both aircons running" : "All aircons running" }
        return "\(running) of \(total) aircon\(total > 1 ? "s" : "") running"
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(summary).font(.system(size: 15)).foregroundColor(Theme.ink2)
                    }
                    if store.units.isEmpty {
                        EmptyHome(showDiscovery: $showDiscovery, showSettings: $showSettings)
                    } else {
                        ForEach(store.units) { unit in
                            HomeCard(unit: unit) { path.append(unit.id) }
                        }
                        Text("Tip: drag an aircon to turn it around")
                            .font(.system(size: 13)).foregroundColor(Theme.ink2)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
            .background(Theme.homeBG.ignoresSafeArea())
            .navigationTitle("Airco")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape").foregroundColor(Theme.ink)
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let unit = store.units.first(where: { $0.id == id }) {
                    UnitView(unit: unit)
                }
            }
            .refreshable { await store.refreshAll() }
        }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(store) }
        .sheet(isPresented: $showDiscovery) { DiscoveryView().environmentObject(store) }
        .task {
            // First start: look for the aircons by ourselves.
            if store.units.isEmpty && !store.demo && !autoSearchTried {
                autoSearchTried = true
                showDiscovery = true
            }
        }
    }
}

private struct EmptyHome: View {
    @EnvironmentObject var store: Store
    @Binding var showDiscovery: Bool
    @Binding var showSettings: Bool
    var body: some View {
        VStack(spacing: 12) {
            Text("No aircons yet").font(.system(size: 20, weight: .semibold))
            Text("Search your network, add them by hand, or look around with demo units first.")
                .font(.system(size: 14)).foregroundColor(Theme.ink2).multilineTextAlignment(.center)
            Button("Search my network") { showDiscovery = true }
                .buttonStyle(PrimaryButtonStyle())
            Button("Add by hand") { showSettings = true }
                .buttonStyle(SecondaryButtonStyle())
            Button("Try demo units") { store.setDemo(true) }
                .buttonStyle(SecondaryButtonStyle())
        }
        .padding(22)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color.white))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.blue))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(Theme.blue)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.chip))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

// MARK: - one aircon on the home screen

private struct HomeCard: View {
    @ObservedObject var unit: AirconUnit
    let open: () -> Void

    var body: some View {
        let acc = Theme.accent(unit.airKind)
        let shadowColor = unit.shownPower ? acc.fill.opacity(0.16) : Color.black.opacity(0.06)
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                SceneView(kind: unit.online ? unit.airKind : nil, vane: unit.shownVane, lr: 3, fan: unit.shownFan,
                          setpoint: String(format: "%.1f°", unit.temp))
                    .frame(height: 300 * (UIScreen.main.bounds.width - 40) / 390)
                    .frame(height: 196, alignment: .top)
                    .clipped()
                    .opacity(unit.online ? 1 : 0.45)
                LinearGradient(colors: [Color.white.opacity(0), Color.white], startPoint: .top, endPoint: .bottom)
                    .frame(height: 56)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .allowsHitTesting(false)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Room").font(.system(size: 12)).foregroundColor(Color(hex: 0x4A515C))
                    Text(tempString(unit.roomTemp)).font(.system(size: 15, weight: .semibold))
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.85)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(14)
                .allowsHitTesting(false)
                SwitchPill(isOn: unit.shownPower, tint: acc.fill, label: "\(unit.name) power") {
                    unit.ask(Change(power: !unit.shownPower))
                }
                .disabled(!unit.online)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(14)
            }
            .frame(height: 196)

            HStack(spacing: 8) {
                Button(action: open) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Text(unit.name).font(.system(size: 19, weight: .semibold)).foregroundColor(Theme.ink)
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundColor(Theme.ink3)
                        }
                        HStack(spacing: 6) {
                            if unit.isSending { Spinner(color: Color(hex: 0x4A515C)) }
                            else { Image(systemName: unit.online ? statusSymbol(unit.airKind) : "wifi.slash").font(.system(size: 12, weight: .semibold)) }
                            Text(unit.statusText).font(.system(size: 14, weight: .medium))
                        }
                        .foregroundColor(!unit.online ? Theme.bad : (unit.shownPower ? acc.text : Theme.ink2))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                RoundButton(symbol: "minus", disabled: !unit.shownPower || !unit.online, label: "\(unit.name) colder") { step(-0.5) }
                Text(String(format: "%.1f°", unit.shownTemp))
                    .font(.system(size: 28, weight: .regular)).monospacedDigit()
                    .foregroundColor(unit.shownPower ? Theme.ink : Color(hex: 0x9AA1AC))
                    .frame(width: 72)
                RoundButton(symbol: "plus", disabled: !unit.shownPower || !unit.online, label: "\(unit.name) warmer") { step(0.5) }
            }
            .padding(.leading, 18).padding(.trailing, 14).padding(.bottom, 16).padding(.top, 2)

            if let w = unit.warning {
                WarningBanner(text: w, isError: unit.commandError != nil)
                    .padding(.horizontal, 14).padding(.bottom, 14)
            }
            if !unit.online, let e = unit.error {
                WarningBanner(text: "Can't reach this unit: " + e, isError: true)
                    .padding(.horizontal, 14).padding(.bottom, 14)
            }
        }
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color.white))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: shadowColor, radius: 17, y: 8)
    }

    private func step(_ d: Double) {
        let r = unit.tempRange
        unit.ask(Change(temp: min(r.1, max(r.0, unit.shownTemp + d))), debounce: true)
    }
}
