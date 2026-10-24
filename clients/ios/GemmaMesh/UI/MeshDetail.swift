import Charts
import SwiftUI
import GemmaMeshKit

// ---- tokens by tier --------------------------------------------------------------------------------

/// Work tokens over the range, stacked by tier; a card per tier; and which device asked for them.
struct TokensView: View {
    @Environment(ChatModel.self) private var m
    let range: MeshRange

    private struct Slice: Identifiable {
        let id = UUID()
        let index: Int
        let tier: String
        let work: Int
    }

    var body: some View {
        let stats = m.meshStats(range)
        let buckets = stats.buckets(12)
        let slices = buckets.enumerated().flatMap { i, b in b.map { Slice(index: i, tier: $0.key, work: $0.value) } }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        CPLabel(text: "Throughput · 12 slices")
                        Spacer()
                        Text(MeshStats.short(stats.work)).font(CP.mono(12)).foregroundStyle(CP.text)
                    }
                    Chart(slices) { s in
                        BarMark(x: .value("slice", s.index), y: .value("tokens", s.work))
                            .foregroundStyle(CP.tier(s.tier))
                    }
                    .chartXScale(domain: -0.5...11.5)
                    .chartXAxis(.hidden)
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                            AxisGridLine().foregroundStyle(CP.line)
                            AxisValueLabel { Text(MeshStats.short(v.as(Int.self) ?? 0)).font(CP.mono(11)).foregroundStyle(CP.dim) }
                        }
                    }
                    .frame(height: 150)
                    HStack { Text("−" + range.rawValue.replacingOccurrences(of: " ", with: "")); Spacer(); Text("now") }
                        .font(CP.mono(11)).foregroundStyle(CP.dim)
                }
                .cpPanel(padding: 12)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10, alignment: .top), GridItem(.flexible(), spacing: 10, alignment: .top)], spacing: 10) {
                    ForEach(tierRows(stats, m), id: \.tier) { r in TierCard(tier: r.tier, name: r.name, s: stats.byTier[r.tier] ?? TierStats()) }
                }

                OriginSplit(stats: stats)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .background(CPGrid())
        .navigationTitle("Tokens by tier")
        .cpBar()
    }

    private struct TierCard: View {
        @Environment(ChatModel.self) private var m
        let tier: String
        let name: String
        let s: TierStats

        var body: some View {
            let col = CP.tier(tier)
            // A machine's own counter covers every client and side request (classifier, facts) since it started.
            let node = m.machines.first { $0.tier == tier }?.info
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.system(size: 13, weight: .medium)).foregroundStyle(col).lineLimit(1)
                Text(MeshStats.short(s.work)).font(CP.mono(26, .medium)).foregroundStyle(CP.text)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                    GridRow { Text("in \(MeshStats.short(s.tokens.input - s.tokens.cached))"); Text("out \(MeshStats.short(s.tokens.output))") }
                    GridRow { Text("\(s.turns) turn\(s.turns == 1 ? "" : "s")"); Text(s.avgSeconds.map { String(format: "%.1fs avg", $0) } ?? "—") }
                    GridRow { Text("\(s.privateTurns) private"); Text(s.tokens.estimated ? "~ est." : "") }
                }
                .font(CP.mono(11)).foregroundStyle(CP.muted)
                if s.tokens.cached > 0 { Text("\(MeshStats.short(s.tokens.cached)) reused from cache").font(CP.mono(11)).foregroundStyle(CP.dim) }
                if let n = node, let i = n.tokensIn, let o = n.tokensOut {
                    Text("node total \(MeshStats.short(i - (n.tokensCached ?? 0) + o))").font(CP.mono(11)).foregroundStyle(CP.dim)
                }
            }
            .padding(12).frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(CP.deep(tier).opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(col.opacity(s.turns > 0 ? 0.8 : 0.3)))
        }
    }
}

private struct OriginSplit: View {
    @Environment(ChatModel.self) private var m
    let stats: MeshStats

