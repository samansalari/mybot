# Self-Hosted Rakazo Upstream Synchronisation

This directory provides production-grade systemd services, timers, and configuration templates to run continuous, autonomous upstream synchronisation for `samansalari/mybot` from `elie222/rakazo` without depending on GitHub Actions or consuming GitHub-hosted runner minutes.

---

## 1. Architecture Overview

- **Schedule**: Every 6 hours (`00:00`, `06:00`, `12:00`, `18:00` UTC) via `mybot-sync.timer`.
- **Catch-up**: `Persistent=true` ensures missed intervals (e.g. VPS maintenance or reboots) run immediately upon recovery.
- **Safety**: Non-root service execution (`mybot-sync`), restricted file permissions (`chmod 600`), and process locking (`flock` on `/tmp/mybot-upstream-sync.lock`) to prevent concurrent execution.
- **Independence**: Works completely independently of your local Mac; continues synchronizing 24/7 on your Ubuntu VPS.
- **Validation**: Every sync runs local architecture checks (`pnpm checks`), monorepo typechecking (`pnpm check`), and unit test isolation suites before pushing or opening PRs.
- **Non-Destructive**: Never force-pushes or rewrites `main`. If upstream and local histories diverge, safe non-destructive branch reconciliation is used to maintain PR continuity.

---

## 2. Prerequisites on Ubuntu VPS

Install required packages:

```bash
# Update package lists
sudo apt update && sudo apt install -y git curl python3 systemd

# Install GitHub CLI (gh)
type -p curl >/dev/null || (sudo apt update && sudo apt install curl -y)
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt update && sudo apt install gh -y

# Install Node.js (v22+) and pnpm
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt install -y nodejs
corepack enable
corepack prepare pnpm@latest --activate
```

---

## 3. Dedicated Service Account & Setup

Create a dedicated non-root system user:

```bash
sudo useradd -r -m -d /var/lib/mybot-sync -s /bin/bash mybot-sync
```

Create state, log, and configuration directories:

```bash
sudo mkdir -p /etc/mybot-sync /var/lib/mybot-sync /var/log/mybot-sync
sudo chown -R mybot-sync:mybot-sync /var/lib/mybot-sync /var/log/mybot-sync
sudo chmod 750 /var/lib/mybot-sync /var/log/mybot-sync
```

Clone the repository to `/opt/mybot`:

```bash
sudo mkdir -p /opt/mybot
sudo chown -R mybot-sync:mybot-sync /opt/mybot

# Switch to mybot-sync user to clone
sudo -u mybot-sync -i
git clone https://github.com/samansalari/mybot.git /opt/mybot
cd /opt/mybot
git remote add upstream https://github.com/elie222/rakazo.git
pnpm install --frozen-lockfile
exit
```

---

## 4. Authentication Configuration

Create the configuration file at `/etc/mybot-sync/config.env` with restricted permissions:

```bash
sudo cp /opt/mybot/deploy/systemd/mybot-sync.env.example /etc/mybot-sync/config.env
sudo chmod 600 /etc/mybot-sync/config.env
sudo chown mybot-sync:mybot-sync /etc/mybot-sync/config.env
```

Edit `/etc/mybot-sync/config.env` and set your preferred authentication method:

### Option A: SSH Key (Recommended)
1. Generate an SSH key pair for `mybot-sync`:
   ```bash
   sudo -u mybot-sync ssh-keygen -t ed25519 -C "mybot-sync@vps" -f /var/lib/mybot-sync/.ssh/id_ed25519 -N ""
   ```
2. Add `/var/lib/mybot-sync/.ssh/id_ed25519.pub` as a Deploy Key with **Write Access** to `samansalari/mybot` on GitHub (Settings -> Deploy Keys).
3. Ensure the git remote uses SSH:
   ```bash
   sudo -u mybot-sync git -C /opt/mybot remote set-url origin git@github.com:samansalari/mybot.git
   ```

### Option B: Fine-Grained GitHub Personal Access Token (PAT)
1. Generate a fine-grained token with:
   - Repository: `samansalari/mybot`
   - Permissions: `Contents: Read and write`, `Pull requests: Read and write`
2. Add to `/etc/mybot-sync/config.env`:
   ```env
   GH_TOKEN=github_pat_xxxx
   ```

---

## 5. Install & Enable Systemd Units

Copy the unit files into systemd:

```bash
sudo cp /opt/mybot/deploy/systemd/mybot-sync.service /etc/systemd/system/
sudo cp /opt/mybot/deploy/systemd/mybot-sync.timer /etc/systemd/system/

sudo systemctl daemon-reload
sudo systemctl enable --now mybot-sync.timer
```

Verify timer status:

```bash
sudo systemctl list-timers mybot-sync.timer
```

---

## 6. Operation & Maintenance Commands

### Check Status
Display last sync status, timestamps, upstream SHA, and timer:

```bash
sudo -u mybot-sync /opt/mybot/scripts/upstream-sync.sh --status
```

### Manual Trigger
Trigger an immediate synchronization cycle:

```bash
sudo systemctl start mybot-sync.service
```
Or directly:
```bash
sudo -u mybot-sync /opt/mybot/scripts/upstream-sync.sh --run
```

### View Logs
Stream live journal output:

```bash
sudo journalctl -u mybot-sync.service -f
```
Or inspect the log file:
```bash
tail -f /var/log/mybot-sync/sync.log
```

---

## 7. User-Mode Alternative (No Root Required)

If running without root access on a VPS or workstation:

1. Copy service and timer to `~/.config/systemd/user/`:
   ```bash
   mkdir -p ~/.config/systemd/user ~/.config/mybot-sync
   cp deploy/systemd/mybot-sync.service ~/.config/systemd/user/
   cp deploy/systemd/mybot-sync.timer ~/.config/systemd/user/
   ```
2. Adjust `WorkingDirectory` and paths in `~/.config/systemd/user/mybot-sync.service` to match your home directory.
3. Enable and start:
   ```bash
   systemctl --user daemon-reload
   systemctl --user enable --now mybot-sync.timer
   loginctl enable-linger $USER
   ```
