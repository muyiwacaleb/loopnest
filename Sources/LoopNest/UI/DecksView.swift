import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// Two decks with a two-channel mixer between them, crossfader, and a library bar below.
struct DecksView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                DeckPanel(deck: app.deckA)
                VStack(spacing: 8) {
                    HStack(alignment: .top, spacing: 6) {
                        ChannelStripView(strip: app.deckA.strip)
                        ChannelStripView(strip: app.deckB.strip)
                    }
                    HStack(spacing: 6) {
                        Text("A").font(.system(size: 11, weight: .heavy)).foregroundColor(Theme.gold)
                        Slider(value: $app.crossfade, in: 0...1)
                        Text("B").font(.system(size: 11, weight: .heavy)).foregroundColor(Theme.gold)
                    }.frame(width: 214)
                    Text("CROSSFADER").font(.system(size: 8, weight: .bold)).foregroundColor(Theme.dim)
                }
                DeckPanel(deck: app.deckB)
                MasterStripView()
            }
            LibraryBar()
        }.padding(12)
    }
}

struct LibraryBar: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("LIBRARY").font(.system(size: 10, weight: .heavy)).foregroundColor(Theme.dim)
                Spacer()
                Button("Add tracks…") {
                    let p = NSOpenPanel(); p.allowedContentTypes = [.audio]; p.allowsMultipleSelection = true
                    if p.runModal() == .OK { for u in p.urls where !app.library.contains(u) { app.library.append(u) } }
                }.controlSize(.small)
            }
            ScrollView {
                VStack(spacing: 3) {
                    if app.library.isEmpty { Text("Add tracks, then send them to Deck A or B. (You can also use Load… on a deck.)").font(.caption).foregroundColor(Theme.dim) }
                    ForEach(app.library, id: \.self) { u in
                        HStack {
                            Image(systemName: "music.note").foregroundColor(Theme.purple)
                            Text(u.deletingPathExtension().lastPathComponent).font(.system(size: 12)).lineLimit(1)
                            Spacer()
                            Button("→ A") { app.deckA.load(url: u) }.controlSize(.mini)
                            Button("→ B") { app.deckB.load(url: u) }.controlSize(.mini)
                            Button { app.library.removeAll { $0 == u } } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                        }.padding(.horizontal, 8).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.strip))
                    }
                }
            }
        }
        .padding(10).frame(height: 130)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
    }
}

