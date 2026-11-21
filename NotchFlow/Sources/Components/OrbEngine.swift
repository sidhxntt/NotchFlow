import SwiftUI
import AppKit
import Combine
import PDFKit
import ImageIO

/// The dotted-orb engine, ported 1:1 from `thinking-orbs/src/engine`. Kept as
/// literal a translation as Swift allows — same names, same formulas, same
/// defaults — so it can be diffed against the TypeScript source line by line.
enum OrbEngine {
    /// `core.ts` `Dot`: ink `white` is 0 = darkest ink on paper; the painter
    /// mirrors it on our dark glass so near dots read bright.
    struct Dot {
        var x: Double
        var y: Double
        var z: Double
        var r: Double
        var white: Double
        var a: Double = 1
    }

    /// `core.ts` `Line`: one projected edge in the connecting constellation.
    struct Line {
        var x1: Double
        var y1: Double
        var x2: Double
        var y2: Double
        var white: Double
        var a: Double = 1
        var w: Double
    }

    static func lerp(_ a: Double, _ b: Double, _ f: Double) -> Double {
        a + (b - a) * f
    }

    static func frac(_ x: Double) -> Double {
        x - floor(x)
    }

    /// `core.ts` `vnoise`: smooth deterministic value noise on a 2-D lattice.
    static func vnoise(_ x: Double, _ y: Double) -> Double {
        let xi = floor(x)
        let yi = floor(y)
        var fx = x - xi
        var fy = y - yi
        fx = fx * fx * (3 - 2 * fx)
        fy = fy * fy * (3 - 2 * fy)
        let a = hashD(xi, yi)
        let b = hashD(xi + 1, yi)
        let c = hashD(xi, yi + 1)
        let d = hashD(xi + 1, yi + 1)
        return a + (b - a) * fx + (c - a) * fy + (a - b - c + d) * fx * fy
    }

    /// `core.ts` `hashD`: deterministic hash in [0, 1).
    static func hashD(_ a: Double, _ b: Double) -> Double {
        let h = sin(a * 12.9898 + b * 78.233) * 43758.5453
        return h - h.rounded(.down)
    }

    /// `core.ts` `angleDelta`: shortest signed angular distance, wrapped to (−π, π].
    static func angleDelta(_ a: Double, _ b: Double) -> Double {
        atan2(sin(a - b), cos(a - b))
    }

    /// `core.ts` `fibDir`: stable directions on a unit sphere (Fibonacci lattice).
    static func fibDir(_ i: Int, _ n: Int) -> (Double, Double, Double) {
        let golden = Double.pi * (3 - sqrt(5.0))
        let y = 1 - (2 * (Double(i) + 0.5)) / Double(n)
        let rad = sqrt(max(0, 1 - y * y))
        let a = Double(i) * golden
        return (rad * cos(a), y, rad * sin(a))
    }

    /// `core.ts` `makeProj`: shared spin + tilt + orthographic projection.
    static func makeProj(yaw: Double, tilt: Double, cx: Double, cy: Double, scale: Double)
        -> (Double, Double, Double) -> (Double, Double, Double) {
        let st = sin(tilt), ct = cos(tilt)
        let sy = sin(yaw), cyw = cos(yaw)
        return { x, y, z in
            let x1 = x * cyw + z * sy
            let z1 = -x * sy + z * cyw
            let y1 = y * ct - z1 * st
            let z2 = y * st + z1 * ct
            return (cx + x1 * scale, cy - y1 * scale, z2)
        }
    }

