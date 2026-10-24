import SwiftUI
import GemmaMeshKit

/// The control plane's palette: always dark, the app's tier hues (teal phone, blue mesh, amber cloud) brightened for it.
enum CP {
    static let ground = Color(UIColor(hex: 0x06080B))
    static let panel = Color(UIColor(hex: 0x080B10))
    static let line = Color(UIColor(hex: 0x1C2430))
    static let faint = Color(UIColor(hex: 0x2A3340))
    static let text = Color(UIColor(hex: 0xE6EDF5))
    static let soft = Color(UIColor(hex: 0xC9D3DF))
    static let muted = Color(UIColor(hex: 0x8B95A7))
    static let dim = Color(UIColor(hex: 0x6B7686))
    static let link = Color(UIColor(hex: 0x7DD3FC))
    static let phone = Color(UIColor(hex: 0x2DD4BF))
    static let mesh = Color(UIColor(hex: 0x60A5FA))
    static let cloud = Color(UIColor(hex: 0xFBBF24))
    static let off = Color(UIColor(hex: 0x4B5563))

    static func tier(_ t: String) -> Color {
        switch t {
        case "T0": return phone
        case "T4": return cloud
        case "?", "": return off
        default: return mesh
        }
    }

    /// The darker shade of a tier's hue: the "out" part of a token bar, a card's fill.
    static func deep(_ t: String) -> Color {
        switch t {
        case "T0": return Color(UIColor(hex: 0x115E59))
        case "T4": return Color(UIColor(hex: 0x78350F))
        case "?", "": return Color(UIColor(hex: 0x1F2937))
        default: return Color(UIColor(hex: 0x1E3A8A))
        }
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }
}

/// A small spaced caps label: section titles on the control plane.
struct CPLabel: View {
    let text: String
    var body: some View { Text(text.uppercased()).font(CP.mono(11)).tracking(1.4).foregroundStyle(CP.muted) }
}

/// The faint 22 pt grid behind the control plane.
struct CPGrid: View {
    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            stride(from: 0, through: size.width, by: 22).forEach { x in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)) }
            stride(from: 0, through: size.height, by: 22).forEach { y in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)) }
            ctx.stroke(p, with: .color(CP.link.opacity(0.05)), lineWidth: 1)
        }
        .background(CP.ground)
        .ignoresSafeArea()
    }
}

extension View {
    /// A solid dark header with light text. `scheme` also sets the status bar while this page is in front.
    func cpBar(_ scheme: ColorScheme? = .dark) -> some View {
        self.navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(CP.ground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(scheme, for: .navigationBar)
    }

    /// A control-plane panel: dark fill, hairline border, 16 pt corners.
    func cpPanel(padding: CGFloat = 14) -> some View {
        self.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(CP.panel.opacity(0.9), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(CP.line))
    }
}

/// Where the Mesh page's links lead.
enum MeshRoute: Hashable {
    case tokens
    case sessions
    case memory
    case link(MeshLink)
}

// ---- the page --------------------------------------------------------------------------------------

/// The Mesh page, a swipe left of the chat: which devices are up, what went where, what it cost in tokens, and
/// which device started each conversation. Counted from every device's turns in memory (PROTOCOL §4 meta).
struct MeshView: View {
    @Environment(ChatModel.self) private var m
    /// The system's scheme (this view turns its own content dark): the status bar's while the chat is in front.
    @Environment(\.colorScheme) private var systemScheme
    @State private var range: MeshRange = .day

    var body: some View {
        @Bindable var m = m
        NavigationStack(path: $m.meshPath) {
            let stats = m.meshStats(range)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Hero(stats: stats)
                    RangePicker(range: $range)
                    MeshMap(stats: stats)
                    TierLedger(stats: stats)
                    MemoryCard()
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
            .background(CPGrid())
            .navigationTitle("Mesh")
            .cpBar(m.screen == 1 ? .dark : systemScheme)       // both pages are live: the one in front sets the status bar
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { withAnimation { m.screen = 0 } } label: { Text("‹ Chat").font(.subheadline) }.tint(CP.link)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Text("MESH · \(m.mesh.uppercased())").font(CP.mono(11)).tracking(1.2).foregroundStyle(CP.muted)
                }
            }
            .navigationDestination(for: MeshRoute.self) { r in
                switch r {
                case .tokens: TokensView(range: range)
                case .sessions: SessionsView(range: range)
                case .memory: MemoryView()
                case .link(let l): LinkView(link: l, range: range)
                }
            }
        }
        .tint(CP.link)
        .background(CP.ground.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
    }
}

