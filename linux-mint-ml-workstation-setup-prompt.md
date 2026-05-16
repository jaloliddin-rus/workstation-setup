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

# GPU health (note the "Persistence-M" column — On means Phase 3 has nothing to do)
nvidia-smi
nvidia-smi --query-gpu=persistence_mode --format=csv 2>/dev/null
systemctl is-enabled nvidia-persistenced 2>/dev/null || true

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

Install Node.js system-wide via NodeSource (the distro `npm` package is outdated):
```bash
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | \
  sudo gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
sudo chmod 644 /etc/apt/keyrings/nodesource.gpg

echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" | \
  sudo tee /etc/apt/sources.list.d/nodesource.list
sudo chmod 644 /etc/apt/sources.list.d/nodesource.list

sudo apt update
sudo apt install -y nodejs
node --version && npm --version
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

## Phase 3: NVIDIA driver health and persistence mode

If `nvidia-smi` worked in Phase 0, the driver itself is fine. Note the "CUDA Version" from `nvidia-smi` — that's the maximum CUDA toolkit version users can run.

If `nvidia-smi` failed in Phase 0, stop and tell me — I'll fix the driver via the Driver Manager GUI before continuing.

Enable NVIDIA persistence mode. Without it, every new CUDA process pays a 1–3 second driver-init penalty and the GPU's clock/power state churns whenever users start and stop work — a real annoyance on a multi-tenant box. The `nvidia-persistenced` service ships with the proprietary driver; whether it is already enabled depends on which driver package the machine was installed with. Run the enable command regardless — it is idempotent.

```bash
sudo systemctl enable --now nvidia-persistenced
```

Verify:
```bash
systemctl is-active nvidia-persistenced
nvidia-smi --query-gpu=persistence_mode --format=csv
```

`nvidia-smi --query-gpu=persistence_mode` should print `Enabled` for every GPU. The "Persistence-M" column of plain `nvidia-smi` output should show `On`.

If `systemctl enable` fails with "Unit nvidia-persistenced.service not found", the driver package doesn't ship the service unit (rare — happens with some open-kernel-module variants). Fall back to `sudo apt install -y nvidia-persistenced`, or as a temporary measure run `sudo nvidia-smi -pm 1` (this is per-boot only and must be re-run after reboot).

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

## Phase 5b: Per-user directories on secondary drive

Create private per-user directories on the secondary drive so users have overflow storage:

```bash
sudo mkdir -p /mnt/data/users
sudo chmod 755 /mnt/data/users

# For each existing user:
sudo mkdir -p /mnt/data/users/<username>
sudo chown <username>:<username> /mnt/data/users/<username>
sudo chmod 700 /mnt/data/users/<username>
```

Auto-create for future users on first login:
```bash
sudo tee /etc/profile.d/user-data-dir.sh > /dev/null << 'EOF'
if [ "$(id -u)" -ge 1000 ] && [ -d /mnt/data/users ] && [ -z "$_USER_DATA_DIR_DONE" ]; then
    _USER_DATA_DIR_DONE=1
    export _USER_DATA_DIR_DONE
    USER_DATA="/mnt/data/users/$(id -un)"

    if [ ! -d "$USER_DATA" ]; then
        mkdir -p "$USER_DATA"
        chmod 700 "$USER_DATA"
    fi

    if [ -d "$HOME/Desktop" ] && [ ! -f "$HOME/Desktop/my-data.desktop" ]; then
        cat > "$HOME/Desktop/my-data.desktop" << INNER
[Desktop Entry]
Name=My Data Storage
Comment=Your personal directory on the secondary drive (/mnt/data)
Exec=nemo $USER_DATA
Icon=folder
Terminal=false
Type=Application
INNER
        chmod 755 "$HOME/Desktop/my-data.desktop"
    fi

    if [ -d "$HOME/.config/gtk-3.0" ] && ! grep -q "/mnt/data/users/" "$HOME/.config/gtk-3.0/bookmarks" 2>/dev/null; then
        echo "file://$USER_DATA My Data Storage" >> "$HOME/.config/gtk-3.0/bookmarks"
    fi