    var body: some View {
        let origins = stats.workByOrigin.sorted { $0.value > $1.value }
        let total = max(1, stats.work)
        VStack(alignment: .leading, spacing: 10) {
            CPLabel(text: "Who asked for them")
            if origins.isEmpty {
                Text("No turns in this range.").font(.footnote).foregroundStyle(CP.muted)
            } else {
                GeometryReader { g in
                    HStack(spacing: 2) {
                        ForEach(origins, id: \.key) { o in
                            Rectangle().fill(CP.tier(m.meshTier(o.key))).frame(width: max(2, (g.size.width - 2 * CGFloat(origins.count - 1)) * CGFloat(o.value) / CGFloat(total)))
                        }
                    }
                }
                .frame(height: 10).clipShape(RoundedRectangle(cornerRadius: 5))
                ForEach(origins, id: \.key) { o in
                    HStack {
                        Text(m.meshName(o.key)).foregroundStyle(CP.tier(m.meshTier(o.key)))
                        Spacer()
                        Text("\(MeshStats.short(o.value)) · \(Int((Double(o.value) / Double(total) * 100).rounded()))%").font(CP.mono(12)).foregroundStyle(CP.soft)
                    }
                    .font(.system(size: 13))
                }
            }
        }
        .cpPanel(padding: 12)
    }
}

// ---- sessions by device ----------------------------------------------------------------------------

/// A lane per device that started conversations, a cell per turn coloured by the tier that answered; then the list.
struct SessionsView: View {
    @Environment(ChatModel.self) private var m
    let range: MeshRange

    var body: some View {
        let stats = m.meshStats(range)
        let origins = Array(Set(stats.sessions.map(\.origin))).sorted { a, b in a == m.device ? true : b == m.device ? false : a < b }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    CPLabel(text: "Where sessions started · a cell is a turn")
                    if origins.isEmpty {
                        Text("No conversations in this range.").font(.footnote).foregroundStyle(CP.muted)
                    } else {
                        Lanes(stats: stats, origins: origins)
                    }
                    HStack(spacing: 12) {
                        ForEach(["T0", "T1", "T4"], id: \.self) { t in
                            HStack(spacing: 4) { Rectangle().fill(CP.tier(t)).frame(width: 8, height: 8); Text(t) }
                        }
                        Text("cell = answered by")
                    }
                    .font(CP.mono(11)).foregroundStyle(CP.muted)
                }
                .cpPanel(padding: 12)

                VStack(spacing: 0) {
                    ForEach(stats.sessions) { s in
                        Button {
                            m.openSession(s.id)
                            withAnimation { m.screen = 0 }
                        } label: { SessionRow(s: s) }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 4)
                .background(CP.panel.opacity(0.9), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(CP.line))
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .background(CPGrid())
        .navigationTitle("Sessions by device")
        .cpBar()
    }

    private struct Lanes: View {
        @Environment(ChatModel.self) private var m
        let stats: MeshStats
        let origins: [String]

