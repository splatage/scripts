sudo tee /etc/systemd/system/tradebidder-backend.service >/dev/null <<'UNIT'
[Unit]
Description=TradeBidder backend via PM2 (ecosystem.config.cjs)
Wants=network-online.target redis-server.service mariadb.service mysql.service
After=network-online.target redis-server.service mariadb.service mysql.service

[Service]
Type=simple
User=tradebid
WorkingDirectory=/home/tradebid/tradebidder/backend

Environment=PATH=/home/tradebid/.nvm/versions/node/v22.16.0/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=NODE_ENV=production
Environment=PM2_HOME=/home/tradebid/.pm2

# Delay to mirror your cron @reboot sleep
ExecStartPre=/bin/sleep 90

# Run pm2 in foreground so systemd supervises it
ExecStart=/home/tradebid/.nvm/versions/node/v22.16.0/bin/pm2-runtime /home/tradebid/tradebidder/backend/ecosystem.config.cjs
ExecStop=/home/tradebid/.nvm/versions/node/v22.16.0/bin/pm2 kill

Restart=always
RestartSec=5
TimeoutStartSec=0

# Hardening (optional; relax if needed)
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=read-only
ReadWritePaths=/home/tradebid/.pm2 /home/tradebid/tradebidder

[Install]
WantedBy=multi-user.target
UNIT

echo "
Apply and start:

sudo systemctl daemon-reload
sudo systemctl enable tradebidder-backend.service
sudo systemctl start tradebidder-backend.service

Quick checks:

systemctl status tradebidder-backend.service
journalctl -u tradebidder-backend.service -f
"