fi
EOF
sudo chmod 644 /etc/profile.d/user-data-dir.sh
```

Add desktop shortcut and file manager bookmark for each existing user:
```bash
# For each user, create ~/Desktop/my-data.desktop pointing to /mnt/data/users/<username>
# and append bookmark to ~/.config/gtk-3.0/bookmarks
```

---

## Phase 5c: Disk quotas and new-user automation

Install quota tools and enable soft quotas on the root partition (where /home lives):

```bash
sudo apt install -y quota
# Ensure /etc/fstab has usrquota option on the root partition, then:
sudo mount -o remount /
sudo quotacheck -cum /
sudo quotaon /
```

Set a 200G soft limit (warning only, no hard block) for each standard user:
```bash
sudo setquota -u <username> 200G 0 0 0 /
```

Skip admin users — they have no limit.

Deploy a login warning so users see a message every terminal session when they are over quota:
```bash
sudo tee /etc/profile.d/quota-warn.sh > /dev/null << 'EOF'
if [ "$(id -u)" -ge 1000 ] && command -v quota >/dev/null 2>&1; then
    _quota_out="$(quota -s 2>/dev/null)"
    if printf '%s\n' "$_quota_out" | grep -q '\*'; then
        _used="$(printf '%s\n' "$_quota_out" | awk '/\*/ {gsub(/\*/, "", $2); print $2}')"
        _soft="$(printf '%s\n' "$_quota_out" | awk '/\*/ {print $3}')"
        printf '\n*** Disk quota warning: you are using %s of your %s soft limit on /home.\n' "$_used" "$_soft"
        printf '    Move large files to /data/users/%s to free space.\n' "$(id -un)"
        printf '    Run: quota -s   for details.\n\n'
    fi
    unset _quota_out _used _soft
fi
EOF
sudo chmod 644 /etc/profile.d/quota-warn.sh
```

**Automate all new-user setup** with `/usr/local/sbin/adduser.local` (hook called by `adduser` after creating a user):

```bash
sudo tee /usr/local/sbin/adduser.local > /dev/null << 'EOF'
#!/bin/bash
USERNAME="$1"
UID_NUM="$2"
HOME_DIR="$4"

[ "$UID_NUM" -ge 1000 ] || exit 0

usermod -aG labshared "$USERNAME" 2>/dev/null
setquota -u "$USERNAME" 200G 0 0 0 / 2>/dev/null

if [ -d /mnt/data/users ]; then
    mkdir -p "/mnt/data/users/$USERNAME"
    chown "$USERNAME:$USERNAME" "/mnt/data/users/$USERNAME"
    chmod 700 "/mnt/data/users/$USERNAME"
fi

