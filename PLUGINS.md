# Plugin hosting: investigation (phase 6, section I)

Status: **Audio Unit hosting built 22 Nov** (insert slot per channel and on the master; see STATUS.md for what was and was not tested). VST3 and AAX are not planned.

The notes below are the original investigation.

## Audio Units (AU)
- macOS lets an app list installed AU effects with `AVAudioUnitComponentManager` and load one with `AVAudioUnit.instantiate(with:)`. The loaded unit is an `AVAudioNode`, so it can be attached into LoopNest's existing engine (for example between a channel's compressor and its fader, the same way the built-in effects are).
- Plugin windows use `requestViewController`, which returns a view that can be shown in a panel.
- Saved state is `fullState`, which can be stored with the scene or channel.
- Risks: a faulty plugin can crash the whole app, because it runs in LoopNest's process. Loading out-of-process (macOS 13+) is possible but plugins that do not support it fail to load. Some plugins also use more CPU than LoopNest's own effects, which matters for the low-resource goal.
- Verdict: **feasible**. Best first version: one AU "insert" slot per channel and one on the master, loaded out-of-process, bypassed automatically in Safe Mode, with a crash guard that turns the plugin off if it was loaded when LoopNest last crashed.

## VST3 / AAX
- VST3 needs Steinberg's SDK and a plugin-hosting layer that LoopNest does not have. Their licence and the amount of work (view embedding, parameter automation, bus layouts) make this a separate project. AAX only works inside Pro Tools.
- Verdict: **not planned**. AU covers the plugins that Logic users already have.

## What would have to be tested before shipping AU hosting
Loading and unloading while audio runs, sample-rate changes, plugin crashes, saving and restoring plugin state, and CPU cost. None of this has been done.
