# Where your data lives

Everything is in `~/Library/Application Support/Dictate`:

- `recordings/`: each dictation as `<ms>.wav`, 16 kHz mono.
- `calls/`: each online call as `<ms>-<id>.wav` while it records, then `.m4a`.
- `voice.sqlite`: dictations, online calls with their segments and tags, and one full-text index over both.
- `models/`: the speech models.
- `mcp-token`: the MCP token, readable by you only.

Settings are in the app's preferences (`io.github.spashii.voice`). Keep history set to 30 days deletes dictations and online calls older than that, with their audio. It never deletes a call that is still recording or being transcribed.

Dictate uses the microphone while you dictate or record an online call. To paste, it puts the text on the clipboard, pastes, and half a second later puts back what was there. Whisper runs on the GPU, and Fix the text before pasting talks to Ollama on `127.0.0.1`.

Updates. Dictate uses Sparkle to check for updates. A check asks apps.firstversion.in for the list of updates and tells it which version of Dictate you have. The server counts checks by app, version and country and never stores your IP address. Updates download from dictate.firstversion.in. The speech models download once from huggingface.co.

Activation. Dictate keeps one item in your login Keychain, "Dictate activation": a token signed by the Dictate site. It holds your signup id (a random code that points to your email in my list), a random number made on this Mac, and the date. Dictate checks the signature on this Mac and does not send the token anywhere.
