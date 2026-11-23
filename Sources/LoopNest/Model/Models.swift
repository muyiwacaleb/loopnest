import Foundation
import AppKit

let eqFrequencies: [Float] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
let eqBandLabels = ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

let callApps: Set<String> = [
    "com.apple.FaceTime", "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams",
    "com.hnc.Discord", "com.tinyspeck.slackmacgap", "com.skype.skype", "com.apple.iChat",
    "com.cisco.webexmeetingsapp", "com.google.Chrome.app.meet"
]

/// Insert effects that can sit on one channel (the same effects also exist on the master mix).
struct ChannelFX: Codable, Equatable {
    var filterOn = false
    var hpHz: Float = 80
    var lpHz: Float = 8000
    var distOn = false
    var distPreset = 0
    var distMix: Float = 30
    var distPregain: Float = -6
    var pitchOn = false
    var pitchCents: Float = 0
    var glueOn = false
    var glueThreshold: Float = -20
    var glueRatio: Float = 3
    var glueGain: Float = 2
    init() {}
    init(from m: MasterSettings) {
        filterOn = m.filterOn; hpHz = m.hpHz; lpHz = m.lpHz
        distOn = m.distOn; distPreset = m.distPreset; distMix = m.distMix; distPregain = m.distPregain
        pitchOn = m.pitchOn; pitchCents = m.pitchCents
        glueOn = m.glueOn; glueThreshold = m.glueThreshold; glueRatio = m.glueRatio; glueGain = m.glueGain
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        filterOn = try c.decodeIfPresent(Bool.self, forKey: .filterOn) ?? false
        hpHz = try c.decodeIfPresent(Float.self, forKey: .hpHz) ?? 80
        lpHz = try c.decodeIfPresent(Float.self, forKey: .lpHz) ?? 8000
        distOn = try c.decodeIfPresent(Bool.self, forKey: .distOn) ?? false
        distPreset = try c.decodeIfPresent(Int.self, forKey: .distPreset) ?? 0
        distMix = try c.decodeIfPresent(Float.self, forKey: .distMix) ?? 30
        distPregain = try c.decodeIfPresent(Float.self, forKey: .distPregain) ?? -6
        pitchOn = try c.decodeIfPresent(Bool.self, forKey: .pitchOn) ?? false
        pitchCents = try c.decodeIfPresent(Float.self, forKey: .pitchCents) ?? 0
        glueOn = try c.decodeIfPresent(Bool.self, forKey: .glueOn) ?? false
        glueThreshold = try c.decodeIfPresent(Float.self, forKey: .glueThreshold) ?? -20
        glueRatio = try c.decodeIfPresent(Float.self, forKey: .glueRatio) ?? 3
        glueGain = try c.decodeIfPresent(Float.self, forKey: .glueGain) ?? 2
    }
    var activeNames: [String] {
        var n: [String] = []
        if filterOn { n.append("Filter") }; if distOn { n.append("Distortion") }
        if pitchOn { n.append("Pitch") }; if glueOn { n.append("Glue") }
        return n
    }
}

/// A reminder the user keeps for one hardware input. LoopNest cannot read or switch phantom power itself.
struct PhantomInfo: Codable, Equatable {
    var expected = false
    var micType = 0            // 0 not sure, 1 condenser, 2 dynamic, 3 ribbon
    var note = ""
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        expected = try c.decodeIfPresent(Bool.self, forKey: .expected) ?? false
        micType = try c.decodeIfPresent(Int.self, forKey: .micType) ?? 0
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
    static let typeNames = ["Not sure", "Condenser", "Dynamic", "Ribbon"]
}

