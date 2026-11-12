# Dictate

Dictation and call recording for Mac. Dictate types what you say into any app and records your online calls with your side and theirs kept apart. It runs on your Mac, and no bot joins the call.

## What it does

- **Dictation in any app.** Press ``Option+` `` and talk, then press it again and the text lands where you were writing. If the app quits mid dictation, the next launch recovers it into your history.
- **You and the call, kept apart.** Dictate asks before it records. Your microphone and the call's audio are recorded separately, so every line is labeled Me or Call.
- **Retry unsure segments.** Whisper scores each part. Parts below a confidence threshold are decoded again, and Dictate keeps the better version. Fix the text before pasting sends the text to a model in Ollama to correct misheard words, and it is off until you turn it on.
- **Key terms.** Add the names Whisper gets wrong, spelled your way. Dictate suggests more from your corrections and adds nothing until you press Add.
- **Your agents can read it.** Claude Code or any MCP client can search your dictations and calls. Tools that record or change anything start off.

## Get it

Download Dictate from [spashii.github.io/dictate](https://spashii.github.io/dictate/), open the DMG and drag it to Applications. Activate it once with your email and a code. It is free during the beta.

## Requirements

Apple silicon and macOS 15 or later.

## Documentation

- [Activation](./docs/user/activation.md)
- [Dictation](./docs/user/dictation.md)
- [Online calls](./docs/user/online-calls.md)
- [Agents](./docs/user/agents.md)
- [Settings](./docs/user/settings.md)
- [Where your data lives](./docs/user/data.md)
- [Uninstall](./docs/user/uninstall.md)

Every MCP tool is in [docs/MCP.md](./docs/MCP.md).

## License

Source available under [FSL-1.1-MIT](LICENSE): you can read, change and run the code, but not offer it in a commercial product that competes with it. Each version becomes MIT two years after release, and versions up to 0.11.0 already are. Third-party licenses are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Website: [spashii.github.io/dictate](https://spashii.github.io/dictate/)
