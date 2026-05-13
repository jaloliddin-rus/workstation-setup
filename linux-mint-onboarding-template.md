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
| `/home/<your-username>` | Your private files, code, Conda environments, and experiments. Other users should not access this. |
| `/srv/shared` | Shared datasets, shared notes, and files intentionally shared with the lab. |
| {{EXTRA_STORAGE_LOCATION}} | {{EXTRA_STORAGE_DESCRIPTION}} |

Keep private or unfinished work in your home folder. Put files in `/srv/shared` only when other users are allowed to see or use them.

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
