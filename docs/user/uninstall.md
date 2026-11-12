# Uninstall

Quit Voice and move it to the Trash. To remove your recordings, transcripts and settings too:

```sh
rm -rf ~/Library/Application\ Support/Voice
defaults delete io.github.spashii.voice
```

With Homebrew, `brew uninstall --zap --cask voice` does both.
