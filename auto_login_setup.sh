#!/bin/bash

echo "SETTING UP AUTO LOGIN (Fast Reconnect Daemon)"

if [ -f ~/bin/iiser-login.sh ]; then
    read -p "~/bin/iiser-login.sh already exists. Overwrite? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || exit 1
fi

mkdir -p ~/bin

cat > ~/bin/check-internet.sh << 'EOF'
#!/bin/bash

LOG="$HOME/.iiser-login.log"
MAXLINES=500
CHECK_INTERVAL_ONLINE=2       # Seconds between probes when internet is healthy
RETRY_INTERVAL_OFFLINE=1      # Seconds between retries when disconnected
GATEWAY_UNREACHABLE_BACKOFF=8 # Seconds to wait if not on IISER TVM network

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" >> "$LOG"
    if [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt "$MAXLINES" ]; then
        tail -n "$((MAXLINES / 2))" "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
    fi
}

trap 'log "Auto-login daemon stopped."; exit 0' SIGTERM SIGINT

log "IISER TVM Auto-Login daemon started (fast reconnect mode: 2s check interval)."

last_state="unknown"

while true; do
    # 1. Fast probe for active internet connection (takes ~50ms)
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -m 1.5 "http://connectivitycheck.gstatic.com/generate_204" 2>/dev/null)

    if [ "$http_code" = "204" ]; then
        if [ "$last_state" != "online" ]; then
            log "Internet connection active."
            last_state="online"
        fi
        sleep "$CHECK_INTERVAL_ONLINE"
        continue
    fi

    # 2. Internet probe failed! Check if on IISER TVM network
    status_xml=$(curl -sk -m 1.5 "https://gateway.iisertvm.ac.in:8090/captiveportal/status" 2>/dev/null)

    if [ -z "$status_xml" ]; then
        if [ "$last_state" != "unreachable" ]; then
            log "Gateway unreachable. Not on IISER TVM Wi-Fi or interface down."
            last_state="unreachable"
        fi
        sleep "$GATEWAY_UNREACHABLE_BACKOFF"
        continue
    fi

    # If portal says LIVE but 204 failed, could be momentary jitter. Check once more.
    if echo "$status_xml" | grep -q "LIVE"; then
        sleep "$RETRY_INTERVAL_OFFLINE"
        http_code=$(curl -s -o /dev/null -w "%{http_code}" -m 1.5 "http://connectivitycheck.gstatic.com/generate_204" 2>/dev/null)
        if [ "$http_code" = "204" ]; then
            last_state="online"
            sleep "$CHECK_INTERVAL_ONLINE"
            continue
        fi
    fi

    # 3. Session dropped or expired! Re-authenticate immediately
    log "Captive portal session expired or dropped. Re-authenticating immediately..."
    last_state="authenticating"
    start_time=$(date +%s%3N)

    login_out=$("$HOME/bin/iiser-login.sh" 2>&1)
    login_code=$?
    end_time=$(date +%s%3N)
    elapsed=$((end_time - start_time))

    if [ $login_code -eq 0 ] || echo "$login_out" | grep -q "LIVE"; then
        log "Re-authenticated successfully in ${elapsed}ms. (Status: LIVE)"
        last_state="online"
        sleep "$CHECK_INTERVAL_ONLINE"
    elif echo "$login_out" | grep -qi "maximum login limit"; then
        log "Re-authentication failed: Maximum login limit reached. Retrying in 5s..."
        sleep 5
    else
        log "Re-authentication attempt: $login_out. Retrying in 1s..."
        sleep "$RETRY_INTERVAL_OFFLINE"
    fi
done
EOF

read -p "Username: " USERNAME < /dev/tty
read -s -p "Password: " PASSWORD < /dev/tty
echo

cat > ~/bin/iiser-login.sh << EOF
#!/bin/bash

GATEWAY="https://gateway.iisertvm.ac.in:8090"
USERNAME="$USERNAME"
PASSWORD="$PASSWORD"

check_status() {
    local res
    res=\$(curl -sk -m 2 "\$GATEWAY/captiveportal/status" 2>/dev/null)
    if echo "\$res" | grep -q "LIVE"; then
        [ "\$1" != "-q" ] && echo "Status: LIVE (Authenticated as \$USERNAME)"
        return 0
    elif echo "\$res" | grep -q "LOGIN"; then
        [ "\$1" != "-q" ] && echo "Status: LOGIN (Logged out / captive portal required)"
        return 1
    elif [ -n "\$res" ]; then
        [ "\$1" != "-q" ] && echo "Status: Portal reachable, but not live"
        return 1
    else
        [ "\$1" != "-q" ] && echo "Status: Gateway unreachable (not on IISER TVM network?)"
        return 2
    fi
}

do_login() {
    local res
    res=\$(curl -sk -m 4 \\
      -H "Origin: \$GATEWAY" \\
      -H "Referer: \$GATEWAY/httpclient.html" \\
      -H "Content-Type: application/x-www-form-urlencoded" \\
      --data "mode=191&username=\${USERNAME}&password=\${PASSWORD}&a=\$(date +%s%3N)&producttype=0" \\
      "\$GATEWAY/login.xml" 2>/dev/null)

    if echo "\$res" | grep -q "LIVE"; then
        [ "\$1" != "-q" ] && echo "Login successful (status: LIVE)"
        return 0
    elif echo "\$res" | grep -qi "maximum login limit"; then
        [ "\$1" != "-q" ] && echo "Login failed: Maximum login limit reached for \$USERNAME"
        return 1
    elif [ -n "\$res" ]; then
        local msg
        msg=\$(echo "\$res" | sed -n 's/.*<message><!\\[CDATA\\[\\(.*\\)\\]\\]><\\/message>.*/\\1/p')
        [ "\$1" != "-q" ] && echo "Login response: \${msg:-\$res}"
        return 1
    else
        [ "\$1" != "-q" ] && echo "Login failed: Gateway unreachable"
        return 2
    fi
}

case "\$1" in
    --status|-s)
        check_status "\$2"
        ;;
    -q|--quiet|--silent)
        do_login -q
        ;;
    *)
        do_login "\$@"
        ;;
esac
EOF

chmod 700 ~/bin/iiser-login.sh
chmod 755 ~/bin/check-internet.sh

mkdir -p ~/.config/systemd/user

# Disable old timer if present
if systemctl --user is-enabled iiser-login.timer >/dev/null 2>&1; then
    systemctl --user disable --now iiser-login.timer 2>/dev/null || true
fi
rm -f ~/.config/systemd/user/iiser-login.timer

cat > ~/.config/systemd/user/iiser-login.service << 'EOF'
[Unit]
Description=IISER TVM Captive Portal Auto-Login Daemon
After=network.target network-online.target

[Service]
Type=simple
ExecStart=%h/bin/check-internet.sh
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now iiser-login.service

echo "Setup complete. Service status:"
systemctl --user status iiser-login.service --no-pager