        var body: some View {
            let laneH: CGFloat = 46
            // From the first turn in the range to now, so a busy hour is not squeezed into a sliver of the day.
            let from = min(stats.sessions.map(\.start).min() ?? stats.since, stats.now - 600)
            VStack(alignment: .leading, spacing: 4) {
                Canvas { ctx, size in
                    let span = max(1, stats.now - from)
                    let usable = size.width - 8
                    let x = { (ts: Double) -> CGFloat in usable * CGFloat((ts - from) / span) }
                    for (i, o) in origins.enumerated() {
                        let top = CGFloat(i) * laneH
                        ctx.draw(Text(m.meshName(o)).font(.system(size: 12)).foregroundColor(CP.tier(m.meshTier(o))),
                                 at: CGPoint(x: 0, y: top + 7), anchor: .leading)
                        let y = top + 30
                        var p = Path(); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
                        ctx.stroke(p, with: .color(CP.line), lineWidth: 1)
                        // A session's turns sit side by side from its first turn, so short sessions stay visible.
                        for s in stats.sessions where s.origin == o {
                            for (k, t) in s.tiers.enumerated() {
                                let r = CGRect(x: min(usable - 8, x(s.start) + CGFloat(k) * 9), y: y - 8, width: 8, height: 16)
                                ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(CP.tier(t)))
                            }
                        }
                    }
                    var now = Path(); now.move(to: CGPoint(x: size.width - 2, y: 14)); now.addLine(to: CGPoint(x: size.width - 2, y: size.height))
                    ctx.stroke(now, with: .color(CP.link.opacity(0.6)), lineWidth: 1)
                }
                .frame(height: CGFloat(origins.count) * laneH)
                HStack {
                    Text(Date(timeIntervalSince1970: from).formatted(date: stats.range == .week ? .abbreviated : .omitted, time: .shortened))
                    Spacer()
                    Text("now").foregroundStyle(CP.link)
                }
                .font(CP.mono(11)).foregroundStyle(CP.dim)
            }
        }
    }

    private struct SessionRow: View {
        @Environment(ChatModel.self) private var m
        let s: SessionStats

        var body: some View {
            let phone = s.origin == m.device
            HStack(spacing: 12) {
                Image(systemName: phone ? "iphone" : "laptopcomputer").font(.system(size: 16))
                    .foregroundStyle(CP.tier(m.meshTier(s.origin))).frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.title.isEmpty ? "(untitled)" : s.title).font(.system(size: 13)).foregroundStyle(CP.text).lineLimit(1)
                    Text(meta).font(CP.mono(11)).foregroundStyle(CP.muted).lineLimit(1)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(MeshStats.short(s.work)).font(CP.mono(13, .medium)).foregroundStyle(CP.text)
                    Text(chip).font(CP.mono(11)).foregroundStyle(chipColour)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(chipColour.opacity(0.6)))
                }
            }
            .frame(minHeight: 60)
            .overlay(alignment: .bottom) { Rectangle().fill(Color(UIColor(hex: 0x121922))).frame(height: 1) }
            .contentShape(Rectangle())
            .accessibilityIdentifier("meshSession")
        }

        private var meta: String {
            let when = Date(timeIntervalSince1970: s.end).formatted(date: .omitted, time: .shortened)
            var parts = [when, "\(s.tiers.count) turn\(s.tiers.count == 1 ? "" : "s")"]
            if s.origin != m.device { parts.append(m.meshName(s.origin)) }
            if s.isPrivate { parts.append("private") }
            if s.web { parts.append("web") }
            return parts.joined(separator: " · ")
        }

        private var chip: String { var seen = Set<String>(); return s.tiers.filter { seen.insert($0).inserted }.joined(separator: " ") }
        private var chipColour: Color { s.tiers.contains("T4") ? CP.cloud : s.isPrivate ? CP.mesh : CP.muted }
    }
}

// ---- one link --------------------------------------------------------------------------------------

/// One line of the map: tokens each way, how it went, whether the link is encrypted, and every turn on it with the
/// router's reasons.
struct LinkView: View {
    @Environment(ChatModel.self) private var m
    let link: MeshLink
    let range: MeshRange
    @State private var picked: String? = nil

    var body: some View {
        let turns = (m.meshStats(range).links[link] ?? []).reversed().map { $0 }
        let tokens = turns.reduce(TokenCount()) { var a = $0; a += $1.tokens; return a }
        let secs = turns.compactMap(\.seconds)
        let selected = turns.first { $0.id == picked } ?? turns.first
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    End(device: link.origin)
                    VStack(spacing: 3) {
                        Text("\(MeshStats.short(tokens.input - tokens.cached)) in ▶").font(CP.mono(11))
                        Rectangle().fill(CP.tier(m.meshTier(link.node))).frame(height: 4).clipShape(Capsule())
                        Text("◀ \(MeshStats.short(tokens.output)) out").font(CP.mono(11))
                    }
                    .foregroundStyle(CP.tier(m.meshTier(link.node)))
                    End(device: link.node)
                }
                .cpPanel()

                HStack(spacing: 8) {
                    Stat(value: "\(turns.count)", label: "turns")
                    Stat(value: MeshStats.short(turns.reduce(0) { $0 + $1.work }), label: "tokens")
                    Stat(value: secs.isEmpty ? "—" : String(format: "%.1fs", secs.reduce(0, +) / Double(secs.count)), label: "avg time")
                    Stat(value: "\(turns.filter(\.isPrivate).count)/\(turns.count)", label: "private")
                }

                Security(link: link, turns: turns)

