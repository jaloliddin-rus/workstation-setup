# Windows 11 Workstation Multi-User Setup

I need you to help me set up this Windows 11 workstation for multi-user ML/deep learning work. I have local Administrator access.

## Working agreement

- **Stop after Phase 0** and summarize findings. Wait for my confirmation before proceeding.
- **Pause before any change that affects other users' accounts or requires reboot.**
- Show me the command before running anything destructive or system-wide.
- If something looks unexpected (broken driver, unusual partitioning, existing config that conflicts), stop and ask rather than guessing.
- Do not install CUDA Toolkit system-wide. Users get CUDA via Conda environments.
- Docker Desktop is allowed — users run it via the `docker-users` local group (no admin needed).
- All commands are PowerShell (run as Administrator) unless stated otherwise.
- After each phase, verify the changes took effect before moving on.
- At the end, run a full audit of everything and fix any issues found.

---

## Phase 0: Reconnaissance

Run these and summarize findings. Pay special attention to disk layout — tell me how many drives, what sizes, what's mounted where, and free space.

```powershell
# Windows edition (must be Pro or Enterprise — Home won't work)
(Get-ComputerInfo).WindowsProductName
[System.Environment]::OSVersion.Version

# Hostname
hostname

# CPU and RAM
Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors
Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum |
  ForEach-Object { "{0:N0} GB" -f ($_.Sum / 1GB) }

# GPU health
nvidia-smi

# Existing local users
Get-LocalUser | Where-Object { $_.Enabled } | Select-Object Name, SID, LastLogon

# Local groups
Get-LocalGroupMember -Group "Administrators" | Select-Object Name, ObjectClass
Get-LocalGroupMember -Group "Users" | Select-Object Name, ObjectClass

# User profile directories
Get-ChildItem C:\Users -Directory | ForEach-Object {
    $acl = Get-Acl $_.FullName
    [PSCustomObject]@{ Name = $_.Name; Owner = $acl.Owner }
}

# Disk layout
Get-Volume | Where-Object { $_.DriveLetter } |
  Select-Object DriveLetter, FileSystemLabel, FileSystem, @{N='SizeGB';E={[math]::Round($_.Size/1GB,1)}}, @{N='FreeGB';E={[math]::Round($_.SizeRemaining/1GB,1)}}
Get-Disk | Select-Object Number, FriendlyName, @{N='SizeGB';E={[math]::Round($_.Size/1GB,1)}}, PartitionStyle
Get-Partition | Select-Object DiskNumber, PartitionNumber, DriveLetter, @{N='SizeGB';E={[math]::Round($_.Size/1GB,1)}}

# Check installed features
Get-WindowsCapability -Online | Where-Object { $_.Name -like "OpenSSH*" } | Select-Object Name, State
Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux | Select-Object State
Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform | Select-Object State

# Check if Docker is installed
Get-Command docker -ErrorAction SilentlyContinue | Select-Object Source
Get-Service com.docker.service -ErrorAction SilentlyContinue | Select-Object Status

# Check if WSL is installed
wsl --status 2>$null

# Firewall status
Get-NetFirewallProfile | Select-Object Name, Enabled

# RDP status
(Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server').fDenyTSConnections

# SSH server status
Get-Service sshd -ErrorAction SilentlyContinue | Select-Object Status, StartType

# Long paths enabled?
(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -ErrorAction SilentlyContinue).LongPathsEnabled

# PowerShell execution policy
Get-ExecutionPolicy -List
```

**If Windows edition is Home:** stop immediately — we need Pro or Enterprise for RDP, Group Policy, and proper multi-user management. Ask me to upgrade.

**If C: drive is >80% full:** investigate with `Get-ChildItem C:\ -Directory | ForEach-Object { "{0:N2} GB - {1}" -f ((Get-ChildItem $_.FullName -Recurse -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum/1GB), $_.FullName }`, report findings, and ask what to clean up.

**Stop here. Wait for my confirmation.**

---

## Phase 1: System baseline

```powershell
# Install PSWindowsUpdate module and run updates
Install-PackageProvider -Name NuGet -Force -Scope AllUsers
Install-Module PSWindowsUpdate -Force -Scope AllUsers
Get-WindowsUpdate -Install -AcceptAll -AutoReboot:$false
```

If the update includes driver or feature changes, warn me that a reboot will be needed.

Ask me what hostname to set, then:
```powershell
Rename-Computer -NewName "<name>" -Force
# Reboot needed for hostname change — warn me
```

Enable long paths (critical for conda deep directory structures):
```powershell
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -Value 1
```

Set PowerShell execution policy:
```powershell
Set-ExecutionPolicy RemoteSigned -Scope LocalMachine -Force
```

