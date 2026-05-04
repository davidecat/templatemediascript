/** PM2 process file for Liquidsoap (staging/prod). */
module.exports = {
  apps: [
    {
      name: "liquidsoap-radio",
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
        LIQ_DAEMONIZE: "true",
      },
    },
  ],
};
