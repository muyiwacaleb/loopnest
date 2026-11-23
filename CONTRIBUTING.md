# Contributing to LoopNest

Thank you for extending LoopNest. Start with [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/INSTALL.md](docs/INSTALL.md).

## Set up
`xcode-select --install`, clone, then `./Build.command`. Run `./Test.command` before every pull request: all checks must pass.

## What a good change looks like
- Small and focused; explains what it does in plain words.
- Adds a check to `Sources/LoopNest/Audio/SelfTest.swift` when it touches audio maths, models or patchbay logic.
- Updates [STATUS.md](STATUS.md) honestly: say whether the change is **built**, **self-tested**, **verified on screen / by ear**, or **untested**. Do not mark something working that you did not try.
- Keeps UI text in plain words, no abbreviations.
- Follows the rules in the architecture document (audio-thread safety, pause the engine before graph changes, defaults for new fields).

## Testing the parts a script cannot
Self-tests cover DSP and logic only. Please test by hand and note it in the pull request: sound reaches OBS/Zoom through the virtual devices, device unplug/replug, sample-rate changes, Safe Mode.

## Reporting a bug
Health page > Export diagnostic report, and attach it. Crash logs are in `~/Library/Logs/DiagnosticReports`.

## Good first areas
See the "Not built" list in STATUS.md: per-submix reverb, delay compensation for extra outputs, Meeting-mix fader/meter/EQ, VST3/AAX hosting (large), and the open OBS issue listed under Known issues.