Enable Windows Firewall and configure rules:
```powershell
# Ensure firewall is on for all profiles
Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled True

# Allow SSH (port 22)
New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH Server (sshd)" `
  -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow -Enabled True -ErrorAction SilentlyContinue

# Allow RDP (port 3389)
Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue
```

Enable RDP:
```powershell
Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -Value 1
```

Enable and start OpenSSH Server:
```powershell
# Install OpenSSH Server if not present
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0

# Start and enable the service
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic

# Set PowerShell as default SSH shell
New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell `
  -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -PropertyType String -Force
```

Enable WSL2:
```powershell
# Enable required features
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart
Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart

# Set WSL2 as default
wsl --set-default-version 2
```

**A reboot is likely needed after enabling WSL2 and OpenSSH.** Warn me before rebooting.

After reboot, install Ubuntu in WSL2:
```powershell
wsl --install -d Ubuntu --no-launch
```

Install system-wide essentials via winget:
```powershell
winget install --id Git.Git --accept-source-agreements --accept-package-agreements
winget install --id Microsoft.WindowsTerminal
winget install --id 7zip.7zip
winget install --id Notepad++.Notepad++
```

Verify:
```powershell
# SSH
Get-Service sshd | Select-Object Status, StartType

# RDP
(Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server').fDenyTSConnections
# Should be 0

# WSL
wsl --status

# Firewall
Get-NetFirewallRule -DisplayName "OpenSSH Server (sshd)" | Select-Object Enabled, Action
Get-NetFirewallRule -DisplayGroup "Remote Desktop" | Select-Object Enabled, Action
```

---

## Phase 2: Tighten user profile permissions

**Ask me first** to confirm I've notified other users.

By default, Windows allows all authenticated users to read other profiles. Lock this down:

```powershell
# Get all user profile directories (skip system profiles)
$systemProfiles = @('Public', 'Default', 'Default User', 'All Users')
$profiles = Get-ChildItem C:\Users -Directory |
  Where-Object { $_.Name -notin $systemProfiles }

foreach ($profile in $profiles) {
    $path = $profile.FullName
    Write-Host "Securing: $path"

    # Disable inheritance, convert existing ACEs to explicit
    $acl = Get-Acl $path
    $acl.SetAccessRuleProtection($true, $true)
    Set-Acl $path $acl

    # Remove BUILTIN\Users access
    $acl = Get-Acl $path
    $acl.Access | Where-Object {
        $_.IdentityReference -eq "BUILTIN\Users"
    } | ForEach-Object { $acl.RemoveAccessRule($_) } | Out-Null
    Set-Acl $path $acl
}

# Verify — each profile should only show SYSTEM, Administrators, and the owner
foreach ($profile in $profiles) {
    Write-Host "`n=== $($profile.Name) ==="
    (Get-Acl $profile.FullName).Access | Select-Object IdentityReference, FileSystemRights, AccessControlType
}
```

Confirm each profile shows only: `NT AUTHORITY\SYSTEM` (FullControl), `BUILTIN\Administrators` (FullControl), and the profile owner (FullControl).

---

## Phase 3: NVIDIA driver health

If `nvidia-smi` worked in Phase 0, **skip this phase**. Note the "CUDA Version" from nvidia-smi — that's the max CUDA users can run.

If broken, tell me and I'll update via the NVIDIA driver download page or GeForce Experience.

---

## Phase 4: Add new users

Ask me:
- How many users to add and their usernames
- Whether they should change password on first login

For each user:
```powershell
# Create user — the Read-Host will prompt for password securely:
$password = Read-Host -AsSecureString "Enter password for <username>"
New-LocalUser -Name "<username>" -Password $password -FullName "<Full Name>" -Description "ML lab user"
Add-LocalGroupMember -Group "Users" -Member "<username>"

# DO NOT add to Administrators group
```

**IMPORTANT:** User profiles are only created when the user logs in for the first time. After creating accounts, either:
- Log in as each user once (locally or via RDP) to create their profile, OR
- We'll handle profile setup in later phases when users first log in

Verify user creation:
```powershell
Get-LocalUser | Where-Object { $_.Enabled } | Select-Object Name, Enabled, PasswordRequired
Get-LocalGroupMember -Group "Administrators" | Select-Object Name
# New users should NOT appear in Administrators
```

---

## Phase 5: Shared data folder

**Base the location on Phase 0 disk findings:**
- If a secondary drive exists (e.g., D:), put shared data there: `D:\Shared`
- If no secondary drive, use `C:\Shared`
- If a secondary drive exists but isn't formatted or assigned, ask me about it

```powershell
# Create LabShared local group
New-LocalGroup -Name "LabShared" -Description "ML lab shared data access"

# Add ALL users (existing + new):
Add-LocalGroupMember -Group "LabShared" -Member "<user1>"
Add-LocalGroupMember -Group "LabShared" -Member "<user2>"
# ... repeat for all users

