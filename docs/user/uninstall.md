# Uninstall

Quit Dictate and move it to the Trash. To remove your recordings, transcripts and settings too:

```sh
rm -rf ~/Library/Application\ Support/Dictate ~/Library/Application\ Support/Voice
defaults delete io.github.spashii.voice
security delete-generic-password -s in.firstversion.dictate.activation
```
