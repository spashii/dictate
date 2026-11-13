# What's new in Dictate

<!--
One entry per release, newest first: "## VERSION (YYYY-MM-DD)", then one "- " line per change,
written for the person using Dictate. Settings, About shows this file, and tools/release.sh puts
the entry for VERSION into the update feed, which Sparkle shows before installing. release.sh
stops when VERSION has no entry here.
-->

## 0.15.1 (2026-11-13)

- History fills the window again when a filter has nothing in it.

## 0.15.0 (2026-11-13)

- History has a New menu in the toolbar: New Dictation, Record a Call and Import Audio File…
- Drop an audio or video file on History to transcribe it on your Mac. It gets a title like a call and shows up in search.
- Agents can import an audio file by its path. The tool is off until you turn it on in Settings, Agents.
- History has one Search field in the title row. It finds recordings and marks the words in the one you open.
- Correct a name in History and it becomes a key term. You can undo it right away.
- Call titles are three or four words. A recording shows Generating title… while its title is made.
- Right-click a recording and choose Generate Title to name it again.
- History rows and transcript lines line up better. The play button no longer covers the time.
- Settings, Model greys out what needs an intelligence model when none can run. It says why.
- The menu shows the version below Check for Updates.
- Developer mode in About adds Advanced, with charts of how long the models take.

## 0.14.2 (2026-11-13)

- What’s new shows the last three releases. View more shows the rest.

## 0.14.1 (2026-11-13)

- Settings, Model now has two groups. Speech holds the speech model and Retry unsure segments. Intelligence holds one model for fixing text and for call titles.
- Apple Intelligence is the default Intelligence model, and you can always open the picker.
- Add a title to each call automatically is on by default.
- About shows when an update is available and what's new.
- Dictate is now in early access.

## 0.14.0 (2026-11-13)

- Calls get a short title from their transcript when they end, written by a model on your Mac. An automatic title never replaces a name you give a call.
- Fix the text before pasting can use Apple Intelligence on Macs that have it, as well as Ollama. Choose the model in Settings, Model.
- History shows the call app first, then the title.
- Agents can give a recording a title. The tool is off until you turn it on in Settings, Agents.

## 0.13.1 (2026-11-13)

- The download opens on a window that shows where to drag Dictate.

## 0.13.0 (2026-11-13)

- Activate Dictate once with your email.
- Rename and delete recordings in History.
- Select words in History to correct them. A corrected name is offered as a key term.
- Cmd+F searches inside the open recording.
- The menu shows your five newest recordings.
- When another app has secure keyboard input on, the menu names that app and says the shortcuts are paused.
- Settings, Microphones says whether Blend Mic is installed.

## 0.12.1 (2026-11-12)

- Me is blue and Call is purple in transcripts.
- On speakers, the other side of the call no longer shows up under Me.
- History search looks inside every transcript.
- History works with VoiceOver and the keyboard. Press Return on a block to play from there.
- Long calls open and play faster in History.
- The Agents settings show the setup to paste into an agent app, with your token filled in. They warn when other machines can reach the server.
- Settings, Microphones names each microphone and explains the call audio choice.

## 0.12.0 (2026-11-12)

- Voice is now Dictate. Your recordings and settings move over on their own.
- One window for History and Settings, opened from the menu or with Cmd+,.
- Dictate records the other side of a call straight from the call app, without Blend Mic. Allow call audio once in Setup.
- History has search and one block per speaker turn. Corrected words are underlined. You can play from any line and save the audio with Save As.
- History shows the time of day for each recording, and its time zone when that differs from yours.
- Suggested key terms leave out everyday English words.
- Settings, Agents turns each tool on or off and sets the address and token. On new installs, tools that record or change anything start off.
- The live pill fades while the pointer is over it.
- Recordings that heard nothing stay out of History.

## 0.11.0 (2026-11-09)

- The menu has Check for Updates, Report an Issue and View on GitHub.