# Create shared directory (path depends on disk decision)
$sharedPath = "D:\Shared"  # or "C:\Shared"
New-Item -ItemType Directory -Path $sharedPath -Force

# If on secondary drive, create a symlink for convenience:
# New-Item -ItemType SymbolicLink -Path "C:\Shared" -Target "D:\Shared"

# Set NTFS permissions: disable inheritance, set explicit ACLs
$acl = Get-Acl $sharedPath

# Disable inheritance, remove inherited rules
$acl.SetAccessRuleProtection($true, $false)

# Administrators: Full Control
$adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "BUILTIN\Administrators", "FullControl",
    "ContainerInherit,ObjectInherit", "None", "Allow")
$acl.AddAccessRule($adminRule)

# SYSTEM: Full Control
$systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "NT AUTHORITY\SYSTEM", "FullControl",
    "ContainerInherit,ObjectInherit", "None", "Allow")
$acl.AddAccessRule($systemRule)

# LabShared group: Modify (read, write, execute, delete — but not change permissions)
$labRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "LabShared", "Modify",
    "ContainerInherit,ObjectInherit", "None", "Allow")
$acl.AddAccessRule($labRule)

Set-Acl $sharedPath $acl

# Verify
Write-Host "`nPermissions on ${sharedPath}:"
(Get-Acl $sharedPath).Access | Select-Object IdentityReference, FileSystemRights, AccessControlType, InheritanceFlags
```

Note: group membership takes effect on next login.

---

## Phase 6: Docker Desktop + GPU

```powershell
# Install Docker Desktop
winget install --id Docker.DockerDesktop --accept-source-agreements --accept-package-agreements
```

**A reboot or sign-out may be required after Docker Desktop installation.**

After Docker Desktop is running:
```powershell
# Add all users to docker-users group (created by Docker installer)
Add-LocalGroupMember -Group "docker-users" -Member "<user1>"
Add-LocalGroupMember -Group "docker-users" -Member "<user2>"
# ... repeat for all users

# Verify group membership
Get-LocalGroupMember -Group "docker-users" | Select-Object Name
```

Configure Docker Desktop to use WSL2 backend (this is the default on Windows 11, but verify):
```powershell
# Docker Desktop settings are per-user in %APPDATA%\Docker\settings.json
# The WSL2 backend should be enabled by default
# Verify after Docker starts:
docker info 2>$null | Select-String "Operating System|Server Version|Default Runtime"
```

Test GPU access (use a CUDA tag compatible with the driver version from Phase 0):
```powershell
docker run --rm --gpus all docker.io/nvidia/cuda:<version>-base-ubuntu24.04 nvidia-smi
```

If the GPU test fails, ensure:
1. NVIDIA drivers are up to date
2. Docker Desktop WSL2 backend is enabled
3. WSL2 has the NVIDIA GPU driver (automatic on Windows 11 with recent drivers)

---

## Phase 7: WSL2 configuration

Configure system-wide WSL2 defaults:
```powershell
# Create .wslconfig for default WSL2 resource limits
# This goes in the admin user's profile but affects all WSL instances
@"
[wsl2]
memory=32GB
swap=8GB
processors=$([Math]::Max(1, (Get-CimInstance Win32_Processor).NumberOfLogicalProcessors - 2))

[experimental]
autoMemoryReclaim=gradual
"@ | Set-Content "$env:USERPROFILE\.wslconfig" -Encoding UTF8
```

**Note:** `.wslconfig` is per-Windows-user. Each user can override with their own. The above sets a reasonable default for the admin profile. Mention in onboarding that users can customize.

Verify WSL2 GPU passthrough:
```powershell
wsl -- nvidia-smi
```

If `nvidia-smi` works inside WSL, GPU passthrough is functional. Users who prefer a Linux workflow can work entirely within WSL2.

---

## Phase 8: Shared ML environment

Install system-wide Miniforge, then create a shared read-only environment:

```powershell
# Download Miniforge installer
New-Item -ItemType Directory -Path "C:\Installers" -Force
Invoke-WebRequest -Uri "https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Windows-x86_64.exe" `
  -OutFile "C:\Installers\Miniforge3-Windows-x86_64.exe"

# Install system-wide Miniforge (silent, for all users)
Start-Process -Wait -FilePath "C:\Installers\Miniforge3-Windows-x86_64.exe" -ArgumentList `
  "/S", "/InstallationType=AllUsers", "/RegisterPython=0", "/AddToPath=0", "/D=C:\Miniforge3"
```

Create the shared ML environment:
```powershell
# Create shared environment
& C:\Miniforge3\condabin\conda.bat create -y -p C:\Miniforge3\envs\ml-base python=3.11

