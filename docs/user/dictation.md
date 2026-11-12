# Dictation

Press ``Option+` `` in any text field, talk, and press it again. Your words show in a pill at the top of the screen as you speak, and the text is pasted when you stop.

- The shortcut is the only way to stop a dictation: there is no Escape and no timeout.
- Every recording is a WAV written as you speak, so a crash loses at most the last buffer. A recording that is too short or fails to transcribe keeps a history row, and a failed one retries from the menu.
- Dictate cuts the speech at pauses and transcribes each piece while you are still talking, so stopping costs only the last piece.
- Pasting is Cmd+V into the app in front, and then the clipboard is restored to what it held. Without Accessibility access the text stays on the clipboard.
- The menu lists your last five dictations and three online calls. Click one to copy it.
- Quitting during a dictation keeps the recording. The next launch transcribes it into the history without pasting, and the menu marks it "Recovered a recording".

## Key terms

Names and words Whisper gets wrong, spelled as they should be: people, products and places Whisper hasn't heard of. The list starts empty and goes into Whisper's prompt.

## The fix step

Optional. A model in [Ollama](https://ollama.com) suggests edits to the text, using your key terms, before it is pasted. The default model is `qwen3.5:9b`. If Ollama isn't running or the step fails, Whisper's text is pasted as it is.

On a 16 GB Mac, Whisper and a large Ollama model don't fit on the GPU together. Dictate frees Whisper before the fix step, and skips the fix step while an online call is using Whisper.

## How it works

Speech recognition is Whisper large v3 turbo (whisper.cpp) on your Mac's GPU. Dictate cuts the audio at pauses with the Silero voice activity model and sends each piece to Whisper with the key terms and the text before it as the prompt.

Whisper gives every segment a confidence, and Dictate stores it. Dictate decodes the least sure segments again with beam search, worst first, and shows you what each retry changed. No new retry starts once the retries so far have taken half the time of the first pass. A retry already running finishes, so the total can go slightly over.

Dictation shares Whisper with an online call, so a dictation during one waits behind the call's pieces.
