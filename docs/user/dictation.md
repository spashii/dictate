# Dictation

Press ``Option+` `` in any text field, talk, and press it again. Your words show in a pill at the top of the screen as you speak, and the text is pasted when you stop.

- The shortcut is the only way to stop a dictation: there is no Escape and no timeout.
- Every recording is a WAV written as you speak, so a crash loses at most the last buffer. A recording that is too short or fails to transcribe keeps a history row, and a failed one retries from the menu.
- Dictate cuts the speech at pauses and transcribes each piece while you are still talking, so stopping costs only the last piece.
- Pasting is Cmd+V into the app in front, and then the clipboard is restored to what it held. Without Accessibility access the text stays on the clipboard.
- The menu lists your last five dictations and three online calls. Click one to copy it.
- When another app has secure keyboard input on, which a focused password field does and a stuck app can leave on, macOS stops every global shortcut. The menu then says that app's name and that shortcuts are paused. Leave the field, or quit the app.
- Quitting during a dictation keeps the recording. The next launch transcribes it into the history without pasting, and the menu marks it "Recovered a recording".

## Correcting a word

In History, drag across words or right-click one and choose Correct. With a block focused, press E to correct its line; VoiceOver has the same as an action. A changed name is offered as a key term in Settings, Model.

## Renaming and deleting

Select a recording in History and press Return to give it a title, or Cmd+Delete to delete it. Both are also in the row's right-click menu and the More menu. A name replaces the date as the row's title, and clearing it brings the date back. Delete asks first, then removes the audio, transcript and corrections from this Mac. A call still recording can't be deleted.

## Key terms

Names and words Whisper gets wrong, spelled as they should be: people, products and places Whisper hasn't heard of. The list starts empty and goes into Whisper's prompt.

## The fix step

Optional. A model in [Ollama](https://ollama.com) suggests edits to the text, using your key terms, before it is pasted. The default model is `qwen3.5:9b`. If Ollama isn't running or the step fails, Whisper's text is pasted as it is.

On a 16 GB Mac, Whisper and a large Ollama model don't fit on the GPU together. Dictate frees Whisper before the fix step, and skips the fix step while an online call is using Whisper.

## How it works

Speech recognition is Whisper large v3 turbo (whisper.cpp) on your Mac's GPU. Dictate cuts the audio at pauses with the Silero voice activity model and sends each piece to Whisper with the key terms and the text before it as the prompt.

Whisper gives every segment a confidence, and Dictate stores it. Dictate decodes the least sure segments again with beam search, worst first, and shows you what each retry changed. No new retry starts once the retries so far have taken half the time of the first pass. A retry already running finishes, so the total can go slightly over.

Dictation shares Whisper with an online call, so a dictation during one waits behind the call's pieces.
