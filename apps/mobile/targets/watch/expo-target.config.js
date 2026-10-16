module.exports = (config) => ({
  type: "watch",
  name: "T3CodeWatch",
  displayName: config.name,
  bundleIdentifier: ".watch",
  deploymentTarget: "11.0",
  frameworks: ["SwiftUI", "WatchConnectivity"],
  icon: require("node:path").relative(
    __dirname,
    require("node:path").resolve(__dirname, "../..", config.icon),
  ),
});