# Install PyTorch+CUDA (adjust cu version to match driver from Phase 0):
& C:\Miniforge3\envs\ml-base\python.exe -m pip install `
  torch torchvision torchaudio `
  --index-url https://download.pytorch.org/whl/cu128

# Install ML and medical imaging packages:
& C:\Miniforge3\envs\ml-base\python.exe -m pip install `
  jupyterlab ipykernel numpy pandas matplotlib scipy `
  scikit-learn scikit-image seaborn tqdm pillow h5py `
  opencv-python-headless nibabel pydicom SimpleITK monai tensorboard
```

Set permissions — read-only for users:
```powershell
# Make ml-base environment read-only for non-admins
$envPath = "C:\Miniforge3\envs\ml-base"
$acl = Get-Acl $envPath

# Disable inheritance, convert existing rules
$acl.SetAccessRuleProtection($true, $false)

# Administrators: Full Control
$adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "BUILTIN\Administrators", "FullControl",
    "ContainerInherit,ObjectInherit", "None", "Allow")
$acl.AddAccessRule($adminRule)

# SYSTEM: Full Control
$systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "NT AUTHORITY\SYSTEM", "FullControl",
    "ContainerInherit,ObjectInherit", "None", "Allow")
$acl.AddAccessRule($systemRule)

# Users: Read & Execute only
$userRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "BUILTIN\Users", "ReadAndExecute",
    "ContainerInherit,ObjectInherit", "None", "Allow")
$acl.AddAccessRule($userRule)

Set-Acl $envPath $acl

# Keep Miniforge base readable too
$baseAcl = Get-Acl "C:\Miniforge3"
$baseUserRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "BUILTIN\Users", "ReadAndExecute",
    "ContainerInherit,ObjectInherit", "None", "Allow")
$baseAcl.AddAccessRule($baseUserRule)
Set-Acl "C:\Miniforge3" $baseAcl
```

Create `activate-ml` command accessible system-wide:
```powershell
# Batch file for CMD users
@"
@echo off
call C:\Miniforge3\condabin\conda.bat activate C:\Miniforge3\envs\ml-base
"@ | Set-Content "C:\Windows\activate-ml.cmd" -Encoding ASCII

# PowerShell function for PS users — add to system profile
$psProfile = "$env:ProgramFiles\PowerShell\7\profile.ps1"
if (!(Test-Path (Split-Path $psProfile))) {
    $psProfile = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\profile.ps1"
}
@"

function activate-ml {
    & C:\Miniforge3\condabin\conda.bat activate C:\Miniforge3\envs\ml-base
}
"@ | Add-Content $psProfile -Encoding UTF8
```

Verify:
```powershell
& C:\Miniforge3\envs\ml-base\python.exe -c "import torch; print(f'PyTorch {torch.__version__}, CUDA: {torch.cuda.is_available()}')"
```

---

## Phase 9: Per-user Miniforge

For each existing new user (whose profile has been created by logging in):
```powershell
# Run as the target user — tell me to log in as each user and run:
# Start-Process -Wait "C:\Installers\Miniforge3-Windows-x86_64.exe" -ArgumentList `
#   "/S", "/InstallationType=JustMe", "/RegisterPython=0", "/AddToPath=0", "/D=$env:USERPROFILE\miniforge3"
# ~\miniforge3\condabin\conda.bat init powershell
# ~\miniforge3\condabin\conda.bat init bash
```

**IMPORTANT:** The Miniforge installer and `conda init` must run as the target user, not as admin. Tell me to either:
1. Log in as each user and run the commands, or
2. Give me the go-ahead to create a first-login script

Auto-install for future users via logon script:
```powershell
# Create the logon script
$scriptPath = "C:\Scripts"
New-Item -ItemType Directory -Path $scriptPath -Force

@'
# Miniforge auto-install on first login
$miniforgeDir = "$env:USERPROFILE\miniforge3"
$installer = "C:\Installers\Miniforge3-Windows-x86_64.exe"
$flagFile = "$env:USERPROFILE\.miniforge-installed"

