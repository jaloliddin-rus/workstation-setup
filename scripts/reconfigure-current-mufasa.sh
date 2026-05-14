#!/usr/bin/env bash
set -euo pipefail

TARGET_USER="${TARGET_USER:-jalal}"
USER_ONLY="${USER_ONLY:-0}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
OLD_CONDA="$TARGET_HOME/miniforge3"
NEW_CONDA="$TARGET_HOME/miniconda3"
MINICONDA_INSTALLER="/tmp/Miniconda3-latest-Linux-x86_64.sh"
MINICONDA_URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$REPO_DIR/linux-mint-onboarding-template.md"
BACKUP_DIR="$TARGET_HOME/conda-migration-backups/$(date +%Y%m%d-%H%M%S)"

log() {
  printf '\n== %s ==\n' "$*"
}

require_target_user() {
  if [ "$(id -un)" != "$TARGET_USER" ]; then
    echo "Run this script as $TARGET_USER so user-owned Conda files stay owned by $TARGET_USER." >&2
    exit 1
  fi
}

require_sudo() {
  if ! sudo -n true 2>/dev/null; then
    echo "Passwordless sudo is required for system-wide setup in this run." >&2
    exit 1
  fi
}

download_miniconda() {
  log "Downloading Miniconda installer"
  if [ ! -s "$MINICONDA_INSTALLER" ]; then
    curl -fsSL -o "$MINICONDA_INSTALLER" "$MINICONDA_URL"
  fi
  chmod 755 "$MINICONDA_INSTALLER"
}

