# Linux Mint Workstation Multi-User Setup

I need you to help me set up this Linux Mint workstation for multi-user ML/deep learning work. You have sudo access (I'll set up NOPASSWD for this session).

## Working agreement

- **Stop after Phase 0** and summarize findings. Wait for my confirmation before proceeding.
- **Pause before any change that affects other users' accounts or requires reboot.**
- Show me the command before running anything destructive or system-wide.
- If something looks unexpected (broken driver, unusual partitioning, existing config that conflicts), stop and ask rather than guessing.
- Do not install Docker. Do not add anyone to the `docker` group. We use Podman.
- Install the CUDA Toolkit system-wide for build tools (`nvcc`, headers, CUDA libraries), but do **not** install the driver-changing `cuda` meta package. Users still install ML frameworks inside Conda environments.
- Use Miniconda, not Miniforge, for new per-user Conda installs.
- After each phase, verify the changes took effect before moving on.
- At the end, run a full audit of everything and fix any issues found.
- **IMPORTANT: After setting UMASK to 077 in Phase 1, all files created by root (via sudo tee, etc.) will be chmod 600 by default.** Any file that needs to be readable by other users (polkit rules, autostart .desktop files, profile.d scripts) MUST have `chmod 644` or `chmod 755` applied explicitly after creation. This was the #1 source of bugs during the hulk setup.

---

## Phase 0: Reconnaissance

Run these and summarize findings. Pay special attention to disk layout — tell me how many drives, what sizes, what's mounted where, and free space.

```bash
# Existing users (UID >= 1000)
getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 {print $1, $3, $6}'

# Home directory permissions
ls -ld /home/*

# GPU health
nvidia-smi

# System info
uname -r && lsb_release -a
nproc && free -h | head -2
lscpu | grep 'Model name'

# Container tools
which docker podman 2>/dev/null

# CUDA Toolkit
which nvcc 2>/dev/null || true
nvcc --version 2>/dev/null || true
echo "CUDA_HOME=${CUDA_HOME:-unset}"
dpkg-query -W -f='${binary:Package} ${Version} ${Status}\n' 'cuda-toolkit*' 'nvidia-cuda-toolkit' 2>/dev/null || true

# SSH config
sudo grep -E '^(PasswordAuthentication|PubkeyAuthentication|PermitRootLogin)' /etc/ssh/sshd_config

# SSH keys
ls -la ~/.ssh/authorized_keys 2>/dev/null

# Current defaults
grep '^UMASK' /etc/login.defs
grep 'DIR_MODE' /etc/adduser.conf

# Disk layout
df -h
lsblk -f
sudo fdisk -l 2>/dev/null | grep -E '^Disk |^/dev'
cat /etc/fstab
```

**If root partition is >80% full:** investigate what's consuming space (`du -xh --max-depth=1 /`), report findings, and ask me what to clean up before proceeding.

**Stop here. Wait for my confirmation.**

---

## Phase 1: System baseline

```bash
sudo apt update && sudo apt full-upgrade -y
```

If the upgrade includes kernel or NVIDIA driver changes, warn me that a reboot will be needed.

Ask me what hostname to set, then:
```bash
sudo hostnamectl set-hostname <name>
sudo sed -i 's/127.0.1.1.*/127.0.1.1\t<name>/' /etc/hosts
```

Harden default permissions for new files and new home directories:
- `/etc/login.defs`: change `UMASK 022` → `UMASK 077`
- `/etc/adduser.conf`: set `DIR_MODE=0700` (uncomment if needed)

Enable firewall:
```bash
sudo ufw allow OpenSSH
sudo ufw enable
sudo ufw status verbose
```

Install system-wide essentials:
```bash
sudo apt install -y git tmux htop tree unzip curl wget build-essential libgl1 libglib2.0-0
```

---

## Phase 2: Tighten existing home directories

**Ask me first** to confirm I've notified other users.

```bash
sudo chmod 700 /home/*    # except /home/lost+found
ls -ld /home/*
```

Confirm all user homes show `drwx------`.

---

## Phase 3: NVIDIA driver health

If `nvidia-smi` worked in Phase 0, **skip this phase**. Note the "CUDA Version" from nvidia-smi — that's the max CUDA users can run.

If broken, tell me and I'll fix via Driver Manager GUI.

---

## Phase 4: Add new users

Ask me:
- How many users to add and their usernames
- Whether to assign specific UIDs

For each user:
```bash
# The adduser command is interactive — tell me to run it myself:
# sudo adduser <username>
# sudo passwd <username>    (if password didn't set during adduser)
```

Verify each new home is private:
```bash
ls -ld /home/<username>
# Must show: drwx------
```

---

## Phase 5: Shared data folder

**Base the location on Phase 0 disk findings:**
- If a secondary drive exists and is mounted (e.g., `/data`), put shared data there with a symlink from `/srv/shared`.
- If no secondary drive, use `/srv/shared` on the primary disk.
- If a secondary drive exists but isn't mounted, ask me about it.

**If using a secondary drive:** add `acl` to its `/etc/fstab` entry and remount.

```bash
sudo groupadd labshared

# Add ALL users (existing + new). NEVER omit -a from -aG:
sudo usermod -aG labshared <user1>
sudo usermod -aG labshared <user2>
# ... repeat for all users

# Create directory (path depends on disk decision):
sudo mkdir -p /data/shared         # or /srv/shared
sudo ln -s /data/shared /srv/shared  # symlink if on secondary drive
sudo chown root:labshared /data/shared
sudo chmod 2770 /data/shared       # setgid bit

# ACL so new files are group-readable despite umask 077:
sudo apt install -y acl
sudo setfacl -d -m g:labshared:rwx /data/shared
sudo setfacl -m g:labshared:rwx /data/shared

getfacl /data/shared
```

Note: group membership takes effect on next login.

---

## Phase 6: Resource limits via systemd

**Scale these to the actual hardware** found in Phase 0:
- CPUQuota: (total_cores - 1) * 100 — reserves 1 core for system, dynamic fair-share
- MemoryHigh: ~70% of total RAM (soft limit)
- MemoryMax: ~85% of total RAM (hard kill)

Create `/etc/systemd/system/user-.slice.d/limits.conf`:

```ini
[Slice]
MemoryHigh=<scaled>
MemoryMax=<scaled>
CPUQuota=<scaled>
TasksMax=4096
```

```bash
sudo systemctl daemon-reload
systemctl show user-$(id -u).slice | grep -E 'MemoryMax|MemoryHigh|CPUQuota|TasksMax'
```

---

## Phase 7: CUDA Toolkit + Podman + NVIDIA Container Toolkit

Install CUDA Toolkit system-wide for packages that need to compile CUDA extensions. This gives users `nvcc`, CUDA headers, and system CUDA libraries. It does **not** replace Conda/PyTorch CUDA wheels, and it must not install the driver-changing `cuda` meta package.

Use the CUDA Toolkit version that matches the shared PyTorch wheel family. For the `cu128` PyTorch wheels below, install CUDA Toolkit 12.8.

```bash
# NVIDIA CUDA Toolkit repo for Ubuntu 24.04 / Linux Mint 22.x
curl -fsSL -o /tmp/cuda-keyring_1.1-1_all.deb \
  https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i /tmp/cuda-keyring_1.1-1_all.deb

sudo apt update
sudo apt install -y cuda-toolkit-12-8
```

Expose CUDA Toolkit paths to all users:
```bash
sudo tee /etc/profile.d/cuda-toolkit.sh > /dev/null << 'EOF'
export CUDA_HOME=/usr/local/cuda-12.8
export PATH="$CUDA_HOME/bin:$PATH"
export LD_LIBRARY_PATH="$CUDA_HOME/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
EOF
sudo chmod 644 /etc/profile.d/cuda-toolkit.sh
```

Verify in a new login shell:
```bash
bash -lc 'which nvcc && nvcc --version && echo "$CUDA_HOME"'
```

If `nvidia-cuda-toolkit` from Ubuntu is already installed and `which nvcc` still resolves to `/usr/bin/nvcc`, stop and ask before removing it. Do not remove packages blindly on a machine people are already using.

```bash
sudo apt install -y podman

# NVIDIA container toolkit repo
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
  sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
sudo chmod 644 /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt update
sudo apt install -y nvidia-container-toolkit
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
```

Test as regular user (use a CUDA tag compatible with the driver version from Phase 0):
```bash
podman run --rm --device nvidia.com/gpu=all \
  docker.io/nvidia/cuda:<version>-base-ubuntu24.04 nvidia-smi
```

---

## Phase 8: Shared ML Environment

Install a system-level Miniconda, then create a shared read-only environment:

```bash
# Download installer
sudo mkdir -p /opt/miniconda-installer
sudo curl -fsSL -o /opt/miniconda-installer/Miniconda3-Linux-x86_64.sh \
  https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh
sudo chmod 755 /opt/miniconda-installer /opt/miniconda-installer/Miniconda3-Linux-x86_64.sh

# Install system Miniconda
sudo bash /opt/miniconda-installer/Miniconda3-Linux-x86_64.sh -b -p /opt/conda-shared

# Make new Conda envs include Python by default.
sudo /opt/conda-shared/bin/conda config --system --remove-key channels 2>/dev/null || true
sudo /opt/conda-shared/bin/conda config --system --add channels conda-forge
sudo /opt/conda-shared/bin/conda config --system --set auto_activate_base false
sudo /opt/conda-shared/bin/conda config --system --remove-key create_default_packages 2>/dev/null || true
sudo /opt/conda-shared/bin/conda config --system --add create_default_packages python=3.11
sudo /opt/conda-shared/bin/conda config --system --add create_default_packages pip
sudo /opt/conda-shared/bin/conda config --system --add create_default_packages ipykernel

# Create shared environment
sudo /opt/conda-shared/bin/conda create -y -p /opt/conda-shared/envs/ml-base python=3.11

# Install PyTorch+CUDA from official wheels (adjust cu version to match driver):
sudo /opt/conda-shared/envs/ml-base/bin/pip install \
  torch torchvision torchaudio \
  --index-url https://download.pytorch.org/whl/cu128

# Install ML and medical imaging packages:
sudo /opt/conda-shared/envs/ml-base/bin/pip install \
  jupyterlab ipykernel numpy pandas matplotlib scipy \
  scikit-learn scikit-image seaborn tqdm pillow h5py \
  opencv-python-headless nibabel pydicom SimpleITK monai tensorboard

# Make read-only and accessible:
sudo chmod -R o+rX /opt/conda-shared
sudo chmod -R a+rX,a-w /opt/conda-shared/envs/ml-base

# Verify:
/opt/conda-shared/envs/ml-base/bin/python -c \
  "import torch; print(f'PyTorch {torch.__version__}, CUDA: {torch.cuda.is_available()}')"
```

Create activation alias for all users:
```bash
sudo tee /etc/profile.d/shared-conda-env.sh > /dev/null << 'EOF'
alias activate-ml='source /opt/conda-shared/envs/ml-base/bin/activate'
EOF
sudo chmod 644 /etc/profile.d/shared-conda-env.sh
```

---

## Phase 9: Per-User Miniconda

Install Miniconda into each new user's home, and auto-install for future users:

```bash
# Install for each existing new user:
sudo -u <username> bash /opt/miniconda-installer/Miniconda3-Linux-x86_64.sh \
  -b -p /home/<username>/miniconda3
sudo -u <username> /home/<username>/miniconda3/bin/conda init bash
sudo -u <username> /home/<username>/miniconda3/bin/conda config --system --remove-key channels 2>/dev/null || true
sudo -u <username> /home/<username>/miniconda3/bin/conda config --system --add channels conda-forge
sudo -u <username> /home/<username>/miniconda3/bin/conda config --remove-key channels 2>/dev/null || true
sudo -u <username> /home/<username>/miniconda3/bin/conda config --add channels conda-forge
sudo -u <username> /home/<username>/miniconda3/bin/conda config --set auto_activate_base false
sudo -u <username> /home/<username>/miniconda3/bin/conda config --remove-key create_default_packages 2>/dev/null || true
sudo -u <username> /home/<username>/miniconda3/bin/conda config --add create_default_packages python=3.11
sudo -u <username> /home/<username>/miniconda3/bin/conda config --add create_default_packages pip
sudo -u <username> /home/<username>/miniconda3/bin/conda config --add create_default_packages ipykernel

# Auto-install for future users on first login:
sudo tee /etc/profile.d/miniconda-setup.sh > /dev/null << 'EOF'
if [ -z "$MINICONDA_SETUP_DONE" ] && [ ! -d "$HOME/miniconda3" ] && [ "$(id -u)" -ge 1000 ]; then
    MINICONDA_SETUP_DONE=1
    export MINICONDA_SETUP_DONE
    INSTALLER="/opt/miniconda-installer/Miniconda3-Linux-x86_64.sh"
    if [ -f "$INSTALLER" ]; then
        echo "=== First login: installing Miniconda into ~/miniconda3 ==="
        if bash "$INSTALLER" -b -p "$HOME/miniconda3"; then
            "$HOME/miniconda3/bin/conda" init bash > /dev/null 2>&1
            "$HOME/miniconda3/bin/conda" config --system --remove-key channels > /dev/null 2>&1 || true
            "$HOME/miniconda3/bin/conda" config --system --add channels conda-forge > /dev/null 2>&1
            "$HOME/miniconda3/bin/conda" config --remove-key channels > /dev/null 2>&1 || true
            "$HOME/miniconda3/bin/conda" config --add channels conda-forge > /dev/null 2>&1
            "$HOME/miniconda3/bin/conda" config --set auto_activate_base false
            "$HOME/miniconda3/bin/conda" config --remove-key create_default_packages > /dev/null 2>&1 || true
            "$HOME/miniconda3/bin/conda" config --add create_default_packages python=3.11 > /dev/null 2>&1
            "$HOME/miniconda3/bin/conda" config --add create_default_packages pip > /dev/null 2>&1
            "$HOME/miniconda3/bin/conda" config --add create_default_packages ipykernel > /dev/null 2>&1
            echo "=== Miniconda installed. Run 'source ~/.bashrc' or log out and back in to activate conda. ==="
        fi
    fi
fi
EOF
sudo chmod 644 /etc/profile.d/miniconda-setup.sh
```

If this machine already has Miniforge users, migrate without breaking existing work:

```bash
# Do this one user at a time after notifying the user.
USER_NAME=<username>
OLD=/home/$USER_NAME/miniforge3
NEW=/home/$USER_NAME/miniconda3
BACKUP=/home/$USER_NAME/conda-migration-backups/$(date +%Y%m%d-%H%M%S)

sudo -u "$USER_NAME" mkdir -p "$BACKUP"
sudo -u "$USER_NAME" "$OLD/bin/conda" env list

# Snapshot each old environment before cloning.
for ENV_DIR in "$OLD"/envs/*; do
  [ -d "$ENV_DIR/conda-meta" ] || continue
  ENV_NAME=$(basename "$ENV_DIR")
  sudo -u "$USER_NAME" "$OLD/bin/conda" env export -p "$ENV_DIR" | sudo -u "$USER_NAME" tee "$BACKUP/$ENV_NAME.yml" > /dev/null
  sudo -u "$USER_NAME" "$OLD/bin/conda" list --explicit -p "$ENV_DIR" | sudo -u "$USER_NAME" tee "$BACKUP/$ENV_NAME-explicit.txt" > /dev/null
  [ -x "$ENV_DIR/bin/pip" ] && sudo -u "$USER_NAME" "$ENV_DIR/bin/pip" freeze | sudo -u "$USER_NAME" tee "$BACKUP/$ENV_NAME-pip-freeze.txt" > /dev/null
done

sudo -u "$USER_NAME" bash /opt/miniconda-installer/Miniconda3-Linux-x86_64.sh -b -p "$NEW"
sudo -u "$USER_NAME" "$NEW/bin/conda" init bash
sudo -u "$USER_NAME" "$NEW/bin/conda" config --system --remove-key channels 2>/dev/null || true
sudo -u "$USER_NAME" "$NEW/bin/conda" config --system --add channels conda-forge
sudo -u "$USER_NAME" "$NEW/bin/conda" config --remove-key channels 2>/dev/null || true
sudo -u "$USER_NAME" "$NEW/bin/conda" config --add channels conda-forge
sudo -u "$USER_NAME" "$NEW/bin/conda" config --set auto_activate_base false
sudo -u "$USER_NAME" "$NEW/bin/conda" config --remove-key create_default_packages 2>/dev/null || true
sudo -u "$USER_NAME" "$NEW/bin/conda" config --add create_default_packages python=3.11
sudo -u "$USER_NAME" "$NEW/bin/conda" config --add create_default_packages pip
sudo -u "$USER_NAME" "$NEW/bin/conda" config --add create_default_packages ipykernel

for ENV_DIR in "$OLD"/envs/*; do
  [ -d "$ENV_DIR/conda-meta" ] || continue
  ENV_NAME=$(basename "$ENV_DIR")
  sudo -u "$USER_NAME" "$NEW/bin/conda" create -y -p "$NEW/envs/$ENV_NAME" --clone "$ENV_DIR"
  sudo -u "$USER_NAME" "$NEW/bin/conda" run -p "$NEW/envs/$ENV_NAME" python --version
done
```

Keep `/home/<username>/miniforge3` until that user confirms their migrated environments work.

---

## Phase 10: Coordination tools

```bash
sudo apt install -y pipx
sudo PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install nvitop
sudo chmod -R a+rX /opt/pipx

sudo touch /srv/shared/RESERVATIONS.md
sudo chown root:labshared /srv/shared/RESERVATIONS.md
sudo chmod 664 /srv/shared/RESERVATIONS.md
```

---

## Phase 11: Restrict non-admin users

Disable Update Manager autostart for non-admin users:
```bash
# Disable for future users via skel:
sudo mkdir -p /etc/skel/.config/autostart
sudo chmod 755 /etc/skel/.config /etc/skel/.config/autostart
sudo tee /etc/skel/.config/autostart/mintupdate.desktop > /dev/null << 'EOF'
[Desktop Entry]
X-GNOME-Autostart-enabled=false
Hidden=true
EOF
sudo chmod 644 /etc/skel/.config/autostart/mintupdate.desktop

# Disable for each existing new user:
# sudo mkdir -p /home/<user>/.config/autostart
# sudo cp /etc/skel/.config/autostart/mintupdate.desktop /home/<user>/.config/autostart/
# sudo chown -R <user>:<user> /home/<user>/.config/autostart
```

Restrict shutdown/restart to admin users only via polkit:
```bash
sudo tee /usr/share/polkit-1/rules.d/10-restrict-power.rules > /dev/null << 'EOF'
polkit.addRule(function(action, subject) {
    var validActions = [
        "org.freedesktop.login1.power-off",
        "org.freedesktop.login1.power-off-multiple-sessions",
        "org.freedesktop.login1.power-off-ignore-inhibit",
        "org.freedesktop.login1.reboot",
        "org.freedesktop.login1.reboot-multiple-sessions",
        "org.freedesktop.login1.reboot-ignore-inhibit",
        "org.freedesktop.login1.halt",
        "org.freedesktop.login1.halt-multiple-sessions",
        "org.freedesktop.login1.halt-ignore-inhibit"
    ];
    if (validActions.indexOf(action.id) >= 0) {
        // Replace these with the admin usernames for this machine:
        if (subject.user == "jalal" || subject.user == "admin") {
            return polkit.Result.YES;
        }
        return polkit.Result.NO;
    }
});
EOF
sudo chmod 644 /usr/share/polkit-1/rules.d/10-restrict-power.rules
sudo systemctl restart polkit
```

**IMPORTANT:** The polkit rule file MUST be chmod 644, not 600. If root creates a file with umask 077, polkit won't be able to read it and the rule will be silently ignored.

---

## Phase 12: Onboarding doc + desktop integration

Use the same onboarding structure on every workstation. Start from `linux-mint-onboarding-template.md` in this repository and fill only the machine-specific placeholders:
- Hostname, admin contact, CPU, RAM, GPU, VRAM, NVIDIA driver, driver-supported CUDA, installed CUDA Toolkit, storage layout, shared folder location, resource limits, and installed tools.
- Keep the same headings and order across machines.
- Write both `/srv/shared/ONBOARDING.md` and `/srv/shared/ONBOARDING.html` with the same content.
- The HTML version must use a readable dark theme and copy-to-clipboard buttons on code blocks.
- The guide is for users who may not be technically experienced. Keep the wording explicit and step-by-step.
- Include the tmux section from the template so SSH users know how to keep experiments running after disconnects.

Put desktop shortcuts for onboarding AND shared folder on every user's desktop:
```bash
sudo mkdir -p /etc/skel/Desktop
sudo chmod 755 /etc/skel/Desktop

# Onboarding shortcut
sudo tee /etc/skel/Desktop/onboarding.desktop > /dev/null << 'EOF'
[Desktop Entry]
Name=Onboarding Guide
Comment=Read this first
Exec=xdg-open /srv/shared/ONBOARDING.html
Icon=text-html
Terminal=false
Type=Application
EOF
sudo chmod 755 /etc/skel/Desktop/onboarding.desktop

# Shared folder shortcut
sudo tee /etc/skel/Desktop/shared-folder.desktop > /dev/null << 'EOF'
[Desktop Entry]
Name=Shared Data
Comment=Lab shared folder (/srv/shared)
Exec=nemo /srv/shared
Icon=folder-publicshare
Terminal=false
Type=Application
EOF
sudo chmod 755 /etc/skel/Desktop/shared-folder.desktop

# Copy to existing new users:
# sudo mkdir -p /home/<user>/Desktop
# sudo cp /etc/skel/Desktop/*.desktop /home/<user>/Desktop/
# sudo chown -R <user>:<user> /home/<user>/Desktop
```

Add shared folder bookmark to file manager sidebar:
```bash
# For future users via skel:
sudo mkdir -p /etc/skel/.config/gtk-3.0
sudo chmod 755 /etc/skel/.config /etc/skel/.config/gtk-3.0
sudo tee /etc/skel/.config/gtk-3.0/bookmarks > /dev/null << 'EOF'
file:///srv/shared Shared Data
EOF
sudo chmod 644 /etc/skel/.config/gtk-3.0/bookmarks

# For existing new users:
# sudo mkdir -p /home/<user>/.config/gtk-3.0
# sudo bash -c 'echo "file:///srv/shared Shared Data" >> /home/<user>/.config/gtk-3.0/bookmarks'
# sudo chown -R <user>:<user> /home/<user>/.config/gtk-3.0
```

Auto-open onboarding on first login:
```bash
sudo tee /usr/local/bin/onboarding-firstlogin.sh > /dev/null << 'EOF'
#!/bin/bash
FLAG="$HOME/.onboarding-done"
if [ ! -f "$FLAG" ]; then
    sleep 3
    xdg-open /srv/shared/ONBOARDING.html &
    touch "$FLAG"
fi
EOF
sudo chmod 755 /usr/local/bin/onboarding-firstlogin.sh

sudo tee /etc/xdg/autostart/onboarding.desktop > /dev/null << 'EOF'
[Desktop Entry]
Name=Onboarding Guide
Exec=/usr/local/bin/onboarding-firstlogin.sh
Terminal=false
Type=Application
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF
sudo chmod 644 /etc/xdg/autostart/onboarding.desktop
```

---

## Phase 13: Disable sleep and configure screen timeout

Prevent the machine from sleeping/suspending (critical for long-running ML jobs):

```bash
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
```

Set screen to turn off after 30 minutes for all users (via dconf):

```bash
sudo mkdir -p /etc/dconf/profile /etc/dconf/db/local.d

echo -e "user-db:user\nsystem-db:local" | sudo tee /etc/dconf/profile/user > /dev/null
sudo chmod 644 /etc/dconf/profile/user

echo -e "[org/cinnamon/settings-daemon/plugins/power]\nsleep-display-ac=1800\nsleep-display-battery=1800" | sudo tee /etc/dconf/db/local.d/01-power > /dev/null
sudo chmod 644 /etc/dconf/db/local.d/01-power

sudo dconf update
sudo chmod 644 /etc/dconf/db/local
```

**IMPORTANT:** All four `chmod 644` lines are required — UMASK 077 makes root-created files unreadable by default.

Verify (should print `1800` with no warnings):
```bash
gsettings get org.cinnamon.settings-daemon.plugins.power sleep-display-ac
```

---

## Phase 14: Remote Desktop (xrdp)

Install xrdp so users can connect via RDP from Windows, macOS, or Linux:

```bash
sudo apt install -y xrdp
sudo systemctl enable xrdp
sudo ufw allow 3389/tcp
```

Verify:
```bash
sudo systemctl status xrdp | grep Active
sudo ufw status | grep 3389
```

---

## Phase 15: Final audit

Run a comprehensive check of everything:
- All user homes are chmod 700
- UMASK is 077, DIR_MODE is 0700
- UFW active with only SSH (no stale rules from removed software)
- nvidia-smi works
- CUDA Toolkit is installed intentionally (`nvcc --version` shows expected toolkit version, `CUDA_HOME` points to `/usr/local/cuda-<version>`)
- labshared group has all users
- /srv/shared has correct ACLs and setgid
- systemd limits are active (check with systemctl show)
- podman GPU test passes (run as regular user, not sudo)
- nvitop is accessible by regular users (check permissions on /opt/pipx)
- shared ML env works (PyTorch + CUDA + all packages)
- conda works for each new user (test with interactive shell: `sudo su - <user> -c 'bash -ic "conda --version"'`)
- onboarding desktop shortcut exists for all users, owned by the user, chmod 755
- shared-folder desktop shortcut exists for all users, owned by the user, chmod 755
- shared folder bookmark in file manager for all users
- autostart onboarding.desktop is chmod 644 (NOT 600)
- polkit power rules file is chmod 644 (NOT 600)
- Update Manager disabled for non-admin users
- No leftover NOPASSWD sudoers file
- All /etc/profile.d/ scripts are chmod 644
- All files in /etc/xdg/autostart/ are chmod 644
- `/etc/skel/Desktop`, `/etc/skel/.config/autostart`, and `/etc/skel/.config/gtk-3.0` are readable/traversable by future users (chmod 755)
- Sleep/suspend/hibernate targets are masked (systemctl status sleep.target should show "masked")
- dconf profile and power config are chmod 644 (no permission warnings)
- Screen timeout is 1800 seconds (gsettings get org.cinnamon.settings-daemon.plugins.power sleep-display-ac)
- xrdp is running and enabled (systemctl status xrdp)
- UFW allows port 3389/tcp
- All files in /etc/apt/sources.list.d/ are chmod 644 (NOT 600)

Fix any issues found. Then remove the temporary NOPASSWD entry:
```bash
sudo rm /etc/sudoers.d/claude-temp
```

---

## When done

Summarize:
- What was changed
- What to communicate to other users
- What each new user needs to do on first login
- Any phase that didn't go cleanly and what to follow up on