exit 0
EOF
sudo chmod 755 /usr/local/sbin/adduser.local
```

This eliminates all manual steps when creating users — `sudo adduser <username>` now automatically:
- Adds user to `labshared` group
- Sets 200G soft quota on /home
- Creates private `/mnt/data/users/<username>` directory

---

## Phase 6: Memory pressure tuning for ML workloads

PyTorch DataLoader workers reproducibly freeze a vanilla Linux Mint box when iterating over large datasets: default `vm.overcommit_memory=0` + `vm.swappiness=60` lets forked workers blow past memory pressure thresholds, the in-kernel OOM killer arrives too late to save the desktop, and systemd's default user-slice cap (~70% of RAM) wastes memory on a dedicated ML workstation.

The four subsections below — kernel sysctl, zswap, earlyoom, and raised user-slice limits — work as one coordinated fix. Apply them together.

### Kernel sysctl tuning

Create `/etc/sysctl.d/99-ml-workstation.conf`. Compute `vm.min_free_kbytes` as ~0.2% of total RAM (reference: 128 GB → `262144`, 64 GB → `131072`, 32 GB → `65536`):

```bash
python3 -c "import os; print(int(os.sysconf('SC_PHYS_PAGES') * os.sysconf('SC_PAGE_SIZE') * 0.002 / 1024))"
```

```ini
vm.swappiness = 10
vm.overcommit_memory = 2
vm.overcommit_ratio = 95
vm.min_free_kbytes = <SCALED_TO_RAM>
vm.vfs_cache_pressure = 50
vm.dirty_bytes = 524288000
vm.dirty_background_bytes = 262144000
```

```bash
sudo sysctl --system
```

No reboot needed for this part. **Caveat:** `vm.overcommit_memory=2` disables overcommit — allocations beyond `(swap + RAM × overcommit_ratio / 100)` fail immediately. This is what stops DataLoader from fork-bombing the box, but workloads that lean on overcommit (some JVM heap configurations, certain CUDA pinned-memory paths, large sparse `mmap`s) may surface `Cannot allocate memory` errors. Revisit these values per-workload if that happens.

### Enable zswap

Edit `/etc/default/grub` and set:

```text
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash zswap.enabled=1 zswap.shrinker_enabled=1 zswap.compressor=lz4 zswap.max_pool_percent=30 zswap.accept_threshold_percent=80 zswap.zpool=zsmalloc"
```

```bash
sudo update-grub
```

**Reboot required for zswap to activate.** Per the working agreement, pause here and tell me before rebooting — the other phases can finish first.

### earlyoom userspace OOM killer

```bash
sudo apt install -y earlyoom
sudo systemctl enable --now earlyoom
```

`earlyoom` watches available memory and kills the heaviest process before the kernel OOM path freezes the desktop.

### Raise systemd user-slice limits

**Scale these to the actual hardware** found in Phase 0:
- CPUQuota: (total_cores - 1) * 100 — reserves 1 core for system, dynamic fair-share
- MemoryHigh: 95% of total RAM (soft limit) — raised from the conservative 70% default since this is a dedicated ML box and earlyoom + sysctl tuning above now handle pressure safely
- MemoryMax: 97% of total RAM (hard kill)

Create `/etc/systemd/system/user-.slice.d/limits.conf` (the `user-.slice.d` template form applies to every regular user — do **not** switch to `user-$(id -u).slice.d/` which would only cover one UID):

```ini
[Slice]
MemoryHigh=95%
MemoryMax=97%
CPUQuota=<scaled>
TasksMax=4096
```

```bash
sudo systemctl daemon-reload
```

### Verify Phase 6

```bash
sysctl vm.swappiness vm.overcommit_memory vm.overcommit_ratio vm.min_free_kbytes
grep -r . /sys/module/zswap/parameters/
systemctl is-active earlyoom
systemctl show user-$(id -u).slice | grep -E 'MemoryHigh=|MemoryMax=|CPUQuota=|TasksMax='
```

Zswap parameters only show as enabled after reboot. The `systemctl show user-$(id -u).slice` command needs an active login session for that UID — if you're running over `sudo su` with no graphical session for the operator account, log in first or check from a real user shell. Everything else should be live immediately.

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

Add a login-shell warning that names **other** users currently running CUDA processes (with per-user GPU memory) so people remember to check nvitop and coordinate before kicking off another large job:

```bash
sudo tee /etc/profile.d/gpu-active-warn.sh > /dev/null << 'EOF'
if [ "$(id -u)" -ge 1000 ] && command -v nvidia-smi >/dev/null 2>&1; then
    _me="$(id -un)"
    _summary="$(nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits 2>/dev/null | \
        awk -F',' -v me="$_me" '
        {
            gsub(/ /, "", $1); gsub(/ /, "", $2)
            user = ""
            cmd = "ps -o user= -p " $1 " 2>/dev/null"
            cmd | getline user; close(cmd)
            gsub(/[ \n]/, "", user)
            if (user != "" && user != me) mb[user] += $2
        }
        END {
            for (u in mb) printf "%s (%.1f GB), ", u, mb[u]/1024
        }' | sed 's/, $//')"
    if [ -n "$_summary" ]; then
        printf '\n*** GPU is currently in use by: %s\n' "$_summary"
        printf '    Run: nvitop   to see what they are running.\n'
        printf '    Coordinate large jobs via /srv/shared/RESERVATIONS.md before starting.\n\n'
    fi
    unset _me _summary
