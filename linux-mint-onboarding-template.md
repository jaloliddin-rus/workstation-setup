# {{HOSTNAME}} ML Workstation Onboarding

Read this once before using the workstation. The goal is to help you log in, run experiments, keep work organized, and avoid interrupting other users.

## Quick Facts

| Item | Value |
|---|---|
| Hostname | `{{HOSTNAME}}` |
| Operating system | {{OS_VERSION}} |
| CPU | {{CPU_SUMMARY}} |
| RAM | {{RAM_SUMMARY}} |
| GPU | {{GPU_SUMMARY}} |
| NVIDIA driver | {{NVIDIA_DRIVER}} |
| Driver-supported CUDA | {{DRIVER_CUDA}} |
| Installed CUDA Toolkit | {{CUDA_TOOLKIT}} |
| Shared folder | `/srv/shared` |
| Admin contact | {{ADMIN_CONTACT}} |

## Storage

| Location | What it is for |
|---|---|
| `/home/<your-username>` | Your private files, code, Conda environments, and experiments. Other users should not access this. **Soft limit: {{HOME_QUOTA}} per user.** |
| `{{USER_DATA_BASE}}/<your-username>` | Your private overflow storage on the secondary drive. Use this for large datasets, model checkpoints, and anything that does not fit in your home folder. Created automatically on first login. |
| `/srv/shared` | Shared datasets, shared notes, and files intentionally shared with the lab. |
| {{EXTRA_STORAGE_LOCATION}} | {{EXTRA_STORAGE_DESCRIPTION}} |

Your home directory has a soft storage limit of {{HOME_QUOTA}}. If you go over this limit, you will receive a warning every time you open a terminal. Move large files to `{{USER_DATA_BASE}}/<your-username>` to free space. The secondary drive has {{DATA_DRIVE_TOTAL}} of total storage.

Keep private or unfinished work in your home folder or your `{{USER_DATA_BASE}}` directory. Put files in `/srv/shared` only when other users are allowed to see or use them.

## Connecting

### Local Login

Use your own username and password at the workstation. Do not use another person's account.

### SSH

SSH is the best way to run terminal commands remotely.

On the workstation, you can find the IP address with:

```bash
hostname -I
```

From your laptop or another computer, connect with:

```bash
ssh your-username@<IP_ADDRESS>
```

Replace `your-username` with your Linux username. Replace `<IP_ADDRESS>` with the workstation IP address.

### Remote Desktop

Use Remote Desktop if you need the graphical desktop.

| Your computer | App to use |
|---|---|
| Windows | Remote Desktop Connection |
| macOS | Microsoft Remote Desktop |
| Linux | Remmina |

Connect to `<IP_ADDRESS>` using your Linux username and password.

Important: if you are done working, log out from the Linux menu. Do not only close the Remote Desktop window, because that can leave your desktop session running. If a training job is running, it is okay to close the window without logging out.

## Installed Tools

| Tool | What it is for |
|---|---|
| `conda` | Create isolated Python environments for projects. |
| `activate-ml` | Activate the shared read-only ML environment. |
| `tmux` | Keep terminal sessions and experiments running after SSH disconnects. |
| `nvitop` | Check GPU use before starting work. |
| `podman` | Run containers. Use Podman instead of Docker on this workstation. |
| `git` | Clone and manage code repositories. |
| `htop` | See CPU and memory use. |
| `tree` | Print folder structure in the terminal. |

## Conda Basics

Each user has Miniconda installed at:

```bash
~/miniconda3
```

Use one Conda environment per project. This prevents one project's packages from breaking another project.

Create a new environment:

```bash
conda create -n my-project
```

Python 3.11 and pip are installed automatically in new environments on this workstation.

Activate it:

```bash
conda activate my-project
```

Install packages:

```bash
conda install numpy pandas
pip install package-name
```

Deactivate when done:

```bash
conda deactivate
```

List your environments:

```bash
conda env list
```

Delete an environment:

```bash
conda remove -n my-project --all
```

## Shared ML Environment

There is a shared read-only environment with common ML and medical imaging packages.

Activate it:

```bash
activate-ml
```

This environment is for quick starts and shared examples. Do not modify it. If you need to install more packages, clone it into your own account.

Clone the shared environment:

```bash
conda create -n my-ml --clone /opt/conda-shared/envs/ml-base
conda activate my-ml
pip install additional-package-name
```

## JupyterLab

Start JupyterLab locally:

```bash
activate-ml
jupyter lab
```