if (!(Test-Path $miniforgeDir) -and !(Test-Path $flagFile) -and (Test-Path $installer)) {
    Write-Host "=== First login: installing Miniforge into ~/miniforge3 ==="
    Start-Process -Wait -FilePath $installer -ArgumentList `
        "/S", "/InstallationType=JustMe", "/RegisterPython=0", "/AddToPath=0", "/D=$miniforgeDir"
    if (Test-Path "$miniforgeDir\condabin\conda.bat") {
        & "$miniforgeDir\condabin\conda.bat" init powershell
        Write-Host "=== Miniforge installed. Restart PowerShell to activate conda. ==="
    }
    New-Item -ItemType File -Path $flagFile -Force | Out-Null
}
'@ | Set-Content "$scriptPath\miniforge-firstlogin.ps1" -Encoding UTF8

# Set read+execute for all users
$acl = Get-Acl $scriptPath
$userRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "BUILTIN\Users", "ReadAndExecute",
    "ContainerInherit,ObjectInherit", "None", "Allow")
$acl.AddAccessRule($userRule)
Set-Acl $scriptPath $acl
```

Register the logon script via Local Group Policy:
```powershell
# Create the Group Policy logon script registry entry
$gpPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\Scripts\Logon\0\0"
New-Item -Path $gpPath -Force
Set-ItemProperty -Path $gpPath -Name "Script" -Value "C:\Scripts\miniforge-firstlogin.ps1"
Set-ItemProperty -Path $gpPath -Name "Parameters" -Value ""
Set-ItemProperty -Path $gpPath -Name "IsPowershell" -Value 1

# Alternative: use Task Scheduler (more reliable)
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
  -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Scripts\miniforge-firstlogin.ps1"
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName "Miniforge-FirstLogin" -Action $action -Trigger $trigger `
  -Settings $settings -Description "Install Miniforge on first user login" `
  -RunLevel Limited -Force
```

---

## Phase 10: Coordination tools

```powershell
# Install nvitop into a system-wide dedicated venv
& C:\Miniforge3\python.exe -m venv C:\Tools\nvitop-venv
& C:\Tools\nvitop-venv\Scripts\pip.exe install nvitop

# Create a wrapper batch file on the system PATH
@"
@echo off
"C:\Tools\nvitop-venv\Scripts\nvitop.exe" %*
"@ | Set-Content "C:\Windows\nvitop.cmd" -Encoding ASCII

# Set read+execute for Users on the tools directory
$acl = Get-Acl "C:\Tools"
$userRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "BUILTIN\Users", "ReadAndExecute",
    "ContainerInherit,ObjectInherit", "None", "Allow")
$acl.AddAccessRule($userRule)
Set-Acl "C:\Tools" $acl

# Verify
nvitop --version

# Create reservations file in shared folder
$sharedPath = "C:\Shared"  # adjust to actual path
New-Item -ItemType File -Path "$sharedPath\RESERVATIONS.md" -Force
# LabShared group already has Modify on shared folder — inherits
```

---

## Phase 11: Restrict non-admin users

Remove shutdown/restart rights from standard users via Local Security Policy:

```powershell
# Export current security policy
secedit /export /cfg C:\Windows\Temp\secpol.cfg

# Read the config
$config = Get-Content C:\Windows\Temp\secpol.cfg

# Find the "Shut down the system" line and set to Administrators only
$config = $config -replace '(SeShutdownPrivilege\s*=\s*).*', '$1*S-1-5-32-544'

# Find the "Force shutdown from a remote system" line and set to Administrators only
$config = $config -replace '(SeRemoteShutdownPrivilege\s*=\s*).*', '$1*S-1-5-32-544'

# Write and apply
$config | Set-Content C:\Windows\Temp\secpol.cfg
secedit /configure /db secedit.sdb /cfg C:\Windows\Temp\secpol.cfg /areas USER_RIGHTS
Remove-Item C:\Windows\Temp\secpol.cfg -Force
```

Prevent users from changing power settings via registry:
```powershell
# Hide power options in Settings for non-admin users
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Power" -Force
New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Power" `
  -Name "HidePowerOptions" -Value 1 -PropertyType DWord -Force -ErrorAction SilentlyContinue
```

Verify:
```powershell
# Export and check shutdown privilege
secedit /export /cfg C:\Windows\Temp\secpol-verify.cfg
Select-String "SeShutdownPrivilege|SeRemoteShutdownPrivilege" C:\Windows\Temp\secpol-verify.cfg
Remove-Item C:\Windows\Temp\secpol-verify.cfg -Force
# Should show only *S-1-5-32-544 (Administrators)
```

---

## Phase 12: Onboarding doc + desktop integration

Run `(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike "*Loopback*" }).IPAddress` to get the machine's IP address. Use this actual IP in the onboarding doc examples below.

Create `<shared_folder>\ONBOARDING.html` — a styled HTML page with dark theme and copy-to-clipboard buttons on all code blocks. Include:
- Machine specs (CPU model, cores, RAM, GPU, VRAM, driver version, CUDA version, storage layout)
- How to find the machine's IP (`ipconfig` on the machine itself) and connect:
  - **SSH:** `ssh username@<IP_ADDRESS>` (PowerShell is the default shell)
  - **RDP:** Microsoft Remote Desktop (macOS), Remote Desktop Connection (Windows), Remmina (Linux)
  - Include a warning box: log out of RDP properly when done — don't just close the window, as that leaves the session running and consuming resources. If a training job is running, it's OK to close without logging out.
- **WSL2:** How to launch (`wsl` from PowerShell or Windows Terminal), first-launch setup, GPU verification (`nvidia-smi` inside WSL)
- **Docker:** How to use Docker with GPU (`docker run --rm --gpus all ...`), note that Docker Desktop must be running
- How to use the shared ML environment (`activate-ml` in CMD, or `activate-ml` function in PowerShell) with package list
- How to run JupyterLab (activate-ml then `jupyter lab`, plus SSH tunnel instructions for remote use)
- How to clone the shared env to your own account (step-by-step with commands)
- How to create a fresh environment from scratch
- Useful conda commands cheat sheet (Windows-specific paths)
- How to use the shared folder (desktop shortcut, File Explorer, `C:\Shared` path)
- GPU etiquette with nvitop
- Rules (no system CUDA, no shutdown/restart, ask admin to install software) — highlight rules in warning color
- Contact info for admin

Also keep a plain `<shared_folder>\ONBOARDING.md` with the same content for SSH/terminal viewing.

Put desktop shortcuts for onboarding AND shared folder on every user's desktop:
```powershell
# Create shortcuts in Default user profile (for future users)
$defaultDesktop = "C:\Users\Default\Desktop"
New-Item -ItemType Directory -Path $defaultDesktop -Force