                VStack(alignment: .leading, spacing: 0) {
                    CPLabel(text: "Trace · tap a turn").padding(.vertical, 6)
                    ForEach(turns) { t in
                        Button { picked = t.id } label: {
                            HStack(spacing: 8) {
                                Text(Date(timeIntervalSince1970: t.ts).formatted(date: .omitted, time: .shortened)).font(CP.mono(11)).foregroundStyle(CP.muted)
                                    .frame(width: 58, alignment: .leading)
                                Text(t.isPrivate ? "private" : "public").font(CP.mono(11))
                                    .foregroundStyle(t.isPrivate ? CP.mesh : CP.muted)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .overlay(RoundedRectangle(cornerRadius: 5).stroke((t.isPrivate ? CP.mesh : CP.faint).opacity(0.7)))
                                Text(t.question.isEmpty ? "(no question)" : t.question).font(.system(size: 12)).foregroundStyle(CP.soft).lineLimit(1)
                                Spacer(minLength: 4)
                                Text("\(MeshStats.short(t.tokens.input - t.tokens.cached))→\(MeshStats.short(t.tokens.output))").font(CP.mono(11)).foregroundStyle(CP.text)
                            }
                            .padding(.horizontal, 6).frame(minHeight: 44)
                            .background(t.id == selected?.id ? Color(UIColor(hex: 0x0E1A2C)) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if turns.isEmpty { Text("No turns on this link in this range.").font(.footnote).foregroundStyle(CP.muted).padding(.vertical, 8) }
                }
                .cpPanel(padding: 12)

                if let s = selected {
                    VStack(alignment: .leading, spacing: 6) {
                        CPLabel(text: "Why it went here · \(Date(timeIntervalSince1970: s.ts).formatted(date: .omitted, time: .shortened))")
                        ForEach(Array(s.route.enumerated()), id: \.offset) { _, line in
                            Text(line.hasPrefix("route  ") ? String(line.dropFirst(7)) : line).font(CP.mono(11)).foregroundStyle(CP.mesh)
                        }
                        Text(cost(s)).font(CP.mono(11)).foregroundStyle(CP.muted)
                    }
                    .cpPanel(padding: 12)

                    Button {
                        m.openSession(s.session)
                        withAnimation { m.screen = 0 }
                    } label: {
                        Text("Open conversation").font(.subheadline).foregroundStyle(CP.text).frame(maxWidth: .infinity, minHeight: 44)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(CP.faint))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .background(CPGrid())
        .navigationTitle("\(m.meshName(link.origin)) → \(m.meshName(link.node))")
        .cpBar()
    }

    private func cost(_ t: Turn) -> String {
        var s = "\(Router.grouped(t.tokens.input)) in"
        if t.tokens.cached > 0 { s += " (\(Router.grouped(t.tokens.cached)) cached)" }
        s += " · \(Router.grouped(t.tokens.output)) out"
        if t.tokens.estimated { s = "~" + s }
        if let sec = t.seconds { s += String(format: " · %.1f s", sec) }
        return s
    }

    private struct End: View {
        @Environment(ChatModel.self) private var m
        let device: String
        var body: some View {
            let tier = m.meshTier(device)
            Text("\(tier) \(m.meshName(device))").font(.system(size: 12, weight: .medium)).foregroundStyle(CP.tier(tier)).lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(CP.deep(tier).opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(CP.tier(tier)))
        }
    }

    private struct Stat: View {
        let value: String
        let label: String
        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(CP.mono(18, .medium)).foregroundStyle(CP.text).lineLimit(1).minimumScaleFactor(0.7)
                Text(label).font(.system(size: 11)).foregroundStyle(CP.muted)
            }
            .padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
            .background(CP.panel.opacity(0.9), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(CP.line))
        }
    }

    /// What protects the link: the phone's own model never leaves it; Gemini only gets approved text; a Mac over
    /// plain HTTP is readable on the network.
    private struct Security: View {
        @Environment(ChatModel.self) private var m
        let link: MeshLink
        let turns: [Turn]

        var body: some View {
            let (icon, text, colour) = describe()
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 14))
                Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(colour)
            .padding(.horizontal, 12).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
            .background(colour.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(colour.opacity(0.45)))
        }

        private func describe() -> (String, String, Color) {
            if link.node == "frontier" {
                let bytes = turns.reduce(0) { $0 + $1.leftBytes }
                return ("exclamationmark.shield", "Left the mesh with your approval: \(Router.grouped(bytes)) bytes, only the text you saw.", CP.cloud)
            }
            if link.origin != m.device {
                return ("arrow.triangle.2.circlepath", "Turns asked on \(m.meshName(link.origin)), synced here through memory.", CP.muted)
            }
            let url = m.machines.first { $0.device == link.node }?.node.url ?? ""
            if url.hasPrefix("https") { return ("lock.shield", "HTTPS inside your paired mesh.", CP.phone) }
            return ("exclamationmark.shield", "Plain HTTP on an open mesh: devices on this network could read it.", CP.cloud)
        }
    }
}