struct StripSettings: Codable, Equatable {
    var fx = ChannelFX()
    var gainDB: Float = 0          // fader, -60 ... +6 (-60 == -inf)
    var panL: Float = -1           // where the left signal sits, -1 (hard left) ... +1 (hard right)
    var panR: Float = 1            // where the right signal sits
    var mute = false
    var solo = false
    var eqEnabled = true
    var eq: [Float] = Array(repeating: 0, count: 10)   // dB, +-12
    var compEnabled = false
    var compThreshold: Float = -20 // dB
    var compRatio: Float = 4
    var compMakeup: Float = 0      // dB
    var compAttack: Float = 0.01   // s
    var compRelease: Float = 0.15  // s
    var group: Int? = nil          // 0..3 => A..D
    var reverbSend: Float = 0      // 0...1
    var sub1: Float = 0            // send to Submix 1, 0...1
    var sub2: Float = 0            // send to Submix 2, 0...1
    var linkTo: String? = nil      // another channel whose fader, mute and solo move together with this one
    var subOnly = false            // heard only through its submix(es), not directly
    var delaySend: Float = 0       // 0...1
    var duckable = true
    var armed = false              // record separately
    var width: Float = 1           // stereo width: 0 mono, 1 as is, 2 extra wide
    var invertL = false            // flip the phase of the left signal
    var invertR = false            // flip the phase of the right signal
    var modMode = 0                // 0 off, 1 chorus, 2 flanger, 3 phaser, 4 tremolo
    var modRate: Float = 0.6
    var modDepth: Float = 0.5
    var modMix: Float = 0.5
    var label = ""                 // your own channel name (empty = the app / input name)
    var colorIdx = 0               // 0 none, 1...8 colour tag
    var toMonitor = true           // heard on your speakers / headphones
    var toStream = true            // sent to the LoopNest Stream device (OBS, vMix, ...)
    var toRecord = true            // included in the Recording mix
    var toMeeting = false          // sent to the LoopNest Meeting device (the second mix, for calls)
    var pluginID: String? = nil    // an Audio Unit effect inserted on this channel (nothing until you choose one)
    var pluginState: Data? = nil   // that plug-in's own saved settings
    var pluginBypass = false
    // Voice tools
    var hpfOn = false
    var satOn = false              // tape-style saturation
    var satDrive: Float = 0.3
    var exOn = false               // exciter (adds brightness)
    var exAmount: Float = 0.3
    var tsOn = false               // transient shaper
    var tsAttack: Float = 0        // -1 softer ... +1 punchier
    var tsSustain: Float = 0       // -1 shorter ... +1 longer
    var mbOn = false               // three-band compressor
    var mbThreshold: Float = -24
    var mbRatio: Float = 3
    var agcOn = false              // automatic gain: steady voice level
    var agcTarget: Float = -18     // dBFS
    var hpfFreq: Float = 80
    var nrOn = false
    var nrAmount: Float = 0.5
    var gateOn = false
    var gateThreshold: Float = -50
    var gateFloor: Float = -45
    var deessOn = false
    var deessAmount: Float = 0.5
    var delayMs: Float = 0         // sync delay
    var outputUID: String? = nil   // play this channel through another output device
    var micMuteKey = false

    static let minDB: Float = -60

    /// Takes the sound-shaping settings from a saved preset but keeps this channel's own identity and routing.
    mutating func applyPreset(_ p: StripSettings) {
        var n = p
        n.linkTo = linkTo; n.label = label; n.colorIdx = colorIdx; n.group = group; n.outputUID = outputUID
        n.mute = mute; n.solo = solo; n.gainDB = gainDB; n.panL = panL; n.panR = panR
        n.toMonitor = toMonitor; n.toStream = toStream; n.toRecord = toRecord; n.toMeeting = toMeeting; n.armed = armed
        self = n
    }

    /// One-click voice chain for a streaming microphone.
    mutating func applyStreamerVoice() {
        hpfOn = true; hpfFreq = 90
        nrOn = true; nrAmount = 0.5
        gateOn = true; gateThreshold = -48; gateFloor = -40
        deessOn = true; deessAmount = 0.5
        eqEnabled = true
        eq = [-6, -4, -1, 0, 0, 1, 2, 3, 1, 0]       // trim rumble, add presence
        compEnabled = true; compThreshold = -22; compRatio = 3; compMakeup = 4; compAttack = 0.006; compRelease = 0.12
    }
    var linearGain: Float { gainDB <= StripSettings.minDB ? 0 : pow(10, gainDB / 20) }
}