snapshot_old_envs() {
  if [ ! -x "$OLD_CONDA/bin/conda" ]; then
    log "No Miniforge install found at $OLD_CONDA; skipping old-env snapshots"
    return
  fi

  log "Snapshotting existing Miniforge environments"
  mkdir -p "$BACKUP_DIR"
  "$OLD_CONDA/bin/conda" env list | tee "$BACKUP_DIR/env-list.txt" >/dev/null

  shopt -s nullglob
  for env_dir in "$OLD_CONDA"/envs/*; do
    [ -d "$env_dir/conda-meta" ] || continue
    env_name="$(basename "$env_dir")"
    "$OLD_CONDA/bin/conda" env export -p "$env_dir" > "$BACKUP_DIR/$env_name.yml"
    "$OLD_CONDA/bin/conda" list --explicit -p "$env_dir" > "$BACKUP_DIR/$env_name-explicit.txt"
    if [ -x "$env_dir/bin/pip" ]; then
      "$env_dir/bin/pip" freeze > "$BACKUP_DIR/$env_name-pip-freeze.txt"
    fi
  done
  shopt -u nullglob
}

install_user_miniconda() {
  log "Installing and configuring user Miniconda"
  mkdir -p "$BACKUP_DIR"
  if [ ! -x "$NEW_CONDA/bin/conda" ]; then
    bash "$MINICONDA_INSTALLER" -b -p "$NEW_CONDA"
  fi

  "$NEW_CONDA/bin/conda" config --system --remove-key channels >/dev/null 2>&1 || true
  "$NEW_CONDA/bin/conda" config --system --add channels conda-forge
  "$NEW_CONDA/bin/conda" config --remove-key channels >/dev/null 2>&1 || true
  "$NEW_CONDA/bin/conda" config --add channels conda-forge
  "$NEW_CONDA/bin/conda" config --set auto_activate_base false
  "$NEW_CONDA/bin/conda" config --remove-key create_default_packages >/dev/null 2>&1 || true
  "$NEW_CONDA/bin/conda" config --add create_default_packages python=3.11
  "$NEW_CONDA/bin/conda" config --add create_default_packages pip
  "$NEW_CONDA/bin/conda" config --add create_default_packages ipykernel
  "$NEW_CONDA/bin/conda" init bash >/dev/null

  if grep -q "$OLD_CONDA" "$TARGET_HOME/.bashrc"; then
    cp "$TARGET_HOME/.bashrc" "$BACKUP_DIR/bashrc-before-miniconda-switch"
    sed -i "s#$OLD_CONDA#$NEW_CONDA#g" "$TARGET_HOME/.bashrc"
  fi
}

clone_old_envs() {
  if [ ! -x "$OLD_CONDA/bin/conda" ]; then
    return
  fi

  log "Cloning Miniforge environments into Miniconda"
  shopt -s nullglob
  for env_dir in "$OLD_CONDA"/envs/*; do
    [ -d "$env_dir/conda-meta" ] || continue
    env_name="$(basename "$env_dir")"
    target_env="$NEW_CONDA/envs/$env_name"
    if [ ! -d "$target_env/conda-meta" ]; then
      "$NEW_CONDA/bin/conda" create -y -p "$target_env" --clone "$env_dir"
    fi
    "$NEW_CONDA/bin/conda" run -p "$target_env" python --version
    "$NEW_CONDA/bin/conda" run -p "$target_env" python -m pip --version || echo "pip is not installed in cloned env $env_name; preserved old environment state."
  done
  shopt -u nullglob
}

verify_conda_defaults() {
  log "Verifying new Conda defaults include Python"
  local env_name="__smoke_defaults"
  "$NEW_CONDA/bin/conda" env remove -y -n "$env_name" >/dev/null 2>&1 || true
  "$NEW_CONDA/bin/conda" create -y -n "$env_name"
  "$NEW_CONDA/bin/conda" run -n "$env_name" python --version
  "$NEW_CONDA/bin/conda" run -n "$env_name" python -m pip --version
  "$NEW_CONDA/bin/conda" env remove -y -n "$env_name"
}

install_system_miniconda_assets() {
  log "Installing system Miniconda assets for future users"
  sudo mkdir -p /opt/miniconda-installer
  sudo install -m 755 "$MINICONDA_INSTALLER" /opt/miniconda-installer/Miniconda3-Linux-x86_64.sh

  if [ -f /etc/profile.d/miniforge-setup.sh ]; then
    sudo mv /etc/profile.d/miniforge-setup.sh "/etc/profile.d/miniforge-setup.sh.disabled.$(date +%Y%m%d-%H%M%S)"
  fi

  sudo install -m 644 /dev/stdin /etc/profile.d/miniconda-setup.sh <<'EOF'
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

  if [ -x /opt/conda-shared/bin/conda ]; then
    sudo /opt/conda-shared/bin/conda config --system --remove-key channels >/dev/null 2>&1 || true
    sudo /opt/conda-shared/bin/conda config --system --add channels conda-forge
    sudo /opt/conda-shared/bin/conda config --system --set auto_activate_base false
    sudo /opt/conda-shared/bin/conda config --system --remove-key create_default_packages >/dev/null 2>&1 || true
    sudo /opt/conda-shared/bin/conda config --system --add create_default_packages python=3.11
    sudo /opt/conda-shared/bin/conda config --system --add create_default_packages pip
    sudo /opt/conda-shared/bin/conda config --system --add create_default_packages ipykernel
  fi
}

install_cuda_toolkit() {
  log "Installing/configuring CUDA Toolkit 12.8"
  if [ ! -x /usr/local/cuda-12.8/bin/nvcc ]; then
    curl -fsSL -o /tmp/cuda-keyring_1.1-1_all.deb \
      https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
    sudo dpkg -i /tmp/cuda-keyring_1.1-1_all.deb
    sudo apt-get update
    sudo apt-get install -y cuda-toolkit-12-8
  fi

  sudo install -m 644 /dev/stdin /etc/profile.d/cuda-toolkit.sh <<'EOF'
export CUDA_HOME=/usr/local/cuda-12.8
export PATH="$CUDA_HOME/bin:$PATH"
export LD_LIBRARY_PATH="$CUDA_HOME/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
EOF
}

fix_desktop_integration_permissions() {
  log "Fixing skel desktop/autostart/bookmark permissions"
  sudo mkdir -p /etc/skel/Desktop /etc/skel/.config/autostart /etc/skel/.config/gtk-3.0
  sudo chmod 755 /etc/skel /etc/skel/Desktop /etc/skel/.config /etc/skel/.config/autostart /etc/skel/.config/gtk-3.0

  sudo install -m 755 /dev/stdin /etc/skel/Desktop/onboarding.desktop <<'EOF'
[Desktop Entry]
Name=Onboarding Guide
Comment=Read this first
Exec=xdg-open /srv/shared/ONBOARDING.html
Icon=text-html
Terminal=false
Type=Application
EOF

  sudo install -m 755 /dev/stdin /etc/skel/Desktop/shared-folder.desktop <<'EOF'
[Desktop Entry]
Name=Shared Data
Comment=Lab shared folder (/srv/shared)
Exec=nemo /srv/shared
Icon=folder-publicshare
Terminal=false
Type=Application
EOF

  sudo install -m 644 /dev/stdin /etc/skel/.config/gtk-3.0/bookmarks <<'EOF'
file:///srv/shared Shared Data
EOF
}

generate_onboarding() {
  log "Generating standardized onboarding"
  local tmp_md tmp_html
  tmp_md="$(mktemp)"
  tmp_html="$(mktemp)"

  HOSTNAME_VALUE="$(hostname)"
  OS_VERSION="$(lsb_release -ds 2>/dev/null || printf 'Linux Mint')"
  CPU_SUMMARY="$(lscpu | awk -F: '/Model name/ {gsub(/^[ \t]+/, "", $2); print $2; exit}') ($(nproc) threads)"
  RAM_SUMMARY="$(free -h | awk '/^Mem:/ {print $2}')"
  GPU_QUERY="$(nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader,nounits 2>/dev/null | head -1 || true)"
  if [ -n "$GPU_QUERY" ]; then
    GPU_NAME="$(printf '%s' "$GPU_QUERY" | awk -F, '{gsub(/^[ \t]+|[ \t]+$/, "", $1); print $1}')"
    GPU_MEM="$(printf '%s' "$GPU_QUERY" | awk -F, '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}')"
    NVIDIA_DRIVER="$(printf '%s' "$GPU_QUERY" | awk -F, '{gsub(/^[ \t]+|[ \t]+$/, "", $3); print $3}')"
    GPU_SUMMARY="$GPU_NAME (${GPU_MEM} MiB VRAM)"
  else
    GPU_SUMMARY="NVIDIA RTX A5500 (24 GB VRAM)"
    NVIDIA_DRIVER="$(awk '/NVRM version/ {print $8; exit}' /proc/driver/nvidia/version 2>/dev/null || printf 'unknown')"
  fi
  DRIVER_CUDA="$(nvidia-smi 2>/dev/null | sed -n 's/.*CUDA Version: *\([^ |]*\).*/\1/p' | head -1)"
  DRIVER_CUDA="${DRIVER_CUDA:-unknown}"
  CUDA_TOOLKIT="$(bash -lc 'source /etc/profile.d/cuda-toolkit.sh 2>/dev/null || true; nvcc --version 2>/dev/null' | sed -n 's/.*release \([^,]*\).*/\1/p' | head -1)"
  CUDA_TOOLKIT="${CUDA_TOOLKIT:-unknown}"
  EXTRA_STORAGE_LOCATION="/mnt/data"
  EXTRA_STORAGE_DESCRIPTION="$(df -h /mnt/data 2>/dev/null | awk 'NR==2 {print $2 " secondary data drive mounted at /mnt/data (" $4 " free)"}')"
  EXTRA_STORAGE_DESCRIPTION="${EXTRA_STORAGE_DESCRIPTION:-Secondary storage, if mounted on this machine.}"
  USER_DATA_BASE="/mnt/data/users"
  HOME_QUOTA="200G"
  DATA_DRIVE_TOTAL="$(df -h /mnt/data 2>/dev/null | awk 'NR==2 {print $2}')"
  DATA_DRIVE_TOTAL="${DATA_DRIVE_TOTAL:-unknown}"
  CPU_LIMIT="$(($(nproc) - 1)) CPU threads reserved for users, with 1 thread left for the system"
  MEMORY_HIGH="about 88 GB"
  MEMORY_MAX="about 106 GB"
  TASKS_MAX="4096"
  ADMIN_CONTACT="jalal or admin"

  export HOSTNAME_VALUE OS_VERSION CPU_SUMMARY RAM_SUMMARY GPU_SUMMARY NVIDIA_DRIVER DRIVER_CUDA CUDA_TOOLKIT
  export EXTRA_STORAGE_LOCATION EXTRA_STORAGE_DESCRIPTION USER_DATA_BASE HOME_QUOTA DATA_DRIVE_TOTAL
  export CPU_LIMIT MEMORY_HIGH MEMORY_MAX TASKS_MAX ADMIN_CONTACT TEMPLATE tmp_md tmp_html

  python3 - <<'PY'
from html import escape
import os
import re

template = os.environ["TEMPLATE"]
with open(template, "r", encoding="utf-8") as f:
    text = f.read()

values = {
    "HOSTNAME": os.environ["HOSTNAME_VALUE"],
    "OS_VERSION": os.environ["OS_VERSION"],
    "CPU_SUMMARY": os.environ["CPU_SUMMARY"],
    "RAM_SUMMARY": os.environ["RAM_SUMMARY"],
    "GPU_SUMMARY": os.environ["GPU_SUMMARY"],
    "NVIDIA_DRIVER": os.environ["NVIDIA_DRIVER"],
    "DRIVER_CUDA": os.environ["DRIVER_CUDA"],
    "CUDA_TOOLKIT": os.environ["CUDA_TOOLKIT"],
    "EXTRA_STORAGE_LOCATION": os.environ["EXTRA_STORAGE_LOCATION"],
    "EXTRA_STORAGE_DESCRIPTION": os.environ["EXTRA_STORAGE_DESCRIPTION"],
    "USER_DATA_BASE": os.environ["USER_DATA_BASE"],
    "HOME_QUOTA": os.environ["HOME_QUOTA"],
    "DATA_DRIVE_TOTAL": os.environ["DATA_DRIVE_TOTAL"],
    "CPU_LIMIT": os.environ["CPU_LIMIT"],
    "MEMORY_HIGH": os.environ["MEMORY_HIGH"],
    "MEMORY_MAX": os.environ["MEMORY_MAX"],
    "TASKS_MAX": os.environ["TASKS_MAX"],
    "ADMIN_CONTACT": os.environ["ADMIN_CONTACT"],
}
for key, value in values.items():
    text = text.replace("{{" + key + "}}", value)

with open(os.environ["tmp_md"], "w", encoding="utf-8") as f:
    f.write(text)

def inline(s: str) -> str:
    s = escape(s)
    return re.sub(r"`([^`]+)`", r"<code>\1</code>", s)

lines = text.splitlines()
out = []
i = 0
code_id = 0
while i < len(lines):
    line = lines[i]
    if line.startswith("```"):
        lang = line[3:].strip()
        block = []
        i += 1
        while i < len(lines) and not lines[i].startswith("```"):
            block.append(lines[i])
            i += 1
        code_id += 1
        code = escape("\n".join(block))
        out.append(f'<div class="code-block"><button type="button" data-copy="code-{code_id}">Copy</button><pre><code id="code-{code_id}" class="language-{escape(lang)}">{code}</code></pre></div>')
    elif line.startswith("# "):
        out.append(f"<h1>{inline(line[2:])}</h1>")
    elif line.startswith("## "):
        out.append(f"<h2>{inline(line[3:])}</h2>")
    elif line.startswith("### "):
        out.append(f"<h3>{inline(line[4:])}</h3>")
    elif line.startswith("|"):
        table = []
        while i < len(lines) and lines[i].startswith("|"):
            table.append(lines[i])
            i += 1
        rows = [[cell.strip() for cell in row.strip("|").split("|")] for row in table]
        if len(rows) >= 2 and all(set(cell) <= {"-", ":", " "} for cell in rows[1]):
            out.append("<table><thead><tr>" + "".join(f"<th>{inline(c)}</th>" for c in rows[0]) + "</tr></thead><tbody>")
            for row in rows[2:]:
                out.append("<tr>" + "".join(f"<td>{inline(c)}</td>" for c in row) + "</tr>")
            out.append("</tbody></table>")
        else:
            out.extend(f"<p>{inline(row)}</p>" for row in table)
        continue
    elif line.strip():
        out.append(f"<p>{inline(line)}</p>")
    i += 1

html = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{escape(values["HOSTNAME"])} ML Workstation Onboarding</title>
  <style>
    :root {{ color-scheme: dark; --bg:#101418; --panel:#171d23; --text:#e8edf2; --muted:#8a9aaa; --line:#2c3742; --accent:#5dd3a5; --warn:#f0b45d; }}
    *, *::before, *::after {{ box-sizing: border-box; }}
    body {{ margin:0; font-family:Inter, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background:var(--bg); color:var(--text); line-height:1.6; display:flex; min-height:100vh; }}
    nav#toc {{ width:230px; min-width:230px; background:var(--panel); border-right:1px solid var(--line); position:sticky; top:0; height:100vh; overflow-y:auto; padding:24px 0 32px; flex-shrink:0; }}
    nav#toc .toc-title {{ font-size:0.7rem; font-weight:700; letter-spacing:.1em; text-transform:uppercase; color:var(--muted); padding:0 20px 10px; }}
    nav#toc a {{ display:block; padding:5px 20px; font-size:0.88rem; color:var(--muted); text-decoration:none; border-left:2px solid transparent; transition:color .15s, border-color .15s; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }}
    nav#toc a:hover {{ color:var(--text); }}
    nav#toc a.active {{ color:var(--accent); border-left-color:var(--accent); }}
    nav#toc a.toc-h3 {{ padding-left:32px; font-size:0.82rem; }}
    main {{ flex:1; max-width:900px; padding:32px 40px 56px; min-width:0; }}
    h1 {{ font-size:2rem; margin:0 0 14px; }}
    h2 {{ margin-top:34px; padding-top:18px; border-top:1px solid var(--line); font-size:1.35rem; scroll-margin-top:24px; }}
    h3 {{ margin-top:22px; font-size:1.1rem; scroll-margin-top:24px; }}
    p {{ color:var(--text); }}
    table {{ width:100%; border-collapse:collapse; margin:14px 0 20px; background:var(--panel); }}
    th, td {{ border:1px solid var(--line); padding:10px 12px; text-align:left; vertical-align:top; }}
    th {{ color:var(--accent); font-weight:650; }}
    code {{ color:#b8f7d4; background:#0b0f13; padding:1px 5px; border-radius:4px; }}
    .code-block {{ position:relative; margin:14px 0 20px; }}
    pre {{ overflow:auto; background:#0b0f13; border:1px solid var(--line); border-radius:8px; padding:16px; }}
    pre code {{ background:transparent; padding:0; color:#e8edf2; }}
    button {{ position:absolute; top:8px; right:8px; border:1px solid var(--line); background:#22303a; color:var(--text); border-radius:6px; padding:5px 10px; cursor:pointer; font-size:0.8rem; }}
    button:hover {{ border-color:var(--accent); }}
    strong, b {{ color:var(--warn); }}
    @media (max-width: 768px) {{ nav#toc {{ display:none; }} main {{ padding:24px 16px 40px; }} }}
  </style>
</head>
<body>
<nav id="toc"><div class="toc-title">Contents</div></nav>
<main>
{chr(10).join(out)}
</main>
<script>
// Build TOC from headings
const toc = document.getElementById('toc');
const headings = document.querySelectorAll('h2, h3');
headings.forEach((h, i) => {{
  h.id = 'section-' + i;
  const a = document.createElement('a');
  a.href = '#' + h.id;
  a.textContent = h.textContent;
  if (h.tagName === 'H3') a.classList.add('toc-h3');
  toc.appendChild(a);
}});

// Highlight active section on scroll
const tocLinks = toc.querySelectorAll('a');
const observer = new IntersectionObserver((entries) => {{
  entries.forEach(entry => {{
    if (entry.isIntersecting) {{
      tocLinks.forEach(a => a.classList.remove('active'));
      const active = toc.querySelector('a[href="#' + entry.target.id + '"]');
      if (active) {{
        active.classList.add('active');
        active.scrollIntoView({{ block: 'nearest' }});
      }}
    }}
  }});
}}, {{ rootMargin: '0px 0px -80% 0px' }});
headings.forEach(h => observer.observe(h));

// Copy buttons
document.querySelectorAll('button[data-copy]').forEach((button) => {{
  button.addEventListener('click', async () => {{
    const code = document.getElementById(button.dataset.copy).innerText;
    await navigator.clipboard.writeText(code);
    const old = button.innerText;
    button.innerText = 'Copied';
    setTimeout(() => button.innerText = old, 1200);
  }});
}});
</script>
</body>
</html>
"""
with open(os.environ["tmp_html"], "w", encoding="utf-8") as f:
    f.write(html)
PY

  sudo install -m 664 -o root -g labshared "$tmp_md" /srv/shared/ONBOARDING.md
  sudo install -m 664 -o root -g labshared "$tmp_html" /srv/shared/ONBOARDING.html
  rm -f "$tmp_md" "$tmp_html"
}

verify_system() {
  log "Verification"
  "$NEW_CONDA/bin/conda" --version
  grep -n "miniconda3" "$TARGET_HOME/.bashrc" | head -5 || true
  bash -lc 'source /etc/profile.d/cuda-toolkit.sh 2>/dev/null || true; which nvcc; nvcc --version | sed -n "1,4p"; echo "CUDA_HOME=$CUDA_HOME"'
  stat -c '%a %n' /etc/profile.d/miniconda-setup.sh /etc/profile.d/cuda-toolkit.sh /etc/skel/Desktop /etc/skel/.config/autostart /etc/skel/.config/gtk-3.0
  ls -l /srv/shared/ONBOARDING.md /srv/shared/ONBOARDING.html
}

main() {
  require_target_user
  download_miniconda
  snapshot_old_envs
  install_user_miniconda
  clone_old_envs
  verify_conda_defaults

  if [ "$USER_ONLY" = "1" ]; then
    log "User-level migration complete"
    echo "Miniforge was left in place at $OLD_CONDA for rollback."
    echo "Backups were written to $BACKUP_DIR."
    return
  fi

  require_sudo
  install_system_miniconda_assets
  install_cuda_toolkit
  fix_desktop_integration_permissions
  generate_onboarding
  verify_system

  log "Done"
  echo "Miniforge was left in place at $OLD_CONDA for rollback."
  echo "Backups were written to $BACKUP_DIR."
}

main "$@"