    /// `core.ts` `paint`: z-sort far→near, matte grayscale dots. Notch's glass
    /// is always the dark substrate, so the ink value is mirrored (`1 - white`)
    /// unconditionally — the reference's `dark: true` path.
    static func paint(_ ctx: inout GraphicsContext, _ dots: inout [Dot], rMin: Double = 0.3) {
        dots.sort { $0.z < $1.z }
        for d in dots {
            guard d.a >= 0.02 else { continue }
            let w = min(1, max(0, d.white))
            let g = 1 - w
            let r = max(rMin, d.r)
            let rect = CGRect(x: d.x - r, y: d.y - r, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: rect), with: .color(Color(white: g, opacity: d.a)))
        }
    }

    /// `core.ts` `paintLines`: stroke edges before the dot pass so nodes sit
    /// above their constellation web.
    static func paintLines(_ ctx: inout GraphicsContext, _ lines: [Line]) {
        for line in lines {
            guard line.a >= 0.02 else { continue }
            let white = min(1, max(0, line.white))
            let gray = 1 - white
            var path = Path()
            path.move(to: CGPoint(x: line.x1, y: line.y1))
            path.addLine(to: CGPoint(x: line.x2, y: line.y2))
            ctx.stroke(path,
                       with: .color(Color(white: gray, opacity: line.a)),
                       style: StrokeStyle(lineWidth: line.w))
        }
    }

    /// `core.ts` `radiusScale`: dot radii were tuned for a 300pt frame;
    /// sub-linear scaling keeps small spinners legible.
    static func radiusScale(_ size: Double, _ power: Double) -> Double {
        pow(size / 300, power)
    }

    // MARK: profiles + preset (`profiles.ts`, `presets.ts`)

    /// `BASE_PROFILES.ribbon`, verbatim.
    static let ribbonBase: [String: Double] = [
        "lanes": 5, "segs": 88, "ghostN": 150,
        "rBase": 1.1, "rDepth": 1.7, "rsPow": 0.6, "rMin": 0.3,
    ]

    /// `profiles.ts` `scaleCounts`: paired 2-D lattice counts each take √scale
    /// so the TOTAL scales by `scale`; flat counts scale linearly. Only the
    /// keys the ribbon profile carries matter here, but the pair table is kept
    /// whole to stay diffable against the source.
    static func scaleCounts(_ opts: [String: Double], _ scale: Double) -> [String: Double] {
        var out = opts
        var done = Set<String>()
        let rt = sqrt(scale)
        let countPairs = [("latRings", "lonDensity"), ("rings", "lonDensity"), ("lanes", "segs")]
        for (a, b) in countPairs {
            if let va = out[a], let vb = out[b], !done.contains(a), !done.contains(b) {
                out[a] = max(2, (va * rt).rounded())
                out[b] = max(2, (vb * rt).rounded())
                done.insert(a)
                done.insert(b)
            }
        }
        for k in ["orbitN", "ghostN", "nodeN", "strandN", "signals"] {
            if let v = out[k], v != 0, !done.contains(k) {
                out[k] = max(1, (v * scale).rounded())
            }
        }
        if let v = out["iconD"] { out["iconD"] = max(0.02, v * scale) }
        return out
    }

    /// `profiles.ts` `scaleRadii`: every radius key scales together so a dot's
    /// near/far falloff stays intact while the mark shrinks or grows.
    static func scaleRadii(_ opts: [String: Double], _ scale: Double) -> [String: Double] {
        var out = opts
        for k in ["rBase", "rDepth", "rActive", "rDot", "ghostR", "partR", "partRDepth",
                  "nodeR", "nodeRDepth"] {
            if let v = out[k] { out[k] = v * scale }
        }
        out["rSizeMul"] = (out["rSizeMul"] ?? 1) * scale
        return out
    }

    /// `BASE_PROFILES.globe`, verbatim. (`rBoost` is deliberately absent from
    /// `RADIUS_KEYS` in the source, so preset radius scaling leaves it alone.)
    static let globeBase: [String: Double] = [
        "latRings": 17, "lonDensity": 44,
        "rBase": 0.6, "rDepth": 1.7, "rBoost": 1.0,
        "inkFar": 0.62, "inkSpan": 0.54, "rsPow": 0.6, "rMin": 0.3,
    ]

    /// `BASE_PROFILES.rubik`, verbatim. (`moveCount` is the scramble LENGTH,
    /// not a lattice count key in the source, so preset count scaling leaves
    /// it alone — the sphere thins out, the scramble stays 14 moves long.)
    static let rubikBase: [String: Double] = [
        "latRings": 15, "lonDensity": 40, "moveCount": 14,
        "rBase": 0.6, "rDepth": 1.7, "rActive": 0.3,
        "inkFar": 0.62, "inkSpan": 0.54, "rsPow": 0.6, "rMin": 0.3,
    ]

    /// `BASE_PROFILES.orbits`, verbatim. (`particles` is per-orbit and not a
    /// count key in the source, so it survives count scaling untouched.)
    static let orbitsBase: [String: Double] = [
        "orbitN": 12, "ghostN": 40, "ghostR": 0.9, "ghostA": 0.5,
        "particles": 3, "partR": 1.2, "partRDepth": 1.6,
        "rsPow": 0.6, "rMin": 0.3,
    ]

    /// `BASE_PROFILES.web`, verbatim.
    static let webBase: [String: Double] = [
        "nodeN": 30, "thr": 0.72, "signals": 5,
        "nodeR": 1.4, "nodeRDepth": 1.8, "lineW": 0.8,
        "rsPow": 0.6, "rMin": 0.3,
    ]

    /// One resolved (state, 20) preset: the mode's baked clock multiplier, its
    /// fully-scaled draw options, and its frame painter.
    struct OrbPreset {
        let speed: Double
        let opts: [String: Double]
        let draw: (inout GraphicsContext, Double, Double, [String: Double]) -> Void
    }

    /// `resolvePreset(state, 20)` for the states Notch wears, each built
    /// through the same machinery as the source and cached once:
    ///   composing → ribbon 20 {speed 3.12,  count ×0.051, size ×1.073,
    ///                          spin 0, bandMul 4.94, wobMul 1}
    ///   searching → globe  20 {speed 2.665, count ×0.105, size ×1.75,
    ///                          scanMul 4.335, dimBase 0.45}
    ///   solving   → rubik  20 {speed 1.95,  count ×0.088, size ×1.9}
    ///   working   → orbits 20 {speed 3.9,   count ×0.238, size ×2.4}
    ///   connecting → web   20 {speed 6.63,  count ×0.25,  size ×1.52}
    private static let presets: [OrbState: OrbPreset] = {
        var composing = scaleRadii(scaleCounts(ribbonBase, 0.051), 1.073)
        for (k, v) in ["spin": 0.0, "bandMul": 4.94, "wobMul": 1.0] { composing[k] = v }

        var searching = scaleRadii(scaleCounts(globeBase, 0.105), 1.75)
        for (k, v) in ["scanMul": 4.335, "dimBase": 0.45] { searching[k] = v }

        let solving = scaleRadii(scaleCounts(rubikBase, 0.088), 1.9)

        let working = scaleRadii(scaleCounts(orbitsBase, 0.238), 2.4)

        let connecting = scaleRadii(scaleCounts(webBase, 0.25), 1.52)

        return [
            .composing: OrbPreset(speed: 3.12, opts: composing, draw: drawRibbon),
            .searching: OrbPreset(speed: 2.665, opts: searching, draw: drawGlobe),
            .solving: OrbPreset(speed: 1.95, opts: solving, draw: drawRubik),
            .working: OrbPreset(speed: 3.9, opts: working, draw: drawOrbits),
            .connecting: OrbPreset(speed: 6.63, opts: connecting, draw: drawWeb),
        ]
    }()

    static func preset(for state: OrbState) -> OrbPreset {
        presets[state]!   // the table covers every OrbState case by construction
    }

    // MARK: ribbon (`ribbon.ts`)

    /// `drawRibbon`, verbatim: an undulating sash of parallel strands rides a
    /// great circle over a faint Fibonacci ghost shell. With the preset's
    /// spin = 0 the 3D tumble is frozen — only the traveling undulation moves.
    static func drawRibbon(_ ctx: inout GraphicsContext, size: Double, t: Double, o: [String: Double]) {
        let cx = size / 2
        let cy = size / 2
        let R = (size / 2) * 0.78
        let spin = o["spin"] ?? 1
        let pt = makeProj(yaw: t * 0.1 * spin, tilt: 0.3, cx: cx, cy: cy, scale: 1)
        let rs = radiusScale(size, o["rsPow"] ?? 0.6)

        var dots: [Dot] = []
        let ghostN = Int(o["ghostN"] ?? 150)
        for i in 0..<ghostN {
            let d = fibDir(i, ghostN)
            let (px, py, z) = pt(d.0 * R, d.1 * R, d.2 * R)
            let depth = (z / R + 1) / 2
            dots.append(Dot(x: px, y: py, z: z, r: 0.8 * rs, white: 0.78,
                            a: 0.1 + 0.22 * depth))
        }

        // The band plane, precessing (frozen when spin = 0).
        let ya = t * 0.24 * spin
        let ta = 0.55 + 0.3 * sin(t * 0.18) * spin
        let ux = cos(ya), uy = 0.0, uz = sin(ya)
        let vx = -uz * sin(ta), vy = cos(ta), vz = ux * sin(ta)
        // Plane normal n = u × v.
        let nx = uy * vz - uz * vy
        let ny = uz * vx - ux * vz
        let nz = ux * vy - uy * vx

        let baseLanes = o["lanes"] ?? 5
        let segs = Int(o["segs"] ?? 88)
        let lanes = max(1, Int((baseLanes * (o["bandMul"] ?? 1)).rounded()))
        for w in 0..<lanes {
            let laneOff = (Double(w) - Double(lanes - 1) / 2) * 0.075
            let edge = abs(Double(w) - Double(lanes - 1) / 2) / max(1, Double(lanes - 1) / 2)
            for k in 0..<segs {
                let a = (Double(k) / Double(segs)) * 2 * .pi
                // The undulation: two traveling waves along the band.
                let wob = (0.16 * sin(a * 3 - t * 1.7 + Double(w) * 0.22)
                         + 0.07 * sin(a * 5 + t * 1.1)) * (o["wobMul"] ?? 1)
                let off = laneOff + wob
                let x = ux * cos(a) + vx * sin(a) + nx * off
                let y = uy * cos(a) + vy * sin(a) + ny * off
                let z = uz * cos(a) + vz * sin(a) + nz * off
                let l = sqrt(x * x + y * y + z * z)
                let (px, py, zr) = pt(x / l * R, y / l * R, z / l * R)
                let depth = (zr / R + 1) / 2
                dots.append(Dot(
                    x: px, y: py, z: zr,
                    r: ((o["rBase"] ?? 1.1) + (o["rDepth"] ?? 1.7) * depth) * (1 - 0.25 * edge) * rs,
                    white: 0.52 - 0.44 * depth + 0.18 * edge,
                    a: 0.4 + 0.6 * depth))
            }
        }
        paint(&ctx, &dots, rMin: o["rMin"] ?? 0.3)
    }

    // MARK: globe (`lattice.ts`)

    /// `drawGlobe`, verbatim: a lat/long dot field; a scan meridian sweeps —
    /// read as a size ripple riding the near face, not a shine.
    static func drawGlobe(_ ctx: inout GraphicsContext, size: Double, t: Double, o: [String: Double]) {
        let spin = 0.5
        let cx = size / 2
        let cy = size / 2
        let radius = (size / 2) * 0.82
        let tilt = 0.4 + 0.06 * sin(t * 0.35)
        let pt = makeProj(yaw: t * spin, tilt: tilt, cx: cx, cy: cy, scale: radius)
        // The scan sweeps relative to the spin; scanMul scales that relative rate.
        let scan = t * (spin + (1.7 - spin) * (o["scanMul"] ?? 1))
        let rs = radiusScale(size, o["rsPow"] ?? 0.6)
        let dimBase = o["dimBase"] ?? 1

        var dots: [Dot] = []
        let latRings = Int(o["latRings"] ?? 17)
        let lonDensity = o["lonDensity"] ?? 44
        for li in 0...latRings {
            let lat = -Double.pi / 2 + (Double(li) / Double(latRings)) * .pi
            let cosLat = cos(lat)
            let sinLat = sin(lat)
            let lonCount = max(1, Int((abs(cosLat) * lonDensity).rounded()))
            for lj in 0..<lonCount {
                let lon = (Double(lj) / Double(lonCount)) * 2 * .pi
                let (px, py, z) = pt(cosLat * cos(lon), sinLat, cosLat * sin(lon))
                let depth = (z + 1) / 2
                // The scan: a moving meridian read as a size ripple, not a shine.
                let d = angleDelta(lon + t * spin, scan)
                let boost = exp(-(d * d) / 0.18) * max(0, z)
                dots.append(Dot(
                    x: px, y: py, z: z,
                    r: ((o["rBase"] ?? 0.6) + (o["rDepth"] ?? 1.7) * depth
                        + (o["rBoost"] ?? 1) * boost) * rs,
                    white: (o["inkFar"] ?? 0.62) - (o["inkSpan"] ?? 0.54) * depth,
                    // dimBase < 1 fades un-scanned dots so the meridian reads clearly.
                    a: dimBase + (1 - dimBase) * min(1, boost)))
            }
        }
        paint(&ctx, &dots, rMin: o["rMin"] ?? 0.3)
    }

    // MARK: rubik (`lattice.ts`)

    /// `lattice.ts` `Move`: one quarter turn of the band lying between `lo`
    /// and `hi` along `axis` (0 = x, 1 = y, 2 = z).
    private struct Move {
        let axis: Int
        let lo: Double
        let hi: Double
        let ang: Double
    }

    /// `lattice.ts` `solveCycle`, verbatim: rapid eased moves scramble, then
    /// replay in reverse (a palindrome) so everything clicks back to solved,
    /// rests, repeats. Returns how far each move has been applied plus which
    /// one is in flight.
    private static func solveCycle(_ time: Double, _ count: Int,
                                   _ slotDur: Double, _ rest: Double)
        -> (amount: [Double], active: Int) {
        let cyc = 2 * Double(count) * slotDur + rest
        let tc = time.truncatingRemainder(dividingBy: cyc)
        var amount = [Double](repeating: 0, count: count)
        var active = -1
        if tc < 2 * Double(count) * slotDur {
            let slot = Int(tc / slotDur)
            let p = (tc - Double(slot) * slotDur) / slotDur
            let cl = min(1, p / 0.7)
            let ep = 1 - pow(1 - cl, 3)   // machine ease-out
            if slot < count {
                for i in 0..<slot { amount[i] = 1 }
                amount[slot] = ep
                active = slot
            } else {
                let u = 2 * count - 1 - slot
                for i in 0..<u { amount[i] = 1 }
                amount[u] = 1 - ep
                active = u
            }
        }
        return (amount, active)
    }

    /// `lattice.ts` `applyMoves`, verbatim: turn a point by every move whose
    /// band contains it, each scaled by that move's eased amount. Also reports
    /// whether the point rode the move currently in flight — the "hand".
    private static func applyMoves(_ pt3: (Double, Double, Double),
                                   _ moves: [Move],
                                   _ sc: (amount: [Double], active: Int))
        -> (Double, Double, Double, Bool) {
        var (x, y, z) = pt3
        var inActive = false
        for i in 0..<moves.count {
            if sc.amount[i] <= 0 { continue }
            let mv = moves[i]
            let coord = mv.axis == 0 ? x : (mv.axis == 1 ? y : z)
            if coord < mv.lo || coord >= mv.hi { continue }
            if i == sc.active { inActive = true }
            let a = mv.ang * sc.amount[i]
            let ca = cos(a), sa = sin(a)
            if mv.axis == 0 {
                let y2 = y * ca - z * sa
                z = y * sa + z * ca
                y = y2
            } else if mv.axis == 1 {
                let x2 = x * ca + z * sa
                z = -x * sa + z * ca
                x = x2
            } else {
                let x2 = x * ca - y * sa
                y = x * sa + y * ca
                x = x2
            }
        }
        return (x, y, z, inActive)
    }

    /// `lattice.ts` `makeMoves`, verbatim: the scramble is DETERMINISTIC —
    /// axis, band and direction all fall out of `hashD`, so every run turns
    /// the same sequence. Rebuilt per frame exactly as the source does.
    private static func makeMoves(_ count: Int) -> [Move] {
        var moves: [Move] = []
        for i in 0..<count {
            let axis = min(2, Int(hashD(Double(i), 2.3) * 3))
            let lo = -1.0 + 0.5 * Double(min(3, Int(hashD(Double(i), 5.9) * 4)))
            let dir: Double = hashD(Double(i), 7.7) < 0.5 ? 1 : -1
            moves.append(Move(axis: axis, lo: lo, hi: lo + 0.5, ang: dir * .pi / 2))
        }
        return moves
    }

    /// `drawRubik`, verbatim: the globe's lat/long dot field, cut into bands
    /// that twist in quarter turns — scramble, then the moves replay backwards
    /// and the sphere clicks back to solved. The band being turned inks a
    /// touch darker and swells by `rActive`: the "hand" on it.
    static func drawRubik(_ ctx: inout GraphicsContext, size: Double, t: Double, o: [String: Double]) {
        let cx = size / 2
        let cy = size / 2
        let R = (size / 2) * 0.82
        let pt = makeProj(yaw: t * 0.55, tilt: 0.35 + 0.1 * sin(t * 0.9),
                          cx: cx, cy: cy, scale: R)
        let rs = radiusScale(size, o["rsPow"] ?? 0.6)
        let moveCount = Int(o["moveCount"] ?? 14)
        let moves = makeMoves(moveCount)
        let sc = solveCycle(t, moveCount, 0.42, 1.2)

        var dots: [Dot] = []
        let latRings = Int(o["latRings"] ?? 15)
        let lonDensity = o["lonDensity"] ?? 40
        for li in 0...latRings {
            let lat = -Double.pi / 2 + (Double(li) / Double(latRings)) * .pi
            let cosLat = cos(lat)
            let sinLat = sin(lat)
            let lonCount = max(1, Int((abs(cosLat) * lonDensity).rounded()))
            for lj in 0..<lonCount {
                let lon = (Double(lj) / Double(lonCount)) * 2 * .pi
                let (x, y, z, inActive) = applyMoves(
                    (cosLat * cos(lon), sinLat, cosLat * sin(lon)), moves, sc)
                let (px, py, zr) = pt(x, y, z)
                let depth = (zr + 1) / 2
                dots.append(Dot(
                    x: px, y: py, z: zr,
                    r: ((o["rBase"] ?? 0.6) + (o["rDepth"] ?? 1.7) * depth
                        + (inActive ? (o["rActive"] ?? 0.3) : 0)) * rs,
                    white: (o["inkFar"] ?? 0.62) - (o["inkSpan"] ?? 0.54) * depth
                        - (inActive ? 0.14 : 0)))
            }
        }
        paint(&ctx, &dots, rMin: o["rMin"] ?? 0.3)
    }

    // MARK: orbits (`orbits.ts`)

    /// `drawOrbits`, verbatim: particles on tilted orbits — no nucleus (the
    /// tuned preset runs coreless): just ghost paths and the particles doing
    /// the work.
    static func drawOrbits(_ ctx: inout GraphicsContext, size: Double, t: Double, o: [String: Double]) {
        let cx = size / 2
        let cy = size / 2
        let R = (size / 2) * 0.82
        let pt = makeProj(yaw: t * 0.12, tilt: 0.3, cx: cx, cy: cy, scale: 1)
        let rs = radiusScale(size, o["rsPow"] ?? 0.6)

        var dots: [Dot] = []
        let orbitN = Int(o["orbitN"] ?? 12)
        let ghostN = Int(o["ghostN"] ?? 40)
        let particles = Int(o["particles"] ?? 3)

        // Orbits: each a tilted circle — a ghost path + running particles.
        for orb in 0..<orbitN {
            let h1 = hashD(Double(orb), 1.7)
            let h2 = hashD(Double(orb), 5.2)
            let h3 = hashD(Double(orb), 8.9)
            let ro = R * (0.45 + 0.52 * h1)
            let th = h1 * 2 * .pi
            let phi = acos(2 * h2 - 1)
            // Orbit plane basis (u, v ⟂ normal n).
            let nx = sin(phi) * cos(th)
            let ny = cos(phi)
            let nz = sin(phi) * sin(th)
            var ux = -ny
            var uy = nx
            let uz = 0.0
            let ul = max(1e-6, sqrt(ux * ux + uy * uy))
            ux /= ul
            uy /= ul
            let vx = ny * uz - nz * uy
            let vy = nz * ux - nx * uz
            let vz = nx * uy - ny * ux
            let speed = (0.25 + 0.55 * h3) * (h3 > 0.5 ? 1 : -1)

            // Ghost path.
            for k in 0..<ghostN {
                let a = (Double(k) / Double(ghostN)) * 2 * .pi
                let (px, py, z) = pt((ux * cos(a) + vx * sin(a)) * ro,
                                     (uy * cos(a) + vy * sin(a)) * ro,
                                     (uz * cos(a) + vz * sin(a)) * ro)
                let depth = (z / ro + 1) / 2
                dots.append(Dot(x: px, y: py, z: z,
                                r: (o["ghostR"] ?? 0.9) * rs, white: 0.72,
                                a: (o["ghostA"] ?? 0.5) * (0.4 + 0.6 * depth)))
            }
            // The particles doing the work.
            for m in 0..<particles {
                let a = t * speed + (Double(m) / Double(particles)) * 2 * .pi + h2 * 6
                let (px, py, z) = pt((ux * cos(a) + vx * sin(a)) * ro,
                                     (uy * cos(a) + vy * sin(a)) * ro,
                                     (uz * cos(a) + vz * sin(a)) * ro)
                let depth = (z / ro + 1) / 2
                dots.append(Dot(x: px, y: py, z: z,
                                r: ((o["partR"] ?? 1.2) + (o["partRDepth"] ?? 1.6) * depth) * rs,
                                white: 0.3 - 0.22 * depth))
            }
        }
        paint(&ctx, &dots, rMin: o["rMin"] ?? 0.3)
    }

    // MARK: web (`web.ts`)

    /// `drawWeb`, verbatim: nodes wander over a rotating sphere, nearby pairs
    /// wire together, and bright packets travel between deterministically
    /// re-picked node pairs.
    static func drawWeb(_ ctx: inout GraphicsContext, size: Double, t: Double, o: [String: Double]) {
        let cx = size / 2
        let cy = size / 2
        let R = (size / 2) * 0.8 * (o["spread"] ?? 1)
        let pt = makeProj(yaw: t * 0.12, tilt: 0.32, cx: cx, cy: cy, scale: R)
        let rs = radiusScale(size, o["rsPow"] ?? 0.6)
        let nodeN = Int(o["nodeN"] ?? 30)
        let threshold = o["thr"] ?? 0.72
        let nodeR = o["nodeR"] ?? 1.4
        let nodeRDepth = o["nodeRDepth"] ?? 1.8

        // Fibonacci nodes drift under slow value noise, then renormalise back
        // onto the unit sphere.
        var nodes: [(Double, Double, Double)] = []
        for i in 0..<nodeN {
            let d = fibDir(i, nodeN)
            let x = d.0 + 0.3 * (vnoise(Double(i) * 0.31 + 9, t * 0.24) - 0.5) * 2
            let y = d.1 + 0.3 * (vnoise(Double(i) * 0.53 + 27, t * 0.21) - 0.5) * 2
            let z = d.2 + 0.3 * (vnoise(Double(i) * 0.77 + 55, t * 0.27) - 0.5) * 2
            let length = sqrt(x * x + y * y + z * z)
            nodes.append((x / length, y / length, z / length))
        }

        var lines: [Line] = []
        var dots: [Dot] = []
        // Edges between close neighbours, faded by proximity and depth.
        for i in 0..<nodeN {
            for j in (i + 1)..<nodeN {
                let dx = nodes[i].0 - nodes[j].0
                let dy = nodes[i].1 - nodes[j].1
                let dz = nodes[i].2 - nodes[j].2
                let distance = sqrt(dx * dx + dy * dy + dz * dz)
                if distance >= threshold { continue }
                let (x1, y1, z1) = pt(nodes[i].0, nodes[i].1, nodes[i].2)
                let (x2, y2, z2) = pt(nodes[j].0, nodes[j].1, nodes[j].2)
                let depth = ((z1 + z2) / 2 + 1) / 2
                lines.append(Line(
                    x1: x1, y1: y1, x2: x2, y2: y2, white: 0.42,
                    a: (1 - distance / threshold) * (0.3 + 0.55 * depth),
                    w: max(0.6, (o["lineW"] ?? 0.8) * rs)))
            }
        }

        for i in 0..<nodeN {
            let (px, py, z) = pt(nodes[i].0, nodes[i].1, nodes[i].2)
            let depth = (z + 1) / 2
            let pulse = 1 + 0.25 * sin(t * 1.4 + Double(i) * 2.7)
            dots.append(Dot(
                x: px, y: py, z: z,
                r: (nodeR + nodeRDepth * depth) * pulse * rs,
                white: 0.55 - 0.45 * depth))
        }

        // Bright packets running between paired nodes.
        let signals = Int(o["signals"] ?? 5)
        for signal in 0..<signals {
            let offset = Double(signal) * 7.31
            let segment = floor(t * 0.55 + offset)
            let a = min(nodeN - 1, Int(floor(hashD(segment, Double(signal) * 3.1 + 1.7) * Double(nodeN))))
            let b = min(nodeN - 1, Int(floor(hashD(segment, Double(signal) * 5.7 + 4.2) * Double(nodeN))))
            if a == b { continue }
            let f = frac(t * 0.55 + offset)
            let x = lerp(nodes[a].0, nodes[b].0, f)
            let y = lerp(nodes[a].1, nodes[b].1, f)
            let z = lerp(nodes[a].2, nodes[b].2, f)
            let length = max(1e-6, sqrt(x * x + y * y + z * z))
            let (px, py, zr) = pt(x / length, y / length, z / length)
            let depth = (zr + 1) / 2
            dots.append(Dot(
                x: px, y: py, z: zr,
                r: (nodeR * 1.5 + nodeRDepth * depth) * rs,
                white: 0.05, a: 0.5 + 0.5 * depth))
        }

        paintLines(&ctx, lines)
        paint(&ctx, &dots, rMin: o["rMin"] ?? 0.3)
    }
}
