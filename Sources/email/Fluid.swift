import SwiftUI

struct Palette: Equatable {
    /// deep → mid → glow → light → ice
    var ramp: [SIMD3<Double>]
    /// added to every mesh point's brightness (more splashes) and to a click's flash
    var lift = 0.0
    var clickBoost = 1.5
    /// solid colour under the glass panels when the background is too bright for white text
    var panel: Color?

    init(_ hex: UInt32...) {
        ramp = hex.map { SIMD3(Double($0 >> 16 & 0xff) / 255, Double($0 >> 8 & 0xff) / 255, Double($0 & 0xff) / 255) }
    }

    func color(_ i: Int) -> Color { let c = ramp[i]; return Color(red: c.x, green: c.y, blue: c.z) }
    var deep: Color { color(0) }
    var light: Color { color(3) }
    var ice: Color { color(4) }

    func sample(_ level: Double) -> SIMD3<Double> {
        let l = min(max(level, 0), Double(ramp.count - 1))
        let i = min(Int(l), ramp.count - 2)
        let f = l - Double(i)
        return ramp[i] + (ramp[i + 1] - ramp[i]) * f
    }

    // mostly black, white splashes; spaces differ only slightly in how bright the splashes get
    static let all: [Palette] = [
        Palette(0x000000, 0x070707, 0x1A1A1A, 0x7C7C7C, 0xFFFFFF),
        Palette(0x000000, 0x050505, 0x161616, 0x6E6E6E, 0xF2F2F2),
        Palette(0x000000, 0x080808, 0x1E1E1E, 0x888888, 0xFAFAFA),
        Palette(0x000000, 0x060606, 0x141414, 0x606060, 0xE8E8E8),
        Palette(0x000000, 0x090909, 0x202020, 0x939393, 0xFFFFFF),
        // triton: UC San Diego Yellow #FFCD00 / Gold #C69214 with Blue #00629B and Navy #182B49 splashes (brand.ucsd.edu)
        Palette(0xFFCD00, 0xFFC400, 0xC69214, 0x00629B, 0x182B49),
        Palette.ember,   // 6
        Palette.crimson, // 7
    ]
    static let tritonIndex = 5
    // ember: black with dark red splashes
    static let ember = Palette(0x000000, 0x0A0102, 0x3A0509, 0x7E0C14, 0xB3141E)
    // crimson: all red with white splashes
    static let crimson: Palette = {
        var p = Palette(0xB0101A, 0xC8141F, 0xE02A33, 0xF6B5B8, 0xFFFFFF)
        p.lift = 0.5
        p.clickBoost = 2.6
        p.panel = Color(red: 0.36, green: 0.03, blue: 0.06).opacity(0.62)
        return p
    }()
    /// bright backgrounds need dark sidebar text and navy-tinted glass
    var isLight: Bool { ramp[0].x + ramp[0].y + ramp[0].z > 1.5 }
}


/// Mesh-gradient fluid. Clicks push the mesh outward and brighten it, then it settles.
@MainActor
final class Fluid {
    static let shared = Fluid()
    static let chat = Fluid()

    private var impulses: [(p: SIMD2<Double>, t: Double)] = []
    private var from = Palette.all[0]
    private var to = Palette.all[0]
    private var paletteStart = 0.0
    private let n = 5
    private let phases: [Double] = (0..<25).map { _ in Double.random(in: 0..<(2 * .pi)) }
    /// each point swells into a splash and fades on its own slow rhythm, so splashes keep appearing all over
    private let speeds: [Double] = (0..<25).map { _ in Double.random(in: 0.11...0.27) }

    static var now: Double { Date().timeIntervalSinceReferenceDate }

    func poke(_ p: SIMD2<Double>) {
        impulses.append((p, Self.now))
        if impulses.count > 8 { impulses.removeFirst(impulses.count - 8) }
    }

    func setPalette(_ p: Palette, animated: Bool = true) {
        let t = Self.now
        from = animated ? current(t) : p
        to = p
        paletteStart = t
    }

    private func current(_ t: Double) -> Palette {
        let k = min(max((t - paletteStart) / 1.1, 0), 1)
        let e = k * k * (3 - 2 * k)
        var p = to
        p.ramp = zip(from.ramp, to.ramp).map { $0 + ($1 - $0) * e }
        p.lift = from.lift + (to.lift - from.lift) * e
        return p
    }