struct MasterSettings: Codable, Equatable {
    var gainDB: Float = 0
    var pluginID: String? = nil     // an Audio Unit effect inserted on the master (nothing until you choose one)
    var pluginState: Data? = nil
    var pluginBypass = false
    var eq: [Float] = Array(repeating: 0, count: 10)
    var eqEnabled = true
    var limiterOn = false           // nothing is on until you turn it on
    var mute = false
    var dim = false
    var mono = false
    var pan: Float = 0              // master left/right pan (what you hear), -1 ... 1
    var streamPan: Float = 0        // stream mix left/right pan, -1 ... 1
    var reverbOn = false
    var reverbMix: Float = 0.5      // return level
    var reverbPreset: Int = 4       // AVAudioUnitReverbPreset raw (mediumHall); 100-104 = built-in convolution rooms, 99 = your own impulse response file
    var reverbIRPath: String? = nil
    var delayOn = false
    var delayTime: Float = 0.35     // s
    var delayFeedback: Float = 30   // %
    var delayMix: Float = 0.5       // return level
    var duckingOn = false
    var duckAmountDB: Float = -12
    var outputUID: String? = nil    // nil == system default
    // Extra master FX
    var filterOn = false
    var hpHz: Float = 80
    var lpHz: Float = 8000
    var distOn = false
    var distPreset = 0              // index into distortionPresets
    var distMix: Float = 30         // % wet
    var distPregain: Float = -6     // dB
    var pitchOn = false
    var pitchCents: Float = 0
    var glueOn = false
    var glueThreshold: Float = -20
    var glueRatio: Float = 3
    var glueGain: Float = 2
    var streamGainDB: Float = 0
    var streamMute = false
    // Stream-only processing (what OBS / vMix receive)
    var streamEQOn = false
    var streamEQ: [Float] = Array(repeating: 0, count: 10)
    var streamCompOn = false
    var streamCompThreshold: Float = -18
    var streamCompRatio: Float = 3
    var streamLimiterOn = false
    var streamPreGainDB: Float = 0
    var streamDelayMs: Float = 0      // delays what goes to OBS / vMix / Zoom (to line up with a slow camera, for example)
    var monitorDelayMs: Float = 0     // delays what you hear on the master output (to line up with the stream or a slow display)
    var loudnessTarget: Float = -14
    // Music ducking under your voice
    var micDuckOn = false
    var micDuckDB: Float = -10
    var micDuckThreshold: Float = -45
    // VCA group faders A-D: scale every channel in the group without moving their own faders
    var vcaDB: [Float] = [0, 0, 0, 0]
    var subDB: [Float] = [0, 0]          // submix bus faders
    var subMute: [Bool] = [false, false]
    var subOutUID: [String] = ["", ""]          // per submix: also play on this output device ("" = none)
    var subOutOnly: [Bool] = [false, false]     // per submix: play only on that device, not in the main, stream or recording mix
    var subTone: [Float] = [0, 0, 0, 0, 0, 0]   // per submix: low, mid, high gain in dB (submix 1 first)
    var subCompOn: [Bool] = [false, false]
    var subCompThreshold: [Float] = [-18, -18]
    var vcaMute: [Bool] = [false, false, false, false]
}