For remote use over SSH, start JupyterLab on the workstation:

```bash
activate-ml
jupyter lab --no-browser --port=8888
```

On your laptop, open a second terminal and create a tunnel:

```bash
ssh -N -L 8888:localhost:8888 your-username@<IP_ADDRESS>
```

Then open this address in your laptop browser:

```text
http://localhost:8888
```

## Keeping Experiments Running With tmux

Use `tmux` when running experiments over SSH. Without tmux, a lost SSH connection can stop your terminal program. With tmux, the terminal session stays alive on the workstation.

Start a new tmux session:

```bash
tmux new -s experiment1
```

Run your experiment inside tmux:

```bash
conda activate my-ml
python train.py
```

Detach from tmux without stopping the experiment:

```text
Press Ctrl+b, then release both keys, then press d
```

Reconnect later by SSH, then list tmux sessions:

```bash
tmux ls
```

Reattach to your session:

```bash
tmux attach -t experiment1
```

Useful tmux commands:

| Action | Command or keys |
|---|---|
| New named session | `tmux new -s experiment1` |
| Detach session | `Ctrl+b`, then `d` |
| List sessions | `tmux ls` |
| Reattach session | `tmux attach -t experiment1` |
| New window | `Ctrl+b`, then `c` |
| Next window | `Ctrl+b`, then `n` |
| Split pane left/right | `Ctrl+b`, then `%` |
| Split pane top/bottom | `Ctrl+b`, then `"` |
| Close current pane | type `exit` |

Only stop a tmux session when you are sure your experiment is finished:

```bash
tmux kill-session -t experiment1
```

## Transferring Files With rsync

Use `rsync` to copy files between your laptop and the workstation. It is faster than `scp` for large transfers because it only sends the parts that changed.

### Copy a file or folder to the workstation

From your laptop terminal:

```bash
rsync -avh --progress /path/to/local/folder/ your-username@<IP_ADDRESS>:/home/your-username/destination/
```

The trailing `/` on the source folder means "copy the contents." Without it, rsync copies the folder itself inside the destination.

### Copy a file or folder from the workstation to your laptop

```bash
rsync -avh --progress your-username@<IP_ADDRESS>:/home/your-username/results/ /path/to/local/folder/
```

### Resume an interrupted transfer

If a large transfer gets interrupted, run the same command again. rsync skips files that are already complete.

### Common options

| Option | What it does |
|---|---|
| `-a` | Archive mode — preserves permissions, timestamps, and subdirectories |
| `-v` | Verbose — shows file names as they transfer |
| `-h` | Human-readable sizes (MB, GB) |
| `--progress` | Shows transfer progress for each file |
| `--exclude='*.tmp'` | Skip files matching a pattern |
| `--dry-run` | Preview what would be copied without actually copying |

### Example: sync a dataset to your data directory

```bash
rsync -avh --progress /mnt/nas/dataset/ your-username@<IP_ADDRESS>:{{USER_DATA_BASE}}/your-username/dataset/
```

Always use `--dry-run` first if you are unsure what will be copied:

```bash
rsync -avh --dry-run /path/to/source/ your-username@<IP_ADDRESS>:/path/to/destination/
```

## GPU Use

Check the GPU before starting a large job:

```bash
nvitop
```

If another user is already using most of the GPU memory, coordinate before starting another large job.

For long jobs, write your plan in:

```bash
/srv/shared/RESERVATIONS.md
```

Include your username, the expected start time, the expected finish time, and what you are running.

## Resource Limits

This workstation has per-user limits so one account cannot accidentally consume the whole machine.

| Limit | Value |
|---|---|
| CPU | {{CPU_LIMIT}} |
| Memory soft limit | {{MEMORY_HIGH}} |
| Memory hard limit | {{MEMORY_MAX}} |
| Process/thread limit | {{TASKS_MAX}} |

If your job is killed, it may have exceeded memory or process limits. Check your logs, reduce batch size, or ask the admin for help.

## Rules

Do not install Docker. Use Podman.

Do not install NVIDIA drivers or system packages yourself. Ask the admin.

Do not shut down or restart the workstation unless the admin told you to.

Do not modify `/opt/conda-shared/envs/ml-base`. Clone it into your own account instead.

Do not put private files in `/srv/shared`.

## Getting Help

For admin help, contact:

```text
{{ADMIN_CONTACT}}
```

When asking for help, include your username, the command you ran, the error message, and which Conda environment you were using.
