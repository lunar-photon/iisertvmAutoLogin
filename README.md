# IISER TVM Auto Login

Automatically log back in to the IISER TVM campus captive portal (`gateway.iisertvm.ac.in:8090`) whenever your session expires — no more opening a browser tab just to re-enter your credentials every time you get logged off.

This sets up a `systemd` user timer on Linux that pings the portal every minute and re-authenticates automatically, even if you were logged out server-side (session/data limit) with no browser open.

## Quick install

```bash
curl -fsSL https://raw.githubusercontent.com/publicgoodstack/iisertvmAutoLogin/main/auto_login_setup.sh | bash
```

You can [view the script source](https://github.com/publicgoodstack/iisertvmAutoLogin/blob/main/auto_login_setup.sh) on GitHub before running it — it's short, and asking for your password is worth double-checking.

You'll be prompted for your LDAP username and password during setup. They're saved locally in `~/bin/iiser-login.sh`, readable only by you (`chmod 700`), and never sent anywhere except directly to the campus gateway.

## What it does

- Creates two scripts in `~/bin/`: one continuous monitor daemon that detects session drops within 1-2 seconds, and one that holds your credentials and handles authentication/status checks.
- Installs a `systemd --user` background daemon (`iiser-login.service`) that automatically starts on login and restarts if needed.
- Truncates its own log file automatically so it doesn't grow forever.

## Requirements

- Linux with `systemd`
- `curl`
- An IISER TVM LDAP account

## Manual install

If you'd rather not pipe a script straight into `bash`, [read it on GitHub](https://github.com/publicgoodstack/iisertvmAutoLogin/blob/main/auto_login_setup.sh) first, or download and inspect it locally:

```bash
curl -fsSL -o auto_login_setup.sh https://raw.githubusercontent.com/publicgoodstack/iisertvmAutoLogin/main/auto_login_setup.sh
less auto_login_setup.sh   # review it
bash auto_login_setup.sh
```

## Checking it's working

```bash
systemctl --user status iiser-login.service
tail -f ~/.iiser-login.log
~/bin/iiser-login.sh -s    # check live portal status
```

A `status: LIVE` in the log means you're logged in and staying that way.

## Uninstall

```bash
systemctl --user disable --now iiser-login.service
rm -f ~/.config/systemd/user/iiser-login.service ~/.config/systemd/user/iiser-login.timer
rm -f ~/bin/iiser-login.sh ~/bin/check-internet.sh
systemctl --user daemon-reload
```

## How it works

A lightweight `systemd` user daemon runs in the background and probes connectivity every 2 seconds. The moment the captive portal session drops or times out server-side (due to lease limits or idle timeout), the daemon detects the outage within ~1 second and immediately re-authenticates against `gateway.iisertvm.ac.in:8090/login.xml`. This eliminates the frustrating 30–60 second disconnection gaps of coarse timer-based scripts, restoring internet in under 2 seconds. When offline or off-campus, it backs off to prevent unnecessary traffic.

## Security note

Your password is stored in plaintext in `~/bin/iiser-login.sh`, restricted to your user account only (`chmod 700`). This is the same trust model as any saved Wi-Fi password on your machine — anyone with access to your user account already has access to far more than this. If that's not an acceptable tradeoff for you, don't run this script.

## Something not working?

Open an [issue](https://github.com/publicgoodstack/iisertvmAutoLogin/issues) with what you tried and what happened — the contents of `~/.iiser-login.log` and `systemctl --user status iiser-login.timer` are usually the most useful things to include.

## Disclaimer

This is an unofficial, independently written tool and is not affiliated with or endorsed by IISER Thiruvananthapuram. It automates the same login request your browser already sends — use at your own discretion, and don't share your credentials file.

## License

MIT 
