# Online calls

An online call has two sides. Dictate records your microphone as Me and the sound of the call app as Call, and transcribes each on its own. Tell the other side you're recording.

1. **Allow call audio once.** Setup has a Call audio step. macOS asks to let Dictate record the sound of other apps; it records only the app you are on a call in. Without it Dictate records your microphone alone.
2. **Speakers or headphones.** On speakers Dictate takes the call out of what your microphone hears, so its words stay under Call. Other sound from your Mac, such as music, stays under Me. Turn this off with Cancel echo from the call in Settings, Microphones.
3. **Start recording.** After a call app has used the microphone for 5 seconds (10 for a browser using the microphone and speakers), Dictate shows "Record this call?" with Record and Not now. ``Option+Shift+` `` and the menu's "Record This Call" start one too.
4. **Read the transcript.** Each side is cut at its pauses and transcribed while the call goes on, yours as Me and everyone else as Call. While it records, the call pill shows the last three lines. Click the call in the menu to copy it.
5. **Stop.** Recording stops 15 seconds after the call app stops using audio, with ``Option+Shift+` ``, from the menu, or when an agent says so. Once the transcript is complete, the audio becomes an AAC `.m4a`: about 45 MB an hour of stereo instead of 690 MB.

When a call ends, the model chosen in Settings, Model (Apple Intelligence or an Ollama model) gives it a short title from its transcript. History and the menu show the title, with the app and time beside it. Without such a model, the call is named after its app, such as "Slack call", or just "Call" when Dictate doesn't know the app. A name you give it in History replaces the title and is never overwritten. Settings, Model, Title calls turns this off.

Quitting during an online call closes the WAV, and the next launch rebuilds the transcript from the file. A mute or a device switch doesn't end a recording: it ends only after 15 seconds with neither input nor output.

Dictate detects online calls in Zoom, Teams, Slack, Discord, FaceTime, WhatsApp, Signal, Telegram, Webex, Skype and Element, and in browsers (Meet, or any call in a tab). An agent can start a recording for any other app.

## Which audio records

Settings, Microphones has two choices for calls. Microphone for calls is Me. Call audio is the other side: Automatic, which is the call app Dictate finds; a specific app from the list, for a call app Dictate doesn't know; or a [Blend Mic](https://spashii.github.io/blend/) mix, for someone who already uses one. If the chosen app isn't running or the microphone is unplugged, Dictate falls back to Automatic or the default microphone and says so. Requires macOS 15 or later.