    func frame(_ t: Double) -> ([SIMD2<Float>], [Color]) {
        let pal = current(t)
        impulses.removeAll { t - $0.t > 4 }
        var pts = [SIMD2<Float>]()
        var cols = [Color]()
        pts.reserveCapacity(n * n)
        cols.reserveCapacity(n * n)
        for j in 0..<n {
            for i in 0..<n {
                let k = j * n + i
                let base = SIMD2(Double(i) / Double(n - 1), Double(j) / Double(n - 1))
                let ph = phases[k]
                // watercolour: the mesh sways and every point blooms into a splash and fades, at its own pace
                var off = SIMD2(sin(t * 0.55 + ph) * 0.1 + sin(t * 0.23 + ph * 2) * 0.04,
                                cos(t * 0.47 + ph * 1.3) * 0.1 + cos(t * 0.19 + ph) * 0.04)
                let edge = i == 0 || i == n - 1 || j == 0 || j == n - 1
                let nearSidebar = pal.isLight && i == 0
                let bloom = 0.5 + 0.5 * sin(t * speeds[k] + ph)              // 0…1
                let peak = nearSidebar ? 1.2 : (edge ? 2.9 : 3.6)
                var level = 0.15 + peak * pow(bloom, 1.3) + pal.lift
                for imp in impulses {
                    let a = t - imp.t
                    let tau = 0.42
                    let env = (a / tau) * exp(1 - a / tau)
                    var d = base - imp.p
                    let dist2 = d.x * d.x + d.y * d.y
                    let fall = exp(-dist2 / 0.09)
                    let len = max(sqrt(dist2), 0.0001)
                    d /= len
                    off += d * (0.13 * env * fall)
                    level += (pal.isLight ? 3.2 : pal.clickBoost) * env * exp(-dist2 / 0.05)
                }
                let edgeX = i == 0 || i == n - 1
                let edgeY = j == 0 || j == n - 1
                if edgeX { off.x = 0 }
                if edgeY { off.y = 0 }
                if edgeX || edgeY { off *= 0.6 }
                let p = base + off
                pts.append(SIMD2(Float(min(max(p.x, 0), 1)), Float(min(max(p.y, 0), 1))))
                // bright spaces stop at their splash colour (Triton blue), never the darkest shade
                let c = pal.sample(pal.isLight ? min(level, 3.0) : level)
                cols.append(Color(red: c.x, green: c.y, blue: c.z))
            }
        }
        return (pts, cols)
    }
}

/// The one switch for every animated view. On only while this app is frontmost and a window is actually visible.
/// (`appearsActive` + TimelineView's `paused:` did NOT stop the timelines once the app had been focused and left —
/// it kept redrawing in the background at ~25% CPU — so paused views drop their TimelineView entirely.)
@MainActor @Observable
final class Motion {
    static let shared = Motion()
    private static let demo = ProcessInfo.processInfo.environment["EMAIL_DEMO"] != nil
    private(set) var on = true
    /// the moment the animation stopped, so the frozen frame is the last one shown
    private(set) var frozenAt = Fluid.now

    private init() {
        let nc = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSApplication.didChangeOcclusionStateNotification, NSApplication.didHideNotification,
                     NSApplication.didUnhideNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Motion.shared.refresh() }
            }
        }
        refresh()
    }

    func refresh() {
        let app = NSApplication.shared
        let want = Self.demo || (app.isActive && !app.isHidden && app.occlusionState.contains(.visible))
        guard want != on else { return }
        if !want { frozenAt = Fluid.now }
        on = want
    }
}

struct FluidBackground: View {
    var fluid: Fluid = .shared

    var body: some View {
        Group {
            if Motion.shared.on {
                TimelineView(.animation(minimumInterval: 1 / 20)) { tl in
                    mesh(tl.date.timeIntervalSinceReferenceDate)
                }
            } else {
                mesh(Motion.shared.frozenAt)
            }
        }
        .ignoresSafeArea()
    }

    private func mesh(_ t: Double) -> some View {
        let (pts, cols) = fluid.frame(t)
        return MeshGradient(width: 5, height: 5, points: pts, colors: cols, smoothsColors: true, colorSpace: .perceptual)
    }
}

// MARK: logo

struct LogoMark: View {
    var size: CGFloat = 28

    var body: some View {
        Group {
            if Motion.shared.on {
                TimelineView(.animation(minimumInterval: 1 / 10)) { tl in mesh(tl.date.timeIntervalSinceReferenceDate) }
            } else {
                mesh(Motion.shared.frozenAt)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).strokeBorder(.white.opacity(0.22), lineWidth: max(0.5, size * 0.02)))
    }

    private func mesh(_ t: Double) -> some View {
            let pts: [SIMD2<Float>] = [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [Float(0.5 + 0.18 * sin(t * 0.9)), Float(0.5 + 0.18 * cos(t * 0.7))], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1],
            ]
            let w = 0.5 + 0.5 * sin(t * 0.6)
            let cols: [Color] = [.black, Color(white: 0.1), Color(white: 0.55 * w),
                                 Color(white: 0.08), .white, Color(white: 0.15),
                                 Color(white: 0.5 * (1 - w)), Color(white: 0.06), .black]
        return MeshGradient(width: 3, height: 3, points: pts, colors: cols, smoothsColors: true)
    }
}

struct Wordmark: View {
    var size: CGFloat = 17
    var body: some View {
        HStack(spacing: size * 0.4) {
            LogoMark(size: size * 1.35)
            Text("email")
                .font(.system(size: size, weight: .semibold, design: .rounded))
        }
    }
}
