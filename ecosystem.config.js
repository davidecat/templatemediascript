/** PM2 — production (single user1, no token). */
module.exports = {
    apps: [
      {
        name: "liquidsoap-user-1",
        cwd: "/home/oooomedia/liq_scripts",
        script: "/home/oooomedia/liq_scripts/pm2-start.sh",
        interpreter: "bash",
        autorestart: true,
        max_restarts: 50,
        min_uptime: "5s",
        env: {
          LIQ_BIN: "/usr/bin/liquidsoap",
          SCRIPT: "/home/oooomedia/liq_scripts/script.liq",
          LIQ_USER_ID: "user1",
        },
      },
    ],
  };