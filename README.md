# Voice

Live transcripts of your online calls, made on your Mac. Voice writes down Zoom, Meet, Teams and Discord calls as they happen, with you and the other side kept apart. Your agents can read along. It does fast dictation too.

## Why

I wanted really fast transcription on my own Whisper pipeline, one I could hack on. [Handy](https://handy.computer) and [OpenSuperWhisper](https://github.com/Starmel/OpenSuperWhisper) are my favorites and I learned a lot from them, but I wanted something simpler. With [Blend Mic](https://spashii.github.io/blend/), Voice also hears both sides of an online call, so it writes down you and them separately.

## What it does

- **Online calls, both sides apart.** With a Blend Mic split mix, you're Me and everyone else is Call. Voice asks when an online call starts, or press ``Option+Shift+` ``.
- **Your agents read along.** Claude Code and other agents follow an online call live and search past ones over MCP.
- **No key throws a recording away.** The audio is on disk as you speak. After a crash or a quit, the next launch transcribes it.
- **Dictation.** Press ``Option+` `` in any text field, talk, and press it again. Whisper large v3 turbo runs on your Mac with your key terms in its prompt, and Voice decodes the segments it's unsure of a second time and shows you what each retry changed.

## Install

Download the DMG from the [latest release](https://github.com/spashii/voice/releases/latest), open it, and drag Voice to Applications. Or use Homebrew:

```sh
brew tap spashii/voice https://github.com/spashii/voice
brew trust spashii/voice
brew install --cask voice
```

Voice opens a Set Up Voice window with three steps: allow the microphone, allow Accessibility so it can paste into other apps, and download the speech model (1.6 GB, from Hugging Face). After that it opens at login and updates itself.

## Requirements

Apple silicon and macOS 15 or later. Optional:

- [Blend Mic](https://github.com/spashii/blend), for both sides of an online call. Without it Voice hears only your microphone.
- [Ollama](https://ollama.com), for the fix step.

## Some notes

Voice is in beta. Expect bugs, and report them at [github.com/spashii/voice/issues](https://github.com/spashii/voice/issues).

## Privacy

Your audio never leaves your Mac, and there are no accounts. Voice goes online only to download the speech model and to check for updates. The update server counts update checks by app, version and country and never stores your IP address. The MCP server for agents listens on this Mac only and answers nothing without its token.

## Documentation

- [Dictation](./docs/user/dictation.md)
- [Online calls with Blend Mic](./docs/user/online-calls.md)
- [Agents](./docs/user/agents.md)
- [Settings](./docs/user/settings.md)
- [Where your data lives](./docs/user/data.md)
- [Uninstall](./docs/user/uninstall.md)

Building from source? Start at [docs/DEVELOPMENT.md](./docs/DEVELOPMENT.md). How it works is in [docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md), and every MCP tool is in [docs/MCP.md](./docs/MCP.md).

## License

MIT, see [LICENSE](LICENSE). Voice includes [whisper.cpp](https://github.com/ggml-org/whisper.cpp), [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) and [Sparkle](https://sparkle-project.org). Their licenses are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
