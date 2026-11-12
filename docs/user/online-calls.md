# Online calls with Blend Mic

An online call has two sides, and a microphone hears only yours. [Blend Mic](https://github.com/spashii/blend) makes a microphone that carries yours and the sound your Mac plays on separate channels, and Voice transcribes each channel on its own. Tell the other side you're recording.

1. **Make the mix.** In Blend Mic, make a mix with your microphone and turn on System audio. It starts split by channel: your microphone on the left, system audio on the right.
2. **Leave your call app on its usual microphone.** Only Voice reads the mix. Blend Mic leaves every app that reads a mix out of that mix's system audio, so a call app set to the mix would be missing from the call side. Voice warns if one is.
3. **Start recording.** After a call app has used the microphone for 5 seconds (10 for a browser using the microphone and speakers), Voice shows "Record this call?" with Record and Not now. ``Option+Shift+` `` and the menu's "Record this call" start one too.
4. **Read the transcript.** Each side is cut at its pauses and transcribed while the call goes on, yours as Me and everyone else as Call. While it records, the call pill shows the last three lines. Click the call in the menu to copy it.
5. **Stop.** Recording stops 15 seconds after the call app stops using audio, with ``Option+Shift+` ``, from the menu, or when an agent says so. Once the transcript is complete, the WAV becomes an AAC `.m4a`: about 45 MB an hour of stereo instead of 690 MB.

Quitting during an online call closes the WAV, and the next launch rebuilds the transcript from the file. A mute or a device switch doesn't end a recording: it ends only after 15 seconds with neither input nor output.

Voice detects online calls in Zoom, Teams, Slack, Discord, FaceTime, WhatsApp, Signal, Telegram, Webex, Skype and Element, and in browsers (Meet, or any call in a tab). An agent can start a recording for any other app.

## Which input records

Settings, Calls, Record from lists Blend Mic's mixes with the side each channel carries, then the system default and your other inputs. Until you pick one, Voice records a split Blend Mic mix if there is one, and otherwise the default microphone, which hears only your side unless the call plays through speakers. If the chosen input is unplugged, the automatic one records instead.