struct EQPreset: Identifiable {
    let id: String
    let gains: [Float]
    var name: String { id }
    static let all: [EQPreset] = [
        .init(id: "Flat", gains: [0,0,0,0,0,0,0,0,0,0]),
        .init(id: "Bass lift", gains: [6,5,4,2,0,0,0,0,0,0]),
        .init(id: "Voice clarity", gains: [-4,-3,-2,0,1,3,4,3,1,0]),
        .init(id: "Podcast", gains: [-6,-3,0,2,3,3,2,1,-1,-2]),
        .init(id: "Night", gains: [3,2,0,-1,-1,0,-1,-2,-3,-4]),
        .init(id: "Treble boost", gains: [0,0,0,0,0,1,2,4,5,6]),
        .init(id: "Loudness", gains: [5,4,2,0,-1,-1,0,2,4,5]),
    ]
}

/// When a scene should recall itself: at a time of day, and/or when a named app starts playing.
struct SceneRule: Codable, Equatable {
    var timeOn = false
    var hour = 9
    var minute = 0
    var appOn = false
    var appMatch = ""
    var devOn = false            // recall when a matching audio device is plugged in or removed
    var devMatch = ""
    var devRemoved = false       // false: when it is plugged in, true: when it is removed
    init() {}
    init(from d: Decoder) throws {   // rules saved before the device trigger existed have no such fields
        let c = try d.container(keyedBy: CodingKeys.self)
        timeOn = try c.decodeIfPresent(Bool.self, forKey: .timeOn) ?? false
        hour = try c.decodeIfPresent(Int.self, forKey: .hour) ?? 9
        minute = try c.decodeIfPresent(Int.self, forKey: .minute) ?? 0
        appOn = try c.decodeIfPresent(Bool.self, forKey: .appOn) ?? false
        appMatch = try c.decodeIfPresent(String.self, forKey: .appMatch) ?? ""
        devOn = try c.decodeIfPresent(Bool.self, forKey: .devOn) ?? false
        devMatch = try c.decodeIfPresent(String.self, forKey: .devMatch) ?? ""
        devRemoved = try c.decodeIfPresent(Bool.self, forKey: .devRemoved) ?? false
    }
}

struct MixScene: Codable, Identifiable {
    var id = UUID()
    var name: String
    var strips: [String: StripSettings]
    var master: MasterSettings
}

// MARK: Loopback-style routing model
enum SourceKind: String, Codable { case app, device }

struct RouteSource: Codable, Identifiable, Hashable {
    var id = UUID()
    var kind: SourceKind
    var ref: String            // bundle id (app) or device uid
    var name: String
    var volumeDB: Float = 0
    var mute = false
    var enabled = true         // on/off toggle without deleting
}

struct Wire: Codable, Identifiable, Hashable {
    var id = UUID()
    var sourceID: UUID
    var srcChannel: Int        // 0 = L, 1 = R of the stereo source
    var destChannel: Int       // 0-based channel on the virtual device
}

struct VirtualDeviceConfig: Codable, Identifiable {
    var id = UUID()
    var slot: Int              // which driver slot (0..<8)
    var name: String
    var channels: Int = 2
    var sources: [RouteSource] = []
    var wires: [Wire] = []
    var monitorUID: String? = nil
    var monitorOn = false
    var muteOriginalApps = false    // silence source apps on the system output
    var volumeDB: Float = 0
    var passThru = false
    var enabled = true
}

/// A hardware input (system mic, USB mic, audio-interface channels) shown as a mixer channel.
struct InputConfig: Codable, Identifiable, Hashable {
    var uid: String
    var name: String
    var offset: Int            // first channel (0-based)
    var mono: Bool             // true: use one channel on both sides
    var backupUID: String? = nil   // used automatically if this device disappears
    var id: String { "in:\(uid):\(offset):\(mono ? "m" : "s")" }
    var label: String { mono ? "\(name) · In \(offset + 1)" : "\(name) · In \(offset + 1)+\(offset + 2)" }
}

struct MIDIBinding: Codable, Hashable {
    var channel: Int
    var number: Int
    var isNote: Bool
    var target: String         // "fader:<stripID>", "mute:<id>", "solo:<id>", "master", "dim", "deck:A:play" ...
}
