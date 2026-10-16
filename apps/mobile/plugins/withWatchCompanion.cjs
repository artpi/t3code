const { withInfoPlist } = require("expo/config-plugins");
const withAppleTargets = require("@bacons/apple-targets/app.plugin");

module.exports = (config) => {
  config = withInfoPlist(config, (mod) => {
    mod.modResults.T3WatchCompanionEnabled = true;
    return mod;
  });
  return withAppleTargets(config, { root: "./targets", match: "watch" });
};
