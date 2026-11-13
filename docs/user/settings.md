# Settings

Settings is in the sidebar of Dictate's window, under History. Cmd+, from the menu bar menu opens it on Setup. Setup shows a badge until its steps are done.

- **Setup:** [activate Dictate](./activation.md), allow the microphone, Accessibility and call audio, download the speech model, then Open at login and Keep history (forever, or 30 days).
- **Shortcuts:** the dictation shortcut, the call shortcut, and whether Dictate asks to record calls (on).
- **Microphones:** the default microphone for dictation and for online calls, and Call audio: the app (or Blend Mic mix) whose sound is the other side of a call. Cancel echo from the call, on by default, keeps the call out of Me when it plays on speakers. If the chosen microphone isn't connected, the default one records and Dictate says so.
- **Model:** Large v3 turbo (recommended) or Large v3 (3.1 GB, for languages turbo does worse), which can't change during an online call. The language is always detected. Key terms and the ones Dictate suggests, the retry switch with its numbers, Fix the text before pasting (a switch, off) and Title calls (a switch, on, which names a call from its transcript when it ends). One Model picker serves both switches: Apple Intelligence, shown when the Mac has it, or an Ollama model. The key terms go to Whisper whether or not Fix the text before pasting is on.
- **Agents:** the switch, the host and port the server listens on, the token, the setup to paste into an agent app, and a switch for each tool. Tools that record a call or change stored data start off.
- **About:** the version, Check for Updates, the automatic switch, what's new in each version, and the third-party notices.

Dictate asks on its second launch whether to check for updates automatically. Updates are signed, and Dictate installs only ones signed with its own key.
