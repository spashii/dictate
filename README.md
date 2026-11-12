# Dictate

Live transcripts of your online calls, made on your Mac. Dictate writes down Zoom, Meet, Teams and Discord calls as they happen, with you and the other side kept apart. Your agents can read along. It does fast dictation too.

## Why

I wanted really fast transcription on my own Whisper pipeline, one I could hack on. [Handy](https://handy.computer) and [OpenSuperWhisper](https://github.com/Starmel/OpenSuperWhisper) are my favorites and I learned a lot from them, but I wanted something simpler. Dictate also hears both sides of an online call, so it writes down you and them separately.

## What it does

- **Online calls, both sides apart.** Your microphone is Me and the call app's sound is Call. Dictate asks when an online call starts, or press ``Option+Shift+` ``.
- **Your agents read along.** Claude Code and other agents follow an online call live and search past ones over MCP.
- **No key throws a recording away.** The audio is on disk as you speak. After a crash or a quit, the next launch transcribes it.
- **Dictation.** Press ``Option+` `` in any text field, talk, and press it again. Whisper large v3 turbo runs on your Mac with your key terms in its prompt, and Dictate decodes the segments it's unsure of a second time and shows you what each retry changed.

## Install

Get the signed build by email at [spashii.github.io/dictate](https://spashii.github.io/dictate/), open the DMG, and drag Dictate to Applications. Dictate opens its window on Setup with three steps: allow the microphone, allow Accessibility so it can paste into other apps, and download the speech model (1.6 GB, from Hugging Face). After that it opens at login and updates itself.

## Requirements

Apple silicon and macOS 15 or later. Optional:

- [Ollama](https://ollama.com), for the fix step.

## Some notes

Dictate is in beta. Expect bugs, and report them at [github.com/spashii/dictate/issues](https://github.com/spashii/dictate/issues).

## Privacy

Your audio never leaves your Mac. You activate each Mac once with your email, in your browser; your email is used to send your one-time activation code. Dictate uses Sparkle for updates: a check tells the update server your Dictate version, and the server counts checks by app, version and country and never stores your IP address. The speech model downloads once. The MCP server for agents listens on this Mac only and answers nothing without its token.

## Documentation

- [Dictation](./docs/user/dictation.md)
- [Online calls](./docs/user/online-calls.md)
- [Agents](./docs/user/agents.md)
- [Settings](./docs/user/settings.md)
- [Where your data lives](./docs/user/data.md)
- [Uninstall](./docs/user/uninstall.md)

Every MCP tool is in [docs/MCP.md](./docs/MCP.md).

## License

The code is source available under the [Functional Source License](LICENSE) (FSL-1.1-MIT): you can read it, change it and run it yourself, but not sell a competing copy. Each version becomes MIT two years after its release. Versions up to 0.11.0 were released under MIT and stay MIT. Dictate includes [whisper.cpp](https://github.com/ggml-org/whisper.cpp), [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts), [Sparkle](https://sparkle-project.org) and [BlendKit](https://github.com/spashii/blend) with the audio processing inside it. Their licenses are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
