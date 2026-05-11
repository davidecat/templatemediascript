/** PM2 process file for multi-user Liquidsoap (staging/prod). */
function liqApp({ name, liqUserId, controlPort, tokenEnvVar }) {
  return {
    name,
    cwd: "/home/oooomedia/liq_scripts",
    script: "/home/oooomedia/liq_scripts/pm2-start.sh",
    interpreter: "bash",
    autorestart: true,
    max_restarts: 50,
    min_uptime: "5s",
    env: {
      LIQ_BIN: "/usr/bin/liquidsoap",
      SCRIPT: "/home/oooomedia/liq_scripts/script.liq",
      // Must match API path segment after /api/ (e.g. user1, not 1)
      LIQ_USER_ID: String(liqUserId),
      LIQ_CONTROL_PORT: String(controlPort),
      // Export this env var before PM2 start/restart.
      LIQ_API_TOKEN: process.env[tokenEnvVar] || "",
    },
  };
}

module.exports = {
  apps: [
    liqApp({
      name: "liquidsoap-user-1",
      liqUserId: "user1",
      controlPort: 7001,
      tokenEnvVar: "LIQ_TOKEN_USER_1",
    }),
    liqApp({
      name: "liquidsoap-user-9",
      liqUserId: "user9",
      controlPort: 7009,
      tokenEnvVar: "LIQ_TOKEN_USER_9",
    }),
  ],
};
