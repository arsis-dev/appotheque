cask "appotheque" do
  version "0.5.0"
  sha256 "336e14388c4f82826005fb08f1c32b7f6820d4a3ca5c88abbee57abe3aa19e63"

  url "https://github.com/arsis-dev/appotheque/releases/download/v#{version}/Appotheque-#{version}.zip"
  name "Appothèque"
  desc "Launcher that rebuilds apps in development only when their sources change"
  homepage "https://github.com/arsis-dev/appotheque"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :tahoe

  app "Appothèque.app"

  zap trash: [
    "~/Library/Application Support/Appotheque",
    "~/Library/Preferences/dev.arsis.appotheque.plist",
  ]
end
