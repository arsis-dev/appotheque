cask "appotheque" do
  version "0.5.1"
  sha256 "c12dd2e90255a54e5d125586d10e0ae118b14b537d8515e201d8846ce3671292"

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