fi
EOF
sudo chmod 644 /etc/profile.d/gpu-active-warn.sh
```

The script only looks at **compute** processes (`--query-compute-apps`), so idle Xorg/desktop graphics don't trigger the warning. The current user's own training is filtered out. `nvidia-smi` adds ~200 ms to login-shell startup; this only runs on login shells (not subshells), so it fires once per "I sat down at the terminal", not every command.

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
- `HOSTNAME`, `OS_VERSION`, `CPU_SUMMARY`, `RAM_SUMMARY`, `GPU_SUMMARY`, `NVIDIA_DRIVER`, `DRIVER_CUDA`, `CUDA_TOOLKIT`
- `ADMIN_CONTACT`, `HOME_QUOTA`, `DATA_DRIVE_TOTAL`
- `USER_DATA_BASE` — the base path for per-user overflow dirs (e.g. `/data/users` or `/mnt/data/users`)
- `EXTRA_STORAGE_LOCATION`, `EXTRA_STORAGE_DESCRIPTION` — any additional storage row in the table
- `CPU_LIMIT`, `MEMORY_HIGH`, `MEMORY_MAX`, `TASKS_MAX`

Keep the same headings and order across machines. Write both `/srv/shared/ONBOARDING.md` (plain text) and `/srv/shared/ONBOARDING.html`. The HTML version must:
- Use a readable dark theme
- Include copy-to-clipboard buttons on all code blocks
- Include a sticky left-sidebar table of contents auto-generated from headings
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

Out of the box, xrdp on Linux Mint is sluggish over the network and orphans sessions when the client window closes (subsequent reconnects spawn fresh sessions instead of reattaching). Tune `xrdp.ini` and `sesman.ini` before users start connecting.

### Performance — /etc/xrdp/xrdp.ini

In the `[Globals]` section, set:

```ini
crypt_level=low
tcp_send_buffer_bytes=4194304
tcp_recv_buffer_bytes=4194304
```

RDP-layer encryption is CPU-heavy. `crypt_level=low` is appropriate **only** when the workstation is reached over a trusted LAN — anyone with packet-capture access to that network segment could observe session contents and the password used at login. The onboarding template tells users to tunnel off-site connections through SSH (`ssh -L 3389:localhost:3389 user@host`); if you decide this LAN is not trusted, raise `crypt_level` instead.

Make sure the `[Xorg]` session block appears **before** `[Xvnc]` in the file — xrdp picks the first matching backend, and xorgxrdp is dramatically faster than Xvnc. The Ubuntu/Mint default order is already correct; verify rather than assume.

Apply with sed (back up first, then edit; the substitutions assume Ubuntu/Mint's default xrdp.ini which already contains a `crypt_level=` line):

```bash
sudo cp /etc/xrdp/xrdp.ini /etc/xrdp/xrdp.ini.bak

sudo sed -i 's/^crypt_level=.*/crypt_level=low/' /etc/xrdp/xrdp.ini

# Insert TCP buffer lines into [Globals] only if missing (idempotent for re-runs):
grep -q '^tcp_send_buffer_bytes=' /etc/xrdp/xrdp.ini || \
  sudo sed -i '/^\[Globals\]/a tcp_send_buffer_bytes=4194304' /etc/xrdp/xrdp.ini
grep -q '^tcp_recv_buffer_bytes=' /etc/xrdp/xrdp.ini || \
  sudo sed -i '/^\[Globals\]/a tcp_recv_buffer_bytes=4194304' /etc/xrdp/xrdp.ini

# Verify [Xorg] appears before [Xvnc]:
grep -n '^\[Xorg\]\|^\[Xvnc\]' /etc/xrdp/xrdp.ini
```

### Reconnect behavior — /etc/xrdp/sesman.ini

In the `[Sessions]` section:

```ini
KillDisconnected=false
DisconnectedTimeLimit=0
IdleTimeLimit=0
Policy=Default
```

`Policy=Default` matches sessions on User + BitPerPixel only — the loosest matching policy, which is what makes reconnects reliably reattach to the existing session. Stricter policies like `UBDC` (User + BitPerPixel + Display + Client) match too tightly and spawn a fresh session almost every reconnect. The other three keys keep the session alive when the client window closes and disable auto-reap on idle.

```bash
sudo cp /etc/xrdp/sesman.ini /etc/xrdp/sesman.ini.bak

sudo sed -i \
  -e 's/^KillDisconnected=.*/KillDisconnected=false/' \
  -e 's/^DisconnectedTimeLimit=.*/DisconnectedTimeLimit=0/' \
  -e 's/^IdleTimeLimit=.*/IdleTimeLimit=0/' \
  -e 's/^Policy=.*/Policy=Default/' \
  /etc/xrdp/sesman.ini
```

### Apply and verify

```bash
sudo systemctl restart xrdp