/// Names on the control plane: this phone, the Mac by its device name, Gemini for the frontier.
extension ChatModel {
    func meshName(_ device: String) -> String {
        if device == self.device { return "this iPhone" }
        if device == "frontier" { return "Gemini" }
        return device
    }

    func meshTier(_ device: String) -> String {
        if device == self.device { return "T0" }
        if device == "frontier" { return "T4" }
        return machines.first { $0.device == device }?.tier ?? "?"
    }
}

private struct Hero: View {
    @Environment(ChatModel.self) private var m
    let stats: MeshStats

    var body: some View {
        let up = m.machines.filter(\.reachable).count + (m.phoneReady ? 1 : 0)
        VStack(alignment: .leading, spacing: 6) {
            CPLabel(text: "Tokens processed · \(stats.range.rawValue)")
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text((stats.total.estimated ? "~" : "") + MeshStats.short(stats.work)).font(CP.mono(46, .medium)).foregroundStyle(CP.text)
                    .accessibilityIdentifier("meshTotal")
                Text("in \(MeshStats.short(stats.total.input - stats.total.cached)) · out \(MeshStats.short(stats.total.output))" +
                     (stats.total.cached > 0 ? " · \(MeshStats.short(stats.total.cached)) cached" : ""))
                    .font(CP.mono(12)).foregroundStyle(CP.muted)
            }
            HStack(spacing: 8) {
                Chip(text: "● \(up) device\(up == 1 ? "" : "s") up", color: CP.phone)
                if stats.leftBytes > 0 {
                    Chip(text: "\(Router.grouped(stats.leftBytes)) B left · \(stats.approved) approved", color: CP.cloud)
                } else {
                    Chip(text: "0 B left the mesh", color: CP.phone)
                }
                if stats.webTurns > 0 { Chip(text: "\(stats.webTurns) web", color: CP.cloud) }
            }
        }
        .padding(.top, 6)
    }
}

struct Chip: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(CP.mono(11)).foregroundStyle(color).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.45)))
    }
}