# Onboarding shortcut
$WshShell = New-Object -ComObject WScript.Shell
$shortcut = $WshShell.CreateShortcut("$defaultDesktop\Onboarding Guide.lnk")
$shortcut.TargetPath = "<shared_folder>\ONBOARDING.html"
$shortcut.IconLocation = "shell32.dll,1"
$shortcut.Description = "Read this first"
$shortcut.Save()

# Shared folder shortcut
$shortcut = $WshShell.CreateShortcut("$defaultDesktop\Shared Data.lnk")
$shortcut.TargetPath = "<shared_folder>"
$shortcut.IconLocation = "shell32.dll,275"
$shortcut.Description = "Lab shared folder"
$shortcut.Save()

# Copy to existing new users:
# foreach ($user in @("<user1>", "<user2>")) {
#     $userDesktop = "C:\Users\$user\Desktop"
#     if (Test-Path "C:\Users\$user") {
#         New-Item -ItemType Directory -Path $userDesktop -Force
#         Copy-Item "$defaultDesktop\Onboarding Guide.lnk" $userDesktop
#         Copy-Item "$defaultDesktop\Shared Data.lnk" $userDesktop
#         $userSid = (Get-LocalUser $user).SID.Value
#         icacls $userDesktop /setowner "$user" /T /C
#     }
# }
```

Pin shared folder to Quick Access for all users:
```powershell
# For future users — add to Default profile's Quick Access
# This is stored per-user; we can add via a logon script
@'
$sharedPath = "<shared_folder>"
if (Test-Path $sharedPath) {
    $shell = New-Object -ComObject Shell.Application
    $shell.Namespace($sharedPath).Self.InvokeVerb("pintohome")
}
'@ | Add-Content "C:\Scripts\miniforge-firstlogin.ps1" -Encoding UTF8
```

Auto-open onboarding on first login — add to the existing first-login script:
```powershell
# Append to the existing first-login script
@'

# Open onboarding guide on first login
$onboardingFlag = "$env:USERPROFILE\.onboarding-done"
if (!(Test-Path $onboardingFlag)) {
    Start-Sleep -Seconds 5
    Start-Process "<shared_folder>\ONBOARDING.html"
    New-Item -ItemType File -Path $onboardingFlag -Force | Out-Null
}
'@ | Add-Content "C:\Scripts\miniforge-firstlogin.ps1" -Encoding UTF8
```

---

## Phase 13: Disable sleep and configure screen timeout

Prevent the machine from sleeping/suspending (critical for long-running ML jobs):
```powershell
# Disable standby and hibernate on AC power
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0

# Disable hibernation entirely (also frees disk space)
powercfg /hibernate off

# Set monitor timeout to 30 minutes on AC
powercfg /change monitor-timeout-ac 30

# Prevent users from changing power plan via Group Policy registry keys
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Power\PowerSettings" -Force
New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Power\PowerSettings" `
  -Name "ActivePowerScheme" -Value (powercfg /getactivescheme).Split()[3] `
  -PropertyType String -Force -ErrorAction SilentlyContinue

# Disable sleep button action
powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS SBUTTONACTION 0
powercfg /setactive SCHEME_CURRENT
```

Verify:
```powershell
powercfg /query SCHEME_CURRENT SUB_SLEEP
# Standby and hibernate should both show 0x00000000
powercfg /query SCHEME_CURRENT SUB_VIDEO
# Monitor timeout should show 0x00000708 (1800 seconds = 30 minutes)
```

---

## Phase 14: SSH server fine-tuning

The SSH server was enabled in Phase 1. Now configure it:

```powershell
$sshdConfig = "C:\ProgramData\ssh\sshd_config"

# Read current config
$config = Get-Content $sshdConfig

# Ensure these settings:
# PubkeyAuthentication yes (default, verify it's not disabled)
# PasswordAuthentication yes (for initial access)
# PermitRootLogin — not applicable on Windows

# The default config is generally fine for our use case
# Just verify key settings are not accidentally disabled:
Write-Host "=== SSH Config Review ==="
Select-String "PubkeyAuthentication|PasswordAuthentication|AuthorizedKeysFile" $sshdConfig

# Restart sshd to apply any changes
Restart-Service sshd
```

Test SSH locally:
```powershell
ssh localhost whoami
```

---

## Phase 15: Final audit

Run a comprehensive check of everything:

```powershell
Write-Host "=== FINAL AUDIT ===" -ForegroundColor Cyan

# 1. Windows edition
$edition = (Get-ComputerInfo).WindowsProductName
Write-Host "`n[Edition] $edition" -ForegroundColor Yellow
if ($edition -notlike "*Pro*" -and $edition -notlike "*Enterprise*") {
    Write-Host "  FAIL: Need Pro or Enterprise" -ForegroundColor Red
}

# 2. User profile permissions
Write-Host "`n[User Profile Permissions]" -ForegroundColor Yellow
$systemProfiles = @('Public', 'Default', 'Default User', 'All Users')
Get-ChildItem C:\Users -Directory | Where-Object { $_.Name -notin $systemProfiles } | ForEach-Object {
    $access = (Get-Acl $_.FullName).Access | Where-Object { $_.IdentityReference -eq "BUILTIN\Users" }
    if ($access) {
        Write-Host "  FAIL: $($_.Name) — BUILTIN\Users has access" -ForegroundColor Red
    } else {
        Write-Host "  OK: $($_.Name) — no BUILTIN\Users access" -ForegroundColor Green
    }
}

# 3. Firewall
Write-Host "`n[Firewall]" -ForegroundColor Yellow
Get-NetFirewallProfile | ForEach-Object {
    $status = if ($_.Enabled) { "OK" } else { "FAIL" }
    $color = if ($_.Enabled) { "Green" } else { "Red" }
    Write-Host "  $status`: $($_.Name) profile — Enabled: $($_.Enabled)" -ForegroundColor $color
}

# 4. SSH, RDP, firewall rules
Write-Host "`n[SSH Server]" -ForegroundColor Yellow
$sshd = Get-Service sshd -ErrorAction SilentlyContinue
Write-Host "  Status: $($sshd.Status), StartType: $($sshd.StartType)"
if ($sshd.Status -ne "Running") { Write-Host "  FAIL: sshd not running" -ForegroundColor Red }

Write-Host "`n[RDP]" -ForegroundColor Yellow
$rdp = (Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server').fDenyTSConnections
Write-Host "  fDenyTSConnections: $rdp (should be 0)"
if ($rdp -ne 0) { Write-Host "  FAIL: RDP disabled" -ForegroundColor Red }

Write-Host "`n[Firewall Rules]" -ForegroundColor Yellow
$sshRule = Get-NetFirewallRule -DisplayName "OpenSSH Server (sshd)" -ErrorAction SilentlyContinue
$rdpRules = Get-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -eq "True" }
Write-Host "  SSH rule: $(if ($sshRule) { 'OK' } else { 'MISSING' })"
Write-Host "  RDP rules: $(if ($rdpRules) { 'OK' } else { 'MISSING' })"

# 5. NVIDIA
Write-Host "`n[NVIDIA GPU]" -ForegroundColor Yellow
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader

# 6. LabShared group
Write-Host "`n[LabShared Group Members]" -ForegroundColor Yellow
Get-LocalGroupMember -Group "LabShared" | Select-Object Name

# 7. Shared folder permissions
Write-Host "`n[Shared Folder Permissions]" -ForegroundColor Yellow
$sharedPath = "C:\Shared"  # adjust to actual path
if (Test-Path $sharedPath) {
    (Get-Acl $sharedPath).Access | Select-Object IdentityReference, FileSystemRights, InheritanceFlags
} else {
    Write-Host "  FAIL: Shared folder not found at $sharedPath" -ForegroundColor Red
}

# 8. Docker
Write-Host "`n[Docker]" -ForegroundColor Yellow
$dockerUsers = Get-LocalGroupMember -Group "docker-users" -ErrorAction SilentlyContinue
Write-Host "  docker-users members: $(($dockerUsers | ForEach-Object { $_.Name }) -join ', ')"
docker version --format '{{.Server.Version}}' 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "  WARNING: Docker not responding (Desktop may need to start)" -ForegroundColor Yellow }

# 9. WSL2
Write-Host "`n[WSL2]" -ForegroundColor Yellow
wsl --status 2>$null
wsl -- nvidia-smi --query-gpu=name --format=csv,noheader 2>$null

