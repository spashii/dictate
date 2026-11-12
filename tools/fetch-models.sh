#!/bin/zsh
# Puts whisper's model and the voice activity model where Dictate looks for them.
# OpenSuperWhisper's copy of the whisper model is cloned when it's there: an APFS clone
# takes no space and leaves its file as it was.
set -euo pipefail
support=$HOME/Library/Application\ Support
# A Mac whose app hasn't moved its data to Dictate yet still keeps it in Voice.
[[ -d $support/Dictate || ! -d $support/Voice ]] && models=$support/Dictate/models || models=$support/Voice/models
mkdir -p $models
whisper=$models/ggml-large-v3-turbo.bin
osw=$HOME/Library/Application\ Support/ru.starmel.OpenSuperWhisper/whisper-models/ggml-large-v3-turbo.bin
if [[ ! -f $whisper ]]; then
  if [[ -f $osw ]]; then
    cp -c $osw $whisper
  else
    curl -fL --progress-bar -o $whisper.part \
      https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
    mv $whisper.part $whisper
  fi
fi
vad=$models/ggml-silero-v5.1.2.bin
if [[ ! -f $vad ]]; then
  curl -fsL -o $vad.part https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin
  mv $vad.part $vad
fi
ls -l $models