private struct RangePicker: View {
    @Binding var range: MeshRange
    var body: some View {
        HStack(spacing: 4) {
            ForEach(MeshRange.allCases) { r in
                Button { range = r } label: {
                    Text(r.rawValue).font(CP.mono(12)).frame(maxWidth: .infinity, minHeight: 30)
                        .foregroundStyle(range == r ? CP.text : CP.muted)
                        .background(range == r ? CP.line : .clear, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(CP.panel.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(CP.line))
    }
}

// ---- the live map ----------------------------------------------------------------------------------

/// The phone at the centre, the mesh's machines on a ring around it inside the dashed mesh boundary, Gemini outside.
/// A line per device pair that talked in the range: its width is the work tokens; dots run along it while a request
/// is in flight. Tap a line's label for its turns.
private struct MeshMap: View {
    @Environment(ChatModel.self) private var m
    let stats: MeshStats
    private let height: CGFloat = 360

    private struct Spot: Identifiable {
        let id: String          // device
        let name: String
        let tier: String
        let sub: String
        let up: Bool
        let at: CGPoint
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let c = CGPoint(x: w / 2, y: 205)
            let spots = layout(w: w, centre: c)
            let pos = Dictionary(spots.map { ($0.id, $0.at) }, uniquingKeysWith: { a, _ in a })
            let links = stats.links.filter { pos[$0.key.origin] != nil && pos[$0.key.node] != nil && $0.key.origin != $0.key.node }
            let maxWork = max(1, links.values.map { $0.reduce(0) { $0 + $1.work } }.max() ?? 1)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    ctx.stroke(Path(ellipseIn: CGRect(x: 14, y: c.y - 120, width: w - 28, height: 240)), with: .color(CP.faint),
                               style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 125, y: c.y - 115, width: 250, height: 230)),
                               with: .color(Color(UIColor(hex: 0x16202B))), lineWidth: 1)
                    ring(ctx, c, 52, Color(UIColor(hex: 0x123B36)), dash: [])
                    for s in spots where s.id != m.device && stats.links[MeshLink(origin: m.device, node: s.id)] == nil {
                        var p = Path(); p.move(to: c); p.addLine(to: s.at)       // a device nothing went to: a faint line
                        ctx.stroke(p, with: .color(CP.faint), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    }
                    for (l, ts) in links {
                        let work = ts.reduce(0) { $0 + $1.work }
                        var p = Path(); p.move(to: pos[l.origin]!); p.addLine(to: pos[l.node]!)
                        let tier = m.meshTier(l.node)
                        if tier == "T4" {
                            ctx.stroke(p, with: .color(CP.cloud), style: StrokeStyle(lineWidth: 1.5, dash: [2, 4]))
                        } else {
                            ctx.stroke(p, with: .color(CP.tier(tier).opacity(0.85)),
                                       style: StrokeStyle(lineWidth: 1.5 + 5.5 * CGFloat(work) / CGFloat(maxWork), lineCap: .round))
                        }
                    }
                    if let mac = spots.first(where: { $0.tier == "T1" }), m.lastMirrorSync != nil {
                        var p = Path()                                            // the Mac's memory mirror
                        p.move(to: CGPoint(x: c.x - 30, y: c.y + 24))
                        p.addQuadCurve(to: CGPoint(x: mac.at.x - 40, y: mac.at.y + 20), control: CGPoint(x: mac.at.x - 70, y: c.y + 60))
                        ctx.stroke(p, with: .color(CP.phone), style: StrokeStyle(lineWidth: 1.2, dash: [1, 4]))
                    }
                }
                .frame(width: w, height: height)

                if let active = m.activeNode, let to = pos[active] {
                    FlowDots(from: c, to: to, colour: CP.tier(m.meshTier(active)), still: active == m.device)
                        .frame(width: w, height: height).allowsHitTesting(false)
                }

                CPLabel(text: "Mesh boundary").foregroundStyle(CP.dim).offset(x: 12, y: 10)

                ForEach(spots) { s in NodeCard(spot: s, centre: s.id == m.device) .position(s.at) }

                ForEach(Array(links.keys), id: \.self) { l in
                    let ts = links[l]!
                    let a = pos[l.origin]!, b = pos[l.node]!
                    NavigationLink(value: MeshRoute.link(l)) {
                        Text("\(MeshStats.short(ts.reduce(0) { $0 + $1.work })) · \(ts.count) ›").font(CP.mono(11))
                            .foregroundStyle(CP.text).padding(.horizontal, 7).padding(.vertical, 3)
                            .background(CP.ground, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(CP.tier(m.meshTier(l.node)).opacity(0.8)))
                    }
                    .position(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 - 6)
                    .accessibilityIdentifier("meshLink")
                }

                ForEach(spots.filter { $0.id != m.device && $0.tier != "T4" }) { s in
                    let own = stats.links[MeshLink(origin: s.id, node: s.id)]?.reduce(0) { $0 + $1.work } ?? 0
                    if own > 0 {
                        Text("↺ CLI \(MeshStats.short(own))").font(CP.mono(11)).foregroundStyle(CP.tier(s.tier))
                            .position(x: s.at.x, y: s.at.y - 34)
                    }
                }
                HStack(spacing: 10) {
                    HStack(spacing: 4) { Dot(color: CP.phone, size: 6); Text("phone") }
                    HStack(spacing: 4) { Dot(color: CP.mesh, size: 6); Text("mesh") }
                    HStack(spacing: 4) { Dot(color: CP.cloud, size: 6); Text("cloud") }
                    Text("width = tokens")
                    Spacer()
                    if let sync = m.lastMirrorSync, spots.contains(where: { $0.tier == "T1" }) {
                        Text("memory ⇄ \(sync.formatted(date: .omitted, time: .shortened))").foregroundStyle(CP.phone)
                    }
                }
                .font(CP.mono(11)).foregroundStyle(CP.dim)
                .frame(width: w - 24).offset(x: 12, y: height - 26)
            }
        }
        .frame(height: height)
        .background(CP.panel.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(CP.line))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func ring(_ ctx: GraphicsContext, _ c: CGPoint, _ r: CGFloat, _ colour: Color, dash: [CGFloat]) {
        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(colour),
                   style: StrokeStyle(lineWidth: 1, dash: dash))
    }