# 10. Shared ML environment
Write-Host "`n[Shared ML Environment]" -ForegroundColor Yellow
& C:\Miniforge3\envs\ml-base\python.exe -c "import torch; print(f'PyTorch {torch.__version__}, CUDA: {torch.cuda.is_available()}')"
& C:\Miniforge3\envs\ml-base\python.exe -c "import monai; import SimpleITK; import nibabel; print('Medical imaging packages: OK')"

# 11. activate-ml command
Write-Host "`n[activate-ml]" -ForegroundColor Yellow
if (Test-Path "C:\Windows\activate-ml.cmd") {
    Write-Host "  OK: activate-ml.cmd exists" -ForegroundColor Green
} else {
    Write-Host "  FAIL: activate-ml.cmd missing" -ForegroundColor Red
}

# 12. Per-user Miniforge
Write-Host "`n[Per-User Miniforge]" -ForegroundColor Yellow
# Test for each new user — list manually:
# foreach ($user in @("<user1>", "<user2>")) {
#     $condaPath = "C:\Users\$user\miniforge3\condabin\conda.bat"
#     if (Test-Path $condaPath) {
#         Write-Host "  OK: $user has miniforge3" -ForegroundColor Green
#     } else {
#         Write-Host "  PENDING: $user — miniforge3 not yet installed (will install on first login)" -ForegroundColor Yellow
#     }
# }

# 13. nvitop
Write-Host "`n[nvitop]" -ForegroundColor Yellow
$nvitopCmd = Get-Command nvitop -ErrorAction SilentlyContinue
if ($nvitopCmd) {
    Write-Host "  OK: nvitop at $($nvitopCmd.Source)" -ForegroundColor Green
} else {
    Write-Host "  FAIL: nvitop not found" -ForegroundColor Red
}

# 14. Desktop shortcuts
Write-Host "`n[Desktop Shortcuts]" -ForegroundColor Yellow
$defaultDesktop = "C:\Users\Default\Desktop"
@("Onboarding Guide.lnk", "Shared Data.lnk") | ForEach-Object {
    $path = "$defaultDesktop\$_"
    if (Test-Path $path) {
        Write-Host "  OK: $_ exists in Default profile" -ForegroundColor Green
    } else {
        Write-Host "  FAIL: $_ missing from Default profile" -ForegroundColor Red
    }
}

# 15. Sleep/hibernate
Write-Host "`n[Power Settings]" -ForegroundColor Yellow
$standby = powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 2>$null
Write-Host "  Hibernate: $(if ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name HibernateEnabled -ErrorAction SilentlyContinue).HibernateEnabled -eq 0) { 'Disabled (OK)' } else { 'Enabled (FAIL)' })"

# 16. Shutdown restriction
Write-Host "`n[Shutdown Restriction]" -ForegroundColor Yellow
secedit /export /cfg C:\Windows\Temp\audit-secpol.cfg 2>$null
$shutdownPolicy = Select-String "SeShutdownPrivilege" C:\Windows\Temp\audit-secpol.cfg
Write-Host "  $shutdownPolicy"
Remove-Item C:\Windows\Temp\audit-secpol.cfg -Force -ErrorAction SilentlyContinue

# 17. Long paths
Write-Host "`n[Long Paths]" -ForegroundColor Yellow
$longPaths = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem').LongPathsEnabled
Write-Host "  LongPathsEnabled: $longPaths $(if ($longPaths -eq 1) { '(OK)' } else { '(FAIL)' })"

# 18. First-login script
Write-Host "`n[First-Login Script]" -ForegroundColor Yellow
if (Test-Path "C:\Scripts\miniforge-firstlogin.ps1") {
    Write-Host "  OK: First-login script exists" -ForegroundColor Green
} else {
    Write-Host "  FAIL: First-login script missing" -ForegroundColor Red
}
$task = Get-ScheduledTask -TaskName "Miniforge-FirstLogin" -ErrorAction SilentlyContinue
Write-Host "  Scheduled task: $(if ($task) { 'OK' } else { 'MISSING' })"

# 19. Onboarding files
Write-Host "`n[Onboarding Files]" -ForegroundColor Yellow
foreach ($file in @("ONBOARDING.html", "ONBOARDING.md", "RESERVATIONS.md")) {
    $path = "$sharedPath\$file"
    if (Test-Path $path) {
        Write-Host "  OK: $file" -ForegroundColor Green
    } else {
        Write-Host "  FAIL: $file missing" -ForegroundColor Red
    }
}

Write-Host "`n=== AUDIT COMPLETE ===" -ForegroundColor Cyan
```

Fix any issues found.

---

## When done

Summarize:
- What was changed
- What to communicate to other users
- What each new user needs to do on first login
- Any phase that didn't go cleanly and what to follow up on