sudo systemctl status xrdp | grep Active
sudo ufw status | grep 3389
grep -E '^(crypt_level|tcp_send_buffer_bytes|tcp_recv_buffer_bytes)=' /etc/xrdp/xrdp.ini
grep -E '^(KillDisconnected|DisconnectedTimeLimit|IdleTimeLimit|Policy)=' /etc/xrdp/sesman.ini
```

### Troubleshooting stuck sessions

If a user can't reconnect because a session is wedged, this is much lighter than a reboot:

```bash
sudo pkill -9 -u <username> -f 'Xorg|xrdp-chansrv|xrdp-sesman'
sudo systemctl restart user@$(id -u <username>).service
sudo systemctl restart xrdp
```

This clears orphan processes, resets the user's systemd/dbus runtime (the thing that prevents Cinnamon from restarting cleanly), and restarts xrdp. If that still doesn't help, check `~/.xsession-errors` and `/var/log/xrdp-sesman.log` — a `Window manager exited quickly` line in the sesman log means `startwm.sh` is dying and the real reason will be in xsession-errors.

Cinnamon's compositor is genuinely heavy over RDP. If a machine consistently feels slow despite the tuning above, swapping the user session to MATE or XFCE is the next lever, but is not part of the default setup.

---

## Phase 15: Final audit

Run a comprehensive check of everything:
- All user homes are chmod 700
- UMASK is 077, DIR_MODE is 0700
- UFW active with only SSH (no stale rules from removed software)
- nvidia-smi works
- `nvidia-persistenced` service is active and enabled (`systemctl is-active nvidia-persistenced && systemctl is-enabled nvidia-persistenced`)
- `nvidia-smi --query-gpu=persistence_mode --format=csv` reports `Enabled` for every GPU
- CUDA Toolkit is installed intentionally (`nvcc --version` shows expected toolkit version, `CUDA_HOME` points to `/usr/local/cuda-<version>`)
- labshared group has all users
- /srv/shared has correct ACLs and setgid
- systemd limits are active (check with systemctl show) — `MemoryHigh` shows 95% of RAM and `MemoryMax` shows 97% of RAM (not the old 70/85% values)
- `/etc/sysctl.d/99-ml-workstation.conf` exists and values are applied (`sysctl vm.swappiness vm.overcommit_memory vm.overcommit_ratio vm.min_free_kbytes`)
- zswap is enabled at runtime (`cat /sys/module/zswap/parameters/enabled` shows `Y` — only after the GRUB reboot)
- `earlyoom` service is active and enabled (`systemctl is-active earlyoom && systemctl is-enabled earlyoom`)
- podman GPU test passes (run as regular user, not sudo)
- nvitop is accessible by regular users (check permissions on /opt/pipx)
- `/etc/profile.d/gpu-active-warn.sh` exists, chmod 644, and prints when another user has a CUDA process running (test: have a second user start `python -c "import torch; torch.zeros(1).cuda(); input()"`, then open a fresh login shell as a different user)
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
- `/etc/xrdp/xrdp.ini` has `crypt_level=low`, `tcp_send_buffer_bytes=4194304`, `tcp_recv_buffer_bytes=4194304` in `[Globals]`
- `[Xorg]` section appears before `[Xvnc]` in `/etc/xrdp/xrdp.ini` (`grep -n '^\[Xorg\]\|^\[Xvnc\]' /etc/xrdp/xrdp.ini`)
- `/etc/xrdp/sesman.ini` has `KillDisconnected=false`, `DisconnectedTimeLimit=0`, `IdleTimeLimit=0`, `Policy=Default` in `[Sessions]`
- Backups exist at `/etc/xrdp/xrdp.ini.bak` and `/etc/xrdp/sesman.ini.bak`
- Node.js and npm are installed system-wide (`node --version`, `npm --version`)
- Secondary drive is ext4 with `usrquota,acl` in fstab (`mount | grep /mnt/data`)
- `/mnt/data` is chmod 755 (not 777)
- `/mnt/data/users/` exists, chmod 755, with a private dir (700) per user
- Disk quotas are active (`repquota /` shows soft limits for standard users)
- `/usr/local/sbin/adduser.local` exists, chmod 755, automates group + quota + data dir
- `/etc/profile.d/user-data-dir.sh` is chmod 644
- My Data Storage desktop shortcut exists for all users
- My Data Storage bookmark in file manager for all users
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