    /// The phone in the centre; machines spread over the upper arc of the inner ring; Gemini at the top right.
    private func layout(w: CGFloat, centre c: CGPoint) -> [Spot] {
        let phoneSub: String = { if case .ready = m.model { return "\(m.modelLabel) · \(MeshStats.short(stats.byTier["T0"]?.work ?? 0))" }; return "\(m.modelLabel) · off" }()
        var out = [Spot(id: m.device, name: "T0 this iPhone", tier: "T0", sub: phoneSub, up: m.phoneReady, at: c)]
        let machines = m.machines.sorted { $0.tier < $1.tier }
        let angles: [Double] = { switch machines.count {
            case 0: return []
            case 1: return [-125]
            case 2: return [-145, -35]
            default: return (0..<machines.count).map { -150 + 120 * Double($0) / Double(machines.count - 1) }
        } }()
        for (st, a) in zip(machines, angles) {
            let r = a * .pi / 180
            let model = st.model.replacingOccurrences(of: "gemma4-", with: "").uppercased()
            let sub = st.reachable ? model + (st.latencyMs.map { " · \(Int($0)) ms" } ?? "") : "\(model) · away"
            out.append(Spot(id: st.device, name: "\(st.tier) \(st.device)", tier: st.tier, sub: sub, up: st.reachable,
                            at: CGPoint(x: c.x + 125 * cos(r), y: c.y + 115 * sin(r))))
        }
        if m.frontierAllowed {
            out.append(Spot(id: "frontier", name: "T4 Gemini", tier: "T4",
                            sub: "\(MeshStats.short(stats.byTier["T4"]?.work ?? 0)) · asks", up: !m.frontier.apiKey.isEmpty,
                            at: CGPoint(x: w - 62, y: 30)))
        }
        return out
    }

    private struct NodeCard: View {
        let spot: Spot
        let centre: Bool
        var body: some View {
            let col = spot.up ? CP.tier(spot.tier) : CP.muted
            VStack(alignment: .leading, spacing: 1) {
                Text(spot.name).font(.system(size: 12, weight: .medium)).foregroundStyle(spot.up ? CP.text : CP.muted).lineLimit(1)
                Text(spot.sub).font(CP.mono(11)).foregroundStyle(col).lineLimit(1)
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .frame(maxWidth: spot.tier == "T4" ? 112 : 132, alignment: .leading)
            .background {          // opaque, so the lines stop at the card's edge
                RoundedRectangle(cornerRadius: centre ? 12 : 10).fill(CP.panel)
                    .overlay(RoundedRectangle(cornerRadius: centre ? 12 : 10).fill(spot.up ? CP.deep(spot.tier).opacity(0.45) : .clear))
            }
            .overlay(RoundedRectangle(cornerRadius: centre ? 12 : 10)
                .stroke(spot.up ? col : CP.faint, style: StrokeStyle(lineWidth: 1, dash: spot.tier == "T4" ? [4, 3] : [])))
            .fixedSize()
        }
    }
}

/// Dots running from the phone to the node answering now; a pulse on the phone when it answers itself.
private struct FlowDots: View {
    let from: CGPoint
    let to: CGPoint
    let colour: Color
    let still: Bool

    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, _ in
                let t = tl.date.timeIntervalSinceReferenceDate
                if still {
                    let k = CGFloat(t.truncatingRemainder(dividingBy: 1.4) / 1.4)
                    let r = 30 + 30 * k
                    ctx.stroke(Path(ellipseIn: CGRect(x: from.x - r, y: from.y - r, width: 2 * r, height: 2 * r)),
                               with: .color(colour.opacity(Double(1 - k))), lineWidth: 1.5)
                } else {
                    for phase in [0.0, 0.5] {
                        let k = CGFloat((t / 1.6 + phase).truncatingRemainder(dividingBy: 1))
                        let p = CGPoint(x: from.x + (to.x - from.x) * k, y: from.y + (to.y - from.y) * k)
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)), with: .color(.white.opacity(0.9)))
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: .color(colour.opacity(0.35)))
                    }
                }
            }
        }
    }
}

