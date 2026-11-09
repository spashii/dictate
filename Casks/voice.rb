cask "voice" do
  version "0.7.0"
  sha256 "4ecc37f8807afd80f01912beaad06edde342a5926132990974c1ba9deddcf260"

  url "https://apps.idea2prod.in/voice/download/#{version}"
  name "Voice"
  desc "Dictation and call transcripts with Whisper running on the Mac"
  homepage "https://spashii.github.io/voice/"

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :sequoia

  app "Voice.app"

  uninstall quit: "io.github.spashii.voice"

  # Every recording and transcript is in Application Support, so only --zap removes them.
  zap trash: [
    "~/Library/Application Support/Voice",
    "~/Library/Caches/io.github.spashii.voice",
    "~/Library/HTTPStorages/io.github.spashii.voice",
    "~/Library/Preferences/io.github.spashii.voice.plist",
  ]
end
