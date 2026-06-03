cask "heartecho" do
  version "0.1.0"
  sha256 :no_check

  url "https://github.com/cloud-oc/goal-loopback-https-rogueamoeba-com-loopback/releases/download/v#{version}/Heartecho-#{version}.dmg"
  name "Heartecho"
  desc "Native macOS audio routing workbench"
  homepage "https://github.com/cloud-oc/goal-loopback-https-rogueamoeba-com-loopback"

  pkg "Install Heartecho.pkg", allow_untrusted: true

  uninstall launchctl: "com.heartecho.Heartecho.Helper",
            pkgutil: [
              "com.heartecho.Heartecho.distribution",
              "com.heartecho.Heartecho.pkg",
              "com.heartecho.Heartecho.uninstaller.pkg",
            ],
            delete: [
              "/Applications/Heartecho.app",
              "/Library/Audio/Plug-Ins/HAL/Heartecho.driver",
              "/Library/Application Support/Heartecho",
              "/Library/LaunchAgents/com.heartecho.Heartecho.Helper.plist",
            ]

  zap trash: [
    "~/Library/Application Support/Heartecho",
    "~/Library/Preferences/com.heartecho.Heartecho.plist",
  ]
end
