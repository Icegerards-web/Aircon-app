import SwiftUI

/// The live 3D aircon. It is a little real 3D model: every corner is a point in space. About 30 times a second
/// each point is turned to your viewing angle and flattened onto the screen (like a camera lens would),
/// then the faces, the louver and the air are drawn. The air is calculated in the same 3D space, so it turns
/// along with the unit when you drag. Cold air sinks, warm air floats.
/// (Direct port of the approved web design's Scene3D.)

/// Holds the camera angle between frames. A class on purpose: changing it must not trigger a SwiftUI refresh,
/// the animation clock already redraws us 30 times a second.
final class SceneCamera {
    var yaw = -32.0, pitch = -6.0
    var targetYaw = -32.0, targetPitch = -6.0
    var active = false
    var dragStartYaw = 0.0, dragStartPitch = 0.0
    var dragging = false
    var releaseToken = 0
    let t0 = Date.timeIntervalSinceReferenceDate
}

struct SceneView: View {
    var kind: String?            // "cool", "heat", "fan", "dry" or nil when the unit is off
    var vane: Int
    var lr: Int
    var fan: Int
    var auto3d: Bool = false
    var setpoint: String

    @State private var cam = SceneCamera()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let k = geo.size.width / 390.0
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
                Canvas { ctx, size in
                    let t = reduceMotion ? 1.6 : timeline.date.timeIntervalSinceReferenceDate - cam.t0
                    var c = ctx
                    c.scaleBy(x: k, y: k)
                    SceneRenderer(cam: cam, kind: kind, vane: vane, lr: lr, fan: fan, auto3d: auto3d,
                                  setpoint: setpoint, t: t, reduceMotion: reduceMotion).draw(&c)
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { v in
                        if !cam.dragging {
                            cam.dragging = true
                            cam.dragStartYaw = cam.yaw
                            cam.dragStartPitch = cam.pitch
                        }
                        cam.active = true
                        cam.releaseToken += 1
                        let kk = 1.0 / max(k, 0.01)
                        cam.targetYaw = min(-4, max(-60, cam.dragStartYaw + Double(v.translation.width) * kk * 0.3))
                        cam.targetPitch = min(8, max(-11, cam.dragStartPitch - Double(v.translation.height) * kk * 0.12))
                    }
                    .onEnded { _ in
                        cam.dragging = false
                        cam.releaseToken += 1
                        let token = cam.releaseToken
                        let camera = cam
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            if camera.releaseToken == token && !camera.dragging { camera.active = false }
                        }
                    }
            )
        }
        .aspectRatio(390.0 / 300.0, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

// MARK: - drawing

private struct AirColor {
    let core: Color
    let bright: Color
    let rgb: (Double, Double, Double)
}

private func airColor(_ kind: String?) -> AirColor {
    switch kind ?? "off" {
    case "cool": return AirColor(core: Color(hex: 0x4EA8FF), bright: Color(hex: 0xDDF0FF), rgb: (78, 168, 255))
    case "heat": return AirColor(core: Color(hex: 0xFF8A3D), bright: Color(hex: 0xFFE3C7), rgb: (255, 138, 61))
    case "fan": return AirColor(core: Color(hex: 0xA9B8CA), bright: Color(hex: 0xF3F6FA), rgb: (169, 184, 202))
    case "dry": return AirColor(core: Color(hex: 0x33C3AE), bright: Color(hex: 0xCFF7F0), rgb: (51, 195, 174))
    default: return AirColor(core: Color(hex: 0x9AA4B2), bright: Color(hex: 0x3A424E), rgb: (154, 164, 178))
    }
}

extension Color {
    init(hex: Int, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

private struct P3 { var x: Double; var y: Double; var z: Double }
private struct Proj { var x: Double; var y: Double; var z: Double; var s: Double }

private struct SceneRenderer {
    let cam: SceneCamera
    let kind: String?
    let vane: Int
    let lr: Int
    let fan: Int
    let auto3d: Bool
    let setpoint: String
    let t: Double
    let reduceMotion: Bool

    // Camera constants (x right, y up, z out of the wall)
    let pv = P3(x: 0, y: 20, z: 30)
    let foc = 860.0, dist = 900.0, cx = 190.0, cy = 76.0
    let floorY = -170.0
    let hw = 130.0

    // Light theme
    let wallColor = Color(hex: 0xEEF1F5), floorColor = Color(hex: 0xDCE1E8), baseColor = Color(hex: 0xC8CFD9)
    let body: (Double, Double, Double) = (248, 249, 251)
    let amb = 0.70, dif = 0.32, bounce = 0.07
    let lightDir: (Double, Double, Double) = (-0.348, 0.795, 0.497)

    func draw(_ ctx: inout GraphicsContext) {
        let on = kind != nil
        let air = airColor(kind)

        // --- camera easing -------------------------------------------------
        if !cam.active {
            cam.targetYaw = -32 + 3 * sin(t / 4.7)
            cam.targetPitch = -6 + 1.2 * sin(t / 3.3)
        }
        if reduceMotion {
            cam.yaw = cam.targetYaw; cam.pitch = cam.targetPitch
        } else {
            cam.yaw += (cam.targetYaw - cam.yaw) * 0.18
            cam.pitch += (cam.targetPitch - cam.pitch) * 0.18
        }
        let yaw = cam.yaw * Double.pi / 180, pitch = cam.pitch * Double.pi / 180
        let cY = cos(yaw), sY = sin(yaw), cP = cos(pitch), sP = sin(pitch)

        func rot(_ x: Double, _ y: Double, _ z: Double) -> (Double, Double, Double) {
            let x1 = x * cY + z * sY
            let z1 = -x * sY + z * cY
            return (x1, y * cP - z1 * sP, y * sP + z1 * cP)
        }
        func proj(_ x: Double, _ y: Double, _ z: Double) -> Proj {
            let r = rot(x - pv.x, y - pv.y, z - pv.z)
            let s = foc / (dist - r.2)
            return Proj(x: cx + r.0 * s, y: cy - r.1 * s, z: r.2, s: s)
        }
        func pt(_ x: Double, _ y: Double, _ z: Double) -> CGPoint {
            let q = proj(x, y, z)
            return CGPoint(x: q.x, y: q.y)
        }
        func poly(_ pts: [(Double, Double, Double)]) -> Path {
            var p = Path()
            for (i, v) in pts.enumerated() {
                let q = pt(v.0, v.1, v.2)
                if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
            }
            p.closeSubpath()
            return p
        }
        func rgbColor(_ c: (Double, Double, Double), _ k: Double) -> Color {
            func ch(_ v: Double) -> Double { return min(255, max(0, (v * k).rounded())) / 255 }
            return Color(.sRGB, red: ch(c.0), green: ch(c.1), blue: ch(c.2), opacity: 1)
        }

        let frame = CGRect(x: 0, y: 0, width: 390, height: 300)

        // --- 1. room ----------------------------------------------------------
        ctx.fill(poly([(-500, floorY, 0), (500, floorY, 0), (500, 520, 0), (-500, 520, 0)]), with: .color(wallColor))
        ctx.fill(poly([(-500, floorY, 0), (500, floorY, 0), (500, floorY, 400), (-500, floorY, 400)]), with: .color(floorColor))
        ctx.fill(poly([(-500, floorY, 0), (500, floorY, 0), (500, floorY + 7, 0), (-500, floorY + 7, 0)]), with: .color(baseColor))
        ctx.fill(Path(frame), with: .linearGradient(
            Gradient(colors: [Color.white.opacity(0.45), Color.black.opacity(0.10)]),
            startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: 300)))

        // --- 2. light: window beam + the glow the air throws on the wall --------
        let tau = Double.pi * 2
        let ANG: [Int: Double] = [1: 12, 2: 38, 3: 62, 4: 86]
        let LAT: [Int: Double] = [1: -35, 2: -17, 3: 0, 4: 17, 5: 35, 6: 0, 7: 0]
        var ang = 38.0, lat = 0.0, spread = 0.6
        if auto3d {
            ang = 55 + 25 * sin(tau * t / 13)
            lat = 30 * sin(tau * t / 19)
        } else {
            ang = vane == 0 ? 48 + 34 * sin(tau * t / 14) : (ANG[vane] ?? 38)      // slow ~14 s swing
            lat = lr == 0 ? 28 * sin(tau * t / 16) : (LAT[lr] ?? 0)
            if lr == 6 { spread = 1.4 }
            if lr == 7 { spread = 0.1 }
        }
        let ar = ang * Double.pi / 180
        let dir = (0.0, -sin(ar), cos(ar))
        let tanLat = tan(lat * Double.pi / 180)
        let SPEED: [Int: Double] = [0: 1.2, 1: 0.6, 2: 0.85, 3: 1.1, 4: 1.45]
        let spd = SPEED[fan] ?? 1
        let GRAV: [String: Double] = ["cool": 70, "dry": 60, "fan": 35, "heat": -20]
        let grav = GRAV[kind ?? ""] ?? 40
        let reach = 170 + 70 * spd

        // Outlet on the slanted underside, and the flap hinged at its back edge.
        let PR: [(Double, Double)] = [(34, 0), (34, 50), (27, 58), (-8, 62), (-26, 51), (-34, 32), (-34, 0)]
        func lerpPR(_ k: Double) -> (Double, Double) {
            return (PR[3].0 + (PR[4].0 - PR[3].0) * k, PR[3].1 + (PR[4].1 - PR[3].1) * k)
        }
        let o1 = lerpPR(0.16), o2 = lerpPR(0.86)
        let hinge = o2
        let tip = (hinge.0 + dir.1 * 26, hinge.1 + dir.2 * 26)

        // Air ribbons
        let xs: [Double] = [-96, -48, 0, 48, 96]
        func airPt(_ i: Int, _ s: Double) -> (Double, Double, Double) {
            let x0 = xs[i]
            let x = x0 + x0 * spread * s + reach * s * tanLat + sin(s * 5 + t * 1.8 * spd + Double(i) * 1.3) * 10 * s
            var y = tip.0 - 2 + dir.1 * reach * s - grav * s * s + cos(s * 4 + t * 1.5 * spd + Double(i)) * 5 * s
            let z = tip.1 + dir.2 * reach * s
            if y < floorY + 5 { y = floorY + 5 }
            return (x, y, z)
        }
        struct Stream { var path: Path; var mw: Double; var bw: Double; var sw: Double; var o1: Double; var o2: Double }
        var streams: [Stream] = []
        struct Dot { var p: CGPoint; var d: Double; var o: Double; var j: Int }
        var dots: [Dot] = []
        var ends: [(Double, Double, Double)] = []
        var sumX = 0.0, sumY = 0.0, landed = 0
        if on {
            for i in 0..<xs.count {
                var path = Path()
                var midS = 1.0
                for k in 0...13 {
                    let w = airPt(i, Double(k) / 13)
                    let q = proj(w.0, w.1, w.2)
                    if k == 0 { path.move(to: CGPoint(x: q.x, y: q.y)) } else { path.addLine(to: CGPoint(x: q.x, y: q.y)) }
                    if k == 7 { midS = q.s; sumX += q.x; sumY += q.y }
                    if k == 13 { ends.append(w); if w.1 <= floorY + 6 { landed += 1 } }
                }
                let o1v = -((t * 100 * spd + Double(i) * 37).truncatingRemainder(dividingBy: 150))
                let o2v = -((t * 150 * spd + Double(i) * 19).truncatingRemainder(dividingBy: 70))
                streams.append(Stream(path: path, mw: 26 * midS, bw: 5 * midS, sw: 2.6 * midS, o1: o1v, o2: o2v))
                for j in 0..<3 {
                    let qq = (t * 0.38 * spd + Double(j) / 3 + Double(i) * 0.21).truncatingRemainder(dividingBy: 1)
                    let pw = airPt(i, qq)
                    let pp = proj(pw.0, pw.1, pw.2)
                    let base = (kind == "heat" ? 3.2 : (kind == "dry" ? 3.6 : 2.7)) + (j == 1 ? 1.3 : 0)
                    dots.append(Dot(p: CGPoint(x: pp.x, y: pp.y), d: base * pp.s, o: pow(sin(Double.pi * qq), 1.3) * 0.95, j: j))
                }
            }
        }
        let pulse = 0.85 + 0.15 * sin(t * 2.2)

        // glow on the wall + window beam (soft)
        ctx.drawLayer { l in
            l.addFilter(.blur(radius: 22))
            var beam = Path()
            beam.move(to: CGPoint(x: 0, y: -20)); beam.addLine(to: CGPoint(x: 110, y: -20))
            beam.addLine(to: CGPoint(x: 240, y: 320)); beam.addLine(to: CGPoint(x: 50, y: 320)); beam.closeSubpath()
            l.fill(beam, with: .color(Color.white.opacity(0.75)))
            if on {
                let n = Double(max(streams.count, 1))
                let g = CGRect(x: sumX / n - 150, y: sumY / n - 100, width: 300, height: 200)
                l.fill(Path(ellipseIn: g), with: .color(air.core.opacity(0.15 * pulse)))
            }
        }

        // --- 3. the unit's soft shadow on the wall ---------------------------------
        ctx.drawLayer { l in
            l.addFilter(.blur(radius: 10))
            l.fill(poly([(-hw + 14, 30, 0), (hw + 18, 30, 0), (hw + 18, -52, 0), (-hw + 14, -52, 0)]),
                   with: .color(Color(.sRGB, red: 28 / 255, green: 38 / 255, blue: 58 / 255, opacity: 0.26)))
        }

        // --- 4. the unit: a side profile (y, z) stretched along x -----------------------
        struct Face { var name: String; var path: Path; var visible: Bool; var c1: Color; var c2: Color }
        var faces: [String: Face] = [:]
        func addFace(_ name: String, _ pts3: [(Double, Double, Double)], _ n: (Double, Double, Double)) {
            var cx3 = 0.0, cy3 = 0.0, cz3 = 0.0
            for p in pts3 { cx3 += p.0; cy3 += p.1; cz3 += p.2 }
            let cnt = Double(pts3.count)
            cx3 /= cnt; cy3 /= cnt; cz3 /= cnt
            let c = rot(cx3 - pv.x, cy3 - pv.y, cz3 - pv.z)
            let nr = rot(n.0, n.1, n.2)
            let visible = nr.0 * -c.0 + nr.1 * -c.1 + nr.2 * (dist - c.2) > 0
            let dot = n.0 * lightDir.0 + n.1 * lightDir.1 + n.2 * lightDir.2
            let lit = amb + dif * max(0, dot) + bounce * max(0, -n.1)
            faces[name] = Face(name: name, path: poly(pts3), visible: visible,
                               c1: rgbColor(body, lit * 1.04), c2: rgbColor(body, lit * 0.93))
        }
        let names = ["top", "bevelTop", "front", "chamfer", "bevelBottom", "bottom"]
        for e in 0..<6 {
            let a0 = PR[e], a1 = PR[e + 1]
            let dy = a1.0 - a0.0, dz = a1.1 - a0.1
            let ln = (dy * dy + dz * dz).squareRoot()
            addFace(names[e], [(-hw, a0.0, a0.1), (hw, a0.0, a0.1), (hw, a1.0, a1.1), (-hw, a1.0, a1.1)], (0, dz / ln, -dy / ln))
        }
        addFace("capR", PR.map { (hw, $0.0, $0.1) }, (1, 0, 0))
        addFace("capL", PR.map { (-hw, $0.0, $0.1) }, (-1, 0, 0))

        func paint(_ name: String) {
            guard let f = faces[name], f.visible else { return }
            let b = f.path.boundingRect
            ctx.fill(f.path, with: .linearGradient(Gradient(colors: [f.c1, f.c2]),
                                                   startPoint: CGPoint(x: b.minX, y: b.minY), endPoint: CGPoint(x: b.minX, y: b.maxY)))
            ctx.stroke(f.path, with: .color(f.c2), style: StrokeStyle(lineWidth: 0.6, lineJoin: .round))
        }
        for name in ["capL", "capR", "bottom", "bevelBottom", "chamfer", "top", "bevelTop", "front"] { paint(name) }

        // front panel details (the front leans out slightly, so z depends on the height)
        func zFront(_ y: Double) -> Double { return 58 + (27 - y) * (4.0 / 35.0) + 0.4 }
        var seam = Path()
        seam.move(to: pt(-hw + 3, 21, zFront(21)))
        seam.addLine(to: pt(hw - 3, 21, zFront(21)))
        ctx.stroke(seam, with: .color(Color(.sRGB, red: 15 / 255, green: 18 / 255, blue: 24 / 255, opacity: 0.08)), lineWidth: 1)
        let ledP = proj(-112, 10, zFront(10))
        let ledR = 2.3 * ledP.s
        ctx.fill(Path(ellipseIn: CGRect(x: ledP.x - ledR, y: ledP.y - ledR, width: ledR * 2, height: ledR * 2)),
                 with: .color(on ? air.core : Color(hex: 0xC5CBD3)))
        let senP = proj(-104, 10, zFront(10))
        let senR = 1.4 * senP.s
        ctx.fill(Path(ellipseIn: CGRect(x: senP.x - senR, y: senP.y - senR, width: senR * 2, height: senR * 2)),
                 with: .color(Color(hex: 0xB4BBC6)))

        // display glass with the set temperature
        let dA = proj(58, 16, zFront(16)), dB = proj(106, 16, zFront(16))
        let dC = proj(58, 4, zFront(4)), dD = proj(106, 4, zFront(4))
        var disp = Path()
        disp.move(to: CGPoint(x: dA.x, y: dA.y)); disp.addLine(to: CGPoint(x: dB.x, y: dB.y))
        disp.addLine(to: CGPoint(x: dD.x, y: dD.y)); disp.addLine(to: CGPoint(x: dC.x, y: dC.y)); disp.closeSubpath()
        ctx.fill(disp, with: .color(Color(hex: 0x0F141B)))
        ctx.stroke(disp, with: .color(Color(hex: 0x0F141B)), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
        if on {
            ctx.drawLayer { l in
                l.transform = CGAffineTransform(a: (dB.x - dA.x) / 48, b: (dB.y - dA.y) / 48,
                                                c: (dC.x - dA.x) / 12, d: (dC.y - dA.y) / 12, tx: dA.x, ty: dA.y).concatenating(l.transform)
                let txt = Text(setpoint).font(.system(size: 8.6, weight: .bold, design: .monospaced))
                l.draw(txt.foregroundColor(air.core.opacity(0.55)), at: CGPoint(x: 24, y: 6.4), anchor: .center)
                l.draw(txt.foregroundColor(air.bright), at: CGPoint(x: 24, y: 6.2), anchor: .center)
            }
        }

        // air outlet and the louver flap
        let outlet = poly([(-118, o1.0, o1.1), (118, o1.0, o1.1), (118, o2.0, o2.1), (-118, o2.0, o2.1)])
        if let ch = faces["chamfer"], ch.visible {
            ctx.fill(outlet, with: .color(on ? Color(hex: 0x151A22) : ch.c1))
            if on { ctx.fill(outlet, with: .color(air.core.opacity(0.3))) }
        }
        if on {
            let fnY = -dir.2, fnZ = dir.1
            let flapLit = amb + dif * abs(fnY * lightDir.1 + fnZ * lightDir.2) * 0.8
            let flap = poly([(-118, hinge.0, hinge.1), (118, hinge.0, hinge.1), (118, tip.0, tip.1), (-118, tip.0, tip.1)])
            ctx.fill(flap, with: .color(rgbColor(body, flapLit)))
            ctx.stroke(flap, with: .color(rgbColor(body, flapLit * 0.85)), style: StrokeStyle(lineWidth: 0.6, lineJoin: .round))
        }

        guard on else { return }

        // --- 5. mist: wide blurred ribbons of air, and the pool where it reaches the floor ----
        var poolPath = Path()
        var poolOpacity = 0.0
        if !ends.isEmpty {
            var minX = 1e9, maxX = -1e9, zc = 0.0
            for w in ends { minX = min(minX, w.0); maxX = max(maxX, w.0); zc += w.2 }
            zc = min(330, zc / Double(ends.count))
            let pcx = (minX + maxX) / 2, prx = (maxX - minX) / 2 + 50
            var ring: [(Double, Double, Double)] = []
            for r in 0..<24 {
                let th = Double(r) / 24 * tau
                ring.append((pcx + prx * cos(th), floorY + 1, zc + 55 * sin(th)))
            }
            poolPath = poly(ring)
            poolOpacity = (0.15 + 0.4 * Double(landed) / Double(ends.count)) * pulse
        }
        let mist = GraphicsContext.Shading.linearGradient(
            Gradient(stops: [.init(color: air.core.opacity(0.75), location: 0),
                             .init(color: air.core.opacity(0.35), location: 0.6),
                             .init(color: air.core.opacity(0), location: 1)]),
            startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: 300))
        ctx.drawLayer { l in
            l.addFilter(.blur(radius: 9))
            l.opacity = 0.6
            l.fill(poolPath, with: .color(air.core.opacity(poolOpacity)))
            for s in streams {
                l.stroke(s.path, with: mist, style: StrokeStyle(lineWidth: s.mw, lineCap: .round, lineJoin: .round))
            }
        }

        // --- 6. airflow streaks travelling along each ribbon ----------------------------
        let streak = GraphicsContext.Shading.linearGradient(
            Gradient(stops: [.init(color: air.bright, location: 0),
                             .init(color: air.core.opacity(0.8), location: 0.65),
                             .init(color: air.core.opacity(0), location: 1)]),
            startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: 300))
        for s in streams {
            ctx.stroke(s.path, with: mist, style: StrokeStyle(lineWidth: s.bw, lineCap: .round, lineJoin: .round))
            ctx.stroke(s.path, with: streak, style: StrokeStyle(lineWidth: s.sw, lineCap: .round, lineJoin: .round, dash: [38, 112], dashPhase: s.o1))
            ctx.stroke(s.path, with: streak, style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round, dash: [10, 60], dashPhase: s.o2))
        }

        // --- 7. sparkles riding the air: bigger when closer to you ------------------------
        for d in dots {
            let glow = d.d * 2.2
            ctx.fill(Path(ellipseIn: CGRect(x: d.p.x - glow / 2, y: d.p.y - glow / 2, width: glow, height: glow)),
                     with: .color(air.core.opacity(d.o * 0.25)))
            ctx.fill(Path(ellipseIn: CGRect(x: d.p.x - d.d / 2, y: d.p.y - d.d / 2, width: d.d, height: d.d)),
                     with: .color(air.bright.opacity(d.o)))
        }
    }
}
