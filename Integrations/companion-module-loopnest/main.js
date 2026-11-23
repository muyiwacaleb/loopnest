// Bitfocus Companion module for LoopNest. Talks to LoopNest's local web address (default 127.0.0.1:9123).
// Turn on Settings > Remote control in LoopNest first. NOT yet tried inside Companion (see INTEGRATIONS.md).
const { InstanceBase, Regex, runEntrypoint, combineRgb } = require('@companion-module/base')

class LoopNestInstance extends InstanceBase {
  async init(config) {
    this.config = config
    this.state = { strips: [], scenes: [], dim: false, mono: false, streamMute: false, submixMute: [false, false] }
    this.updateStatus('connecting')
    this.setActionDefinitions(this.actions())
    this.setFeedbackDefinitions(this.feedbacks())
    this.startPolling()
  }
  async destroy() { if (this.timer) clearInterval(this.timer) }
  async configUpdated(config) { this.config = config; this.startPolling() }
  getConfigFields() {
    return [
      { type: 'textinput', id: 'host', label: 'LoopNest address', width: 8, default: '127.0.0.1', regex: Regex.SOMETHING },
      { type: 'number', id: 'port', label: 'Port', width: 4, default: 9123, min: 1, max: 65535 },
    ]
  }
  base() { return `http://${this.config.host || '127.0.0.1'}:${this.config.port || 9123}` }
  async call(path) {
    try {
      const r = await fetch(this.base() + path)
      return await r.json()
    } catch (e) { return null }
  }
  startPolling() {
    if (this.timer) clearInterval(this.timer)
    const tick = async () => {
      const s = await this.call('/state')
      if (!s) { this.updateStatus('connection_failure', 'LoopNest is not answering. Is Remote control on?'); return }
      this.updateStatus('ok'); this.state = s
      this.checkFeedbacks()
    }
    tick(); this.timer = setInterval(tick, 500)
  }
  chan(name) {
    const n = String(name).toLowerCase()
    return this.state.strips.find((s) => s.name.toLowerCase() === n) || this.state.strips.find((s) => s.name.toLowerCase().startsWith(n))
  }
  actions() {
    const ch = { type: 'textinput', id: 'ch', label: 'Channel name (or the start of it)', default: 'Mic' }
    const path = (p) => async (a) => { await this.call(p(encodeURIComponent(a.options.ch || ''), a.options)) }
    return {
      mute: { name: 'Channel: mute / unmute', options: [ch], callback: path((c) => `/mute/${c}`) },
      solo: { name: 'Channel: solo', options: [ch], callback: path((c) => `/solo/${c}`) },
      pfl: { name: 'Channel: headphone listen', options: [ch], callback: path((c) => `/pfl/${c}`) },
      stream: { name: 'Channel: send to Stream on / off', options: [ch], callback: path((c) => `/stream/${c}`) },
      meeting: { name: 'Channel: send to Meeting on / off', options: [ch], callback: path((c) => `/meeting/${c}`) },
      monitor: { name: 'Channel: Monitor on / off', options: [ch], callback: path((c) => `/monitor/${c}`) },
      fader: { name: 'Channel: fader (0 to 1, about 0.91 is 0 dB)', options: [ch, { type: 'number', id: 'v', label: 'Level', min: 0, max: 1, default: 0.91, step: 0.01 }], callback: path((c, o) => `/fader/${c}/${o.v}`) },
      master: { name: 'Master fader (0 to 1)', options: [{ type: 'number', id: 'v', label: 'Level', min: 0, max: 1, default: 0.91, step: 0.01 }], callback: async (a) => { await this.call(`/master/${a.options.v}`) } },
      dim: { name: 'Dim', options: [], callback: async () => { await this.call('/dim') } },
      mono: { name: 'Mono', options: [], callback: async () => { await this.call('/mono') } },
      streammute: { name: 'Stream mix mute', options: [], callback: async () => { await this.call('/streammute') } },
      scene: { name: 'Recall scene', options: [{ type: 'textinput', id: 'name', label: 'Scene name', default: '' }], callback: async (a) => { await this.call(`/scene/${encodeURIComponent(a.options.name)}`) } },
      pad: { name: 'Soundboard pad (1 to 64)', options: [{ type: 'number', id: 'n', label: 'Pad', min: 1, max: 64, default: 1 }], callback: async (a) => { await this.call(`/pad/${a.options.n}`) } },
      stoppads: { name: 'Stop all pads', options: [], callback: async () => { await this.call('/pads') } },
    }
  }
  feedbacks() {
    const ch = { type: 'textinput', id: 'ch', label: 'Channel name', default: 'Mic' }
    const red = { bgcolor: combineRgb(200, 0, 0), color: combineRgb(255, 255, 255) }
    const green = { bgcolor: combineRgb(0, 150, 0), color: combineRgb(255, 255, 255) }
    const flag = (name, key, style) => ({ type: 'boolean', name, defaultStyle: style, options: [ch], callback: (f) => { const s = this.chan(f.options.ch); return !!(s && s[key]) } })
    return {
      muted: flag('Channel is muted', 'mute', red),
      soloed: flag('Channel is solo', 'solo', green),
      onStream: flag('Channel goes to Stream', 'stream', green),
      onMeeting: flag('Channel goes to Meeting', 'meeting', green),
      onMonitor: flag('Channel is monitored', 'monitor', green),
      dim: { type: 'boolean', name: 'Dim is on', defaultStyle: green, options: [], callback: () => !!this.state.dim },
      mono: { type: 'boolean', name: 'Mono is on', defaultStyle: green, options: [], callback: () => !!this.state.mono },
      streamMute: { type: 'boolean', name: 'Stream mix is muted', defaultStyle: red, options: [], callback: () => !!this.state.streamMute },
    }
  }
}
runEntrypoint(LoopNestInstance, [])