// ---- tokens by tier --------------------------------------------------------------------------------

private struct TierLedger: View {
    @Environment(ChatModel.self) private var m
    let stats: MeshStats

    var body: some View {
        let rows = tierRows(stats, m)
        let maxWork = max(1, rows.map { stats.byTier[$0.tier]?.work ?? 0 }.max() ?? 1)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                CPLabel(text: "Tokens by tier")
                Spacer()
                NavigationLink(value: MeshRoute.tokens) { Text("Details ›").font(.footnote) }
            }
            .frame(minHeight: 28)
            ForEach(rows, id: \.tier) { r in
                let s = stats.byTier[r.tier] ?? TierStats()
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Dot(color: CP.tier(r.tier), size: 8)
                        Text(r.name).font(.system(size: 12)).foregroundStyle(CP.soft).lineLimit(1)
                    }
                    .frame(width: 112, alignment: .leading)
                    TokenBar(tier: r.tier, input: s.tokens.input - s.tokens.cached, output: s.tokens.output, scale: maxWork)
                    Text((s.tokens.estimated ? "~" : "") + MeshStats.short(s.work)).font(CP.mono(12)).foregroundStyle(CP.text)
                        .frame(width: 58, alignment: .trailing)
                }
                .frame(height: 30)
            }
            HStack {
                Text("solid = new in · dark = out" + (stats.total.estimated ? " · ~ estimated" : "")).font(CP.mono(11)).foregroundStyle(CP.dim)
                Spacer()
                NavigationLink(value: MeshRoute.sessions) { Text("Sessions ›").font(.footnote) }
            }
            .padding(.top, 6)
        }
        .cpPanel(padding: 12)
    }
}

/// What memory holds, at a glance; the way into the Memory page.
private struct MemoryCard: View {
    @Environment(ChatModel.self) private var m

    var body: some View {
        NavigationLink(value: MeshRoute.memory) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    CPLabel(text: "Memory")
                    Text("\(m.memory["fact"] ?? 0) facts · \(m.sessions.count) conversations · \(m.documents().count) documents")
                        .font(CP.mono(12)).foregroundStyle(CP.text)
                    Text(m.lastMirrorSync.map { "Mac mirror synced \($0.formatted(date: .omitted, time: .shortened))" } ?? "Mac mirror not synced since the app opened")
                        .font(CP.mono(11)).foregroundStyle(m.lastMirrorSync == nil ? CP.dim : CP.phone)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(CP.link)
            }
            .cpPanel(padding: 12)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("meshMemory")
    }
}

/// The tiers worth a row: the phone, every machine, Gemini when allowed, and any tier the range's turns used.
@MainActor func tierRows(_ stats: MeshStats, _ m: ChatModel) -> [(tier: String, name: String)] {
    var rows: [(tier: String, name: String)] = [("T0", "T0 iPhone")]
    for st in m.machines.sorted(by: { $0.tier < $1.tier }) where !rows.contains(where: { $0.tier == st.tier }) {
        rows.append((st.tier, "\(st.tier) \(st.device)"))
    }
    for t in stats.byTier.keys.sorted() where !rows.contains(where: { $0.tier == t }) && t != "T4" {
        rows.append((t, t == "?" ? "unknown node" : t))
    }
    if m.frontierAllowed || stats.byTier["T4"] != nil { rows.append(("T4", "T4 Gemini")) }
    return rows
}

struct TokenBar: View {
    let tier: String
    let input: Int
    let output: Int
    let scale: Int
    var body: some View {
        GeometryReader { g in
            HStack(spacing: 0) {
                Rectangle().fill(CP.tier(tier)).frame(width: g.size.width * CGFloat(input) / CGFloat(max(scale, 1)))
                Rectangle().fill(CP.deep(tier)).frame(width: g.size.width * CGFloat(output) / CGFloat(max(scale, 1)))
                Spacer(minLength: 0)
            }
        }
        .frame(height: 6)
        .background(Color(UIColor(hex: 0x121922)))
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}
