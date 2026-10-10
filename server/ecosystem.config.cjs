module.exports = {
  apps: [
    {
      name: "sms-forwarder-api",
      cwd: "/home/ec2-user/sms-forwarder-api",
      script: "server.mjs",
      interpreter: "node",
      instances: 1,
      exec_mode: "fork",
      env: {
        NODE_ENV: "production",
        PORT: 3011,
        HOST: "0.0.0.0",
        // Override on server via ecosystem or .env if needed.
        SMS_API_KEY: "smsfwd_7f3a9c2e1b8d4e6a0c5f9d2b7e4a1c8f",
      },
    },
  ],
};
