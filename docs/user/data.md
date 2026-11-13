# Where your data lives

Everything is in `~/Library/Application Support/Dictate`:

- `recordings/`: each dictation as `<ms>.wav`, 16 kHz mono.
- `calls/`: each online call as `<ms>-<id>.wav` while it records, then `.m4a`. An imported file is kept here too: an audio file in its own format, a video as its audio only.
- `voice.sqlite`: dictations and online calls with their segments and tags. One full-text index covers both.
- `models/`: the speech models.
- `mcp-token`: the MCP token, readable by you only.

Settings are in the app's preferences (`io.github.spashii.voice`). The Data retention settings decide what Dictate deletes. By default it deletes audio after 7 days and history after 30 days.

Keep audio recordings has Until transcribed, 1 day, 7 days and Forever. Forever is there only while Developer mode is on. Until transcribed deletes the audio once the transcript is saved. If the transcription failed, the audio stays so it can be tried again.

Keep history has 7 days, 30 days and Forever. Deleting history removes the recording from History, search and agents. An imported file counts from the day you imported it. A call that is still recording or being transcribed is never deleted.

While Developer mode is on, nothing is deleted. Turning it off asks before it deletes anything, and Cancel keeps Developer mode on.

Dictate uses the microphone while you dictate or record an online call. To paste, it puts the text on the clipboard and pastes. Half a second later it puts back what was there. When Dictate itself is the app in front, the text stays on the clipboard and isn't pasted. Whisper runs on the GPU. Fix the text before pasting and the automatic call titles use the intelligence model you chose in the Model settings. That is Apple Intelligence on this Mac or Ollama on `127.0.0.1`. Nothing goes off this Mac.

Updates. Dictate uses Sparkle to check for updates. A check asks apps.firstversion.in for the list of updates and tells it which version of Dictate you have. The server counts checks by app, version and country and never stores your IP address. Updates download from dictate.firstversion.in. The speech models download once from huggingface.co.

Activation. Dictate keeps one item in your login Keychain, "Dictate activation": a token signed by the Dictate site. It holds three things: your signup id, a random number made on this Mac and the date. The signup id is a random code that points to your email in my list. Dictate checks the signature on this Mac and does not send the token anywhere.
