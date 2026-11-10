import SwiftUI
import AppKit

// Renders the app icon: a fluid dark-to-light blue squircle with a soft lowercase "e".
struct Icon: View {
    var body: some View {
        let pts: [SIMD2<Float>] = [[0, 0], [0.5, 0], [1, 0],
                                   [0, 0.5], [0.42, 0.44], [1, 0.5],
                                   [0, 1], [0.5, 1], [1, 1]]
        let cols: [Color] = [.black, Color(white: 0.08), Color(white: 0.45),
                             Color(white: 0.06), .white, Color(white: 0.12),
                             Color(white: 0.3), Color(white: 0.04), .black]
        ZStack {
            Color.clear
            ZStack {
                MeshGradient(width: 3, height: 3, points: pts, colors: cols, smoothsColors: true, colorSpace: .perceptual)
                Ellipse().fill(.white.opacity(0.55)).frame(width: 300, height: 120).rotationEffect(.degrees(-35)).blur(radius: 50).offset(x: 190, y: 210)
                RoundedRectangle(cornerRadius: 186, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 5)
            }
            .frame(width: 824, height: 824)
            .clipShape(RoundedRectangle(cornerRadius: 186, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
        }
        .frame(width: 1024, height: 1024)
    }
}

struct Wave: Shape {
    var phase: Double
    var amp: Double
    var y: Double
    func path(in r: CGRect) -> Path {
        var p = Path()
        let base = r.height * y
        p.move(to: CGPoint(x: 0, y: r.height))
        for i in 0...100 {
            let x = r.width * Double(i) / 100
            p.addLine(to: CGPoint(x: x, y: base + sin(Double(i) / 100 * 2 * .pi * 1.1 + phase) * amp))
        }
        p.addLine(to: CGPoint(x: r.width, y: r.height))
        p.closeSubpath()
        return p
    }
}

@MainActor func render(_ size: Int, _ url: URL) {
    let r = ImageRenderer(content: Icon())
    r.scale = CGFloat(size) / 1024
    guard let cg = r.cgImage else { fatalError("render failed") }
    let rep = NSBitmapImageRep(cgImage: cg)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
MainActor.assumeIsolated {
    for s in [16, 32, 64, 128, 256, 512, 1024] {
        if s <= 512 { render(s, out.appendingPathComponent("icon_\(s)x\(s).png")) }
        if s >= 32 { render(s, out.appendingPathComponent("icon_\(s / 2)x\(s / 2)@2x.png")) }
    }
    render(1024, out.appendingPathComponent("../icon-preview.png"))
}
