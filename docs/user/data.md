# Where your data lives

Everything is in `~/Library/Application Support/Voice`:

- `recordings/`: each dictation as `<ms>.wav`, 16 kHz mono.
- `calls/`: each online call as `<ms>-<id>.wav` while it records, then `.m4a`.
- `voice.sqlite`: dictations, online calls with their segments and tags, and one full-text index over both.
- `models/`: the speech models.
- `mcp-token`: the MCP token, readable by you only.

Settings are in the app's preferences (`io.github.spashii.voice`). Keep history set to 30 days deletes dictations and online calls older than that, with their audio. It never deletes a call that is still recording or being transcribed.

Voice uses the microphone while you dictate or record an online call. To paste, it puts the text on the clipboard, pastes, and half a second later puts back what was there. Whisper runs on the GPU, and the fix step talks to Ollama on `127.0.0.1`.