struct Waveform: View {
    let peaks: [Float]
    let progress: Double
    var body: some View {
        Canvas { ctx, size in
            let n = peaks.count
            guard n > 0 else {
                ctx.fill(Path(CGRect(x: 0, y: size.height / 2 - 0.5, width: size.width, height: 1)), with: .color(Theme.dim.opacity(0.5)))
                return
            }
            let w = size.width / CGFloat(n)
            for i in 0..<n {
                let h = max(1, CGFloat(peaks[i]) * size.height * 0.95)
                let played = Double(i) / Double(n) < progress
                ctx.fill(Path(CGRect(x: CGFloat(i) * w, y: (size.height - h) / 2, width: max(1, w - 0.5), height: h)),
                         with: .color(played ? Theme.gold : Theme.purple.opacity(0.8)))
            }
            ctx.fill(Path(CGRect(x: size.width * CGFloat(progress) - 1, y: 0, width: 2, height: size.height)), with: .color(.white))
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.well))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct JogWheel: View {
    @ObservedObject var deck: DJDeck
    @LState private var dragStart: Double?
    var body: some View {
        let angle = deck.position * 120
        ZStack {
            Circle().fill(RadialGradient(colors: [Color(white: 0.2), Color(white: 0.08)], center: .center, startRadius: 5, endRadius: 60))
            Circle().stroke(deck.isPlaying ? Theme.purple : Theme.dim.opacity(0.5), lineWidth: 3)
            Circle().stroke(Color.white.opacity(0.06), lineWidth: 1).padding(14)
            Rectangle().fill(Theme.gold).frame(width: 3, height: 22).offset(y: -38)
                .rotationEffect(.degrees(angle))
            Circle().fill(Theme.well).frame(width: 22, height: 22)
        }
        .frame(width: 100, height: 100)
        .gesture(DragGesture(minimumDistance: 1)
            .onChanged { g in
                if dragStart == nil { dragStart = deck.position }
                deck.seek(to: dragStart! + Double(g.translation.width) / 25)
            }
            .onEnded { _ in dragStart = nil })
        .help("Drag to scrub")
    }
}

struct DeckPanel: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var deck: DJDeck

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("DECK \(deck.id)").font(.system(size: 12, weight: .heavy, design: .rounded)).foregroundColor(Theme.gold)
                Text(deck.title).font(.system(size: 11)).lineLimit(1)
                Spacer()
                DeckPFLButton(strip: deck.strip)
                Button("Load…") { pick() }.controlSize(.small)
            }
            Waveform(peaks: deck.peaks, progress: deck.duration > 0 ? deck.position / deck.duration : 0)
                .frame(height: 64)
                .gesture(DragGesture(minimumDistance: 0).onChanged { _ in })
                .overlay(GeometryReader { g in
                    Color.clear.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        deck.seek(to: Double(max(0, min(1, v.location.x / g.size.width))) * deck.duration)
                    })
                })
            HStack {
                Text(time(deck.position)); Spacer(); Text("-" + time(max(0, deck.duration - deck.position)))
            }.font(.system(size: 10, design: .monospaced)).foregroundColor(Theme.dim)
            HStack(alignment: .center, spacing: 12) {
                JogWheel(deck: deck)
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        Button { deck.playPause() } label: {
                            Image(systemName: deck.isPlaying ? "pause.fill" : "play.fill").frame(width: 46)
                        }.buttonStyle(.borderedProminent).tint(Theme.purple)
                        Button { deck.seek(to: 0) } label: { Image(systemName: "backward.end.fill") }
                    }
                    HStack(spacing: 4) {
                        Button("IN") { deck.setLoopIn() }
                        Button("OUT") { deck.setLoopOut() }
                        Button("LOOP") { deck.toggleLoop() }.tint(deck.loopActive ? Theme.green : nil)
                        Button("✕") { deck.clearLoop() }
                    }.buttonStyle(.bordered).controlSize(.small)
                }
            }
            Text("HOT CUES — click to set / jump, ⌥-click to clear").font(.system(size: 8)).foregroundColor(Theme.dim)
            HStack(spacing: 5) {
                ForEach(0..<4, id: \.self) { i in
                    Button {
                        if NSEvent.modifierFlags.contains(.option) { deck.clearCue(i) } else { deck.cue(i) }
                    } label: {
                        Text(deck.cues[i].map { time($0) } ?? "\(i + 1)").font(.system(size: 10, weight: .bold)).frame(maxWidth: .infinity, minHeight: 22)
                    }.buttonStyle(.bordered).tint(deck.cues[i] != nil ? Theme.gold : .gray)
                }
            }
            HStack {
                Text("TEMPO").font(.system(size: 9)).foregroundColor(Theme.dim)
                Slider(value: $deck.tempo, in: 0.5...2)
                Text(String(format: "%+.1f%%", (deck.tempo - 1) * 100)).font(.system(size: 10, design: .monospaced)).frame(width: 52)
                Button("0") { deck.tempo = 1 }.controlSize(.mini)
            }
            Text("Key lock on: pitch stays the same when tempo changes.").font(.system(size: 8)).foregroundColor(Theme.dim)
        }
        .padding(12).frame(width: 300, height: 340, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
    }

    private func pick() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.audio]; p.allowsMultipleSelection = false
        if p.runModal() == .OK, let u = p.url { deck.load(url: u); if !app.library.contains(u) { app.library.append(u) } }
    }
    private func time(_ t: Double) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }
}


/// Pre-fader listen for a deck: hear it on the headphone output without changing what the stream or master get.
struct DeckPFLButton: View {
    @ObservedObject var strip: Strip
    var body: some View {
        PillButton(label: "PFL", on: strip.pfl, tint: Theme.green) { strip.pfl.toggle() }
            .frame(width: 52)
            .help("Listen to this deck on your headphone output (set in Stream, Headphones for PFL).")
    }
}
