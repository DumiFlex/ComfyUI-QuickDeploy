#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Installs and configures ComfyUI in a clean environment.

.DESCRIPTION
    This script:
    - Downloads ComfyUI from GitHub.
    - Sets up a virtual environment.
    - Installs Python and dependencies.
    - Optionally sets up model download and shortcuts.

.NOTES
    Author: DumiFlex
    Version: 1.0
    GitHub: https://github.com/DumiFlex/ComfyUI-QuickDeploy
#>

param(
    [string]$InstallPath = $PSScriptRoot
)

#===========================================================================
# SECTION 1: SCRIPT CONFIGURATION & HELPER FUNCTIONS
#===========================================================================

# --- Cleaning and configuring paths ---
$InstallPath = $InstallPath.TrimEnd('"')
$InstallPath = [IO.Path]::GetFullPath($InstallPath).TrimEnd('\', '/')
$installFolderName = Split-Path $InstallPath -Leaf
$parentOfInstallPath = Split-Path $InstallPath -Parent
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Setting base path as the main installation directory
$comfyPath = Join-Path -Path $InstallPath -ChildPath "ComfyUI"
$tempPath = Join-Path -Path $InstallPath -ChildPath "temp"
$whlBaseUrl = "https://github.com/DumiFlex/ComfyUI-QuickDeploy/releases/download/v1.0.0/"
$logPath = Join-Path $InstallPath "logs"
$logFile = Join-Path $logPath "install_log.txt"
$sevenZipPath = "C:\Program Files\7-Zip\7z.exe"

$venvPython = Join-Path -Path $comfyPath -ChildPath "venv\Scripts\python.exe"

$whlFiles = @(
    "causal_conv1d-1.5.0.post8+cu129torch2.7.1-cp312-cp312-win_amd64.whl",
    "flash_attn-2.8.0+cu129torch2.7.1-cp312-cp312-win_amd64.whl",
    "mamba_ssm-2.2.4+cu129torch2.7.1-cp312-cp312-win_amd64.whl",
    "sageattention-2.2.0+cu129torch2.7.1-cp312-cp312-win_amd64.whl",
    "triton-3.3.0-py3-none-any.whl"
)

# --- Create Log Directory ---
if (-not (Test-Path $logPath)) {
    New-Item -ItemType Directory -Force -Path $logPath | Out-Null
}


# Function to write output
function Write-Log {
    param(
        [string]$Message,
        [string]$Color = "White",
        [string]$Level = "INFO",
        [bool]$usePrefix = $true,
        [int]$PrefixIndent = 0
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $spaces = " " * $PrefixIndent
    $prefix = if ($usePrefix) { "$spaces[{0}] " -f $Level.ToUpper() } else { "$spaces" }
    $Message = "$prefix$Message"
    $formattedMessage = "[$timestamp] $Message"
    Write-Host $Message -ForegroundColor $Color
    Add-Content -Path $logFile -Value $formattedMessage
}

function Invoke-AndLog {
    param(
        [string]$File,
        [string]$Arguments
    )

    $tempLogFile = Join-Path $env:TEMP ([System.Guid]::NewGuid().ToString() + ".tmp")

    try {
        # Runs the command and redirects ALL of its output to the temporary file
        $commandToRun = "`"$File`" $Arguments"
        $cmdArguments = "/C `"$commandToRun > `"`"$tempLogFile`"`" 2>&1`""
        Start-Process -FilePath "cmd.exe" -ArgumentList $cmdArguments -Wait -WindowStyle Hidden
        
        # Once the command is completed, the temporary file is read
        if (Test-Path $tempLogFile) {
            $output = Get-Content $tempLogFile
            # And we add it to the main log safely
            Add-Content -Path $logFile -Value $output
        }
    } catch {
        Write-Log "FATAL ERROR trying to execute command: $commandToRun" -Color Red -Level "ERROR" -PrefixIndent 2
    } finally {
        # We make sure that the temporary file is always deleted
        if (Test-Path $tempLogFile) {
            Remove-Item $tempLogFile
        }
    }
}

function Download-File {
    param(
        [string]$Uri,
        [string]$OutFile,
        [string]$PrefixIndent = 2,
        [string]$Color = "Yellow"
    )

    if (Test-Path $OutFile) {
        Write-Log "Skipping: $((Split-Path $OutFile -Leaf)) (already exists)." -Color DarkGray -Level "INFO" -PrefixIndent "$PrefixIndent"
    } else {
        $fileName = Split-Path -Path $Uri -Leaf
        if (Get-Command 'aria2c' -ErrorAction SilentlyContinue) {
            Write-Log "Downloading $fileName..." -Color "$Color" -Level "INFO" -PrefixIndent "$PrefixIndent"
            $aria_args = "--disable-ipv6 -c -x 16 -s 16 -k 1M --dir=`"$((Split-Path $OutFile -Parent))`" --out=`"$((Split-Path $OutFile -Leaf))`" `"$Uri`""
            Invoke-AndLog "aria2c" $aria_args
        } else {
            Write-Log "Aria2 not found. Falling back to standard download: $fileName" -Color "Dark$Color" -Level "WARN" -PrefixIndent "$PrefixIndent"
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile
        }
    }
}

function Safe-RemoveDirectory {
    param (
        [string]$Path,
        [int]$MaxRetries = 5,
        [int]$DelaySeconds = 2
    )

    for ($i = 0; $i -lt $MaxRetries; $i++) {
        try {
            if (Test-Path $Path) {
                Remove-Item -Recurse -Force -Path $Path -ErrorAction Stop
                Write-Log "Successfully removed directory: $Path" -Color Green -Level "OK" -PrefixIndent 2
                return
            } else {
                return
            }
        } catch {
            Write-Log "Attempt $($i+1) failed to remove directory: $($_.Exception.Message)" -Color Red -Level "WARN" -PrefixIndent 2
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    Write-Log "Failed to remove directory after $MaxRetries attempts: $Path" -Color Red -Level "ERROR" -PrefixIndent 2
    exit 1
}

function Install-Aria2-Binary {
    Write-Log "--- Starting Aria2 binary installation ---" -Color Magenta -Level "INFO" -PrefixIndent 2
    $destFolder = "C:\Tools\aria2"
    if (-not (Test-Path $destFolder)) { New-Item -ItemType Directory -Force -Path $destFolder | Out-Null }
    $aria2Url = "https://github.com/aria2/aria2/releases/download/release-1.36.0/aria2-1.36.0-win-64bit-build1.zip"
    $zipPath  = Join-Path $env:TEMP "aria2_temp.zip"
    Download-File -Uri $aria2Url -OutFile $zipPath
    Write-Log "Extracting zip file to $destFolder..." -Color Magenta -Level "INFO" -PrefixIndent 2
    Expand-Archive -Path $zipPath -DestinationPath $destFolder -Force
    $extractedSubfolder = Join-Path $destFolder "aria2-1.36.0-win-64bit-build1"
    if (Test-Path $extractedSubfolder) {
        Move-Item -Path (Join-Path $extractedSubfolder "*") -Destination $destFolder -Force
        Remove-Item -Path $extractedSubfolder -Recurse -Force
    }
    $configFile = Join-Path $destFolder "aria2.conf"
    $configContent = "continue=true`nmax-connection-per-server=16`nsplit=16`nmin-split-size=1M`nfile-allocation=none"
    $configContent | Out-File $configFile -Encoding UTF8
    $envScope = "User"
    $oldPath = [System.Environment]::GetEnvironmentVariable("Path", $envScope)
    if ($oldPath -notlike "*$destFolder*") {
        Write-Log "Adding '$destFolder' to user PATH..." -Color Magenta -Level "INFO" -PrefixIndent 2
        $newPath = $oldPath + ";$destFolder"
        [System.Environment]::SetEnvironmentVariable("Path", $newPath, $envScope)
        $env:Path = $newPath
        Write-Log "PATH updated. Aria2 will be available immediately." -Color Green -Level "OK" -PrefixIndent 2
    }
    Write-Log "--- Aria2 binary installation complete ---" -Color Magenta -Level "INFO" -PrefixIndent 2
}

function Ensure-ToolInstalled {
    param(
        [string]$CommandName,
        [scriptblock]$InstallAction,
        [string]$CheckPath = $null
    )
    if ($CheckPath) {
        if (-not (Test-Path $CheckPath)) {
            Write-Log "$CommandName not found. Installing $CommandName..." -Color DarkYellow -Level "WARN" -PrefixIndent 2
            & $InstallAction
            if (-not (Test-Path $CheckPath)) {
                Write-Log "$CommandName installation failed." -Color Red -Level "ERROR" -PrefixIndent 2
                exit 1
            }
            Write-Log "$CommandName installation complete." -Color Green -Level "OK" -PrefixIndent 2
        } else {
            Write-Log "$CommandName is available at $CheckPath." -Color Yellow -Level "INFO" -PrefixIndent 2
        }
    } else {
        if (-not (Get-Command $CommandName -ErrorAction SilentlyContinue)) {
            Write-Log "$CommandName not found. Installing $CommandName..." -Color DarkYellow -Level "WARN" -PrefixIndent 2
            & $InstallAction
            if (-not (Get-Command $CommandName -ErrorAction SilentlyContinue)) {
                Write-Log "$CommandName installation failed." -Color Red -Level "ERROR" -PrefixIndent 2
                exit 1
            }
            Write-Log "$CommandName installation complete." -Color Green -Level "OK" -PrefixIndent 2
        } else {
            Write-Log "$CommandName is already installed." -Color Yellow -Level "INFO" -PrefixIndent 2
        }
    }
}

#===========================================================================
# SECTION 2: MAIN SCRIPT EXECUTION
#===========================================================================

Clear-Host
$simulateNonWindows = $true

if ($env:OS -notlike "*Windows*" -or !(Get-CimInstance -ClassName Win32_OperatingSystem)) {
    Write-Host "This script is designed for Windows systems only. Press any key to exit." -ForegroundColor Red -NoNewline
    Read-Host
    exit 1
}
# --- Banner ---
Write-Log "-------------------------------------------------------------------------------" -Color DarkCyan -usePrefix $false
$asciiBanner = @'
           ______                ____      __  ______     ____    ____ 
          / ____/___  ____ ___  / __/_  __/ / / /  _/    / __ \  / __ \
         / /   / __ \/ __ `__ \/ /_/ / / / / / // /_____/ / / / / / / /
        / /___/ /_/ / / / / / / __/ /_/ / /_/ // /_____/ /_/ / / /_/ / 
        \____/\____/_/ /_/ /_/_/  \__, /\____/___/     \___\_\/_____/  
                                 /____/                                                            
'@
Write-Host $asciiBanner -ForegroundColor DarkCyan
Write-Log "-------------------------------------------------------------------------------" -Color DarkCyan -usePrefix $false
Write-Log "                      ComfyUI - Quick & Clean Installer                        " -Color DarkCyan -usePrefix $false
Write-Log "                           Version 1.0 by DumiFlex                             " -Color DarkCyan -usePrefix $false
Write-Log "-------------------------------------------------------------------------------" -Color DarkCyan -usePrefix $false
Write-Log "" -usePrefix $false


# --- Step 0: Make sure the user is aware this will start a clean install ---
Write-Log "User Warning: This script will perform a clean installation of ComfyUI." -Color Yellow -Level "WARN"
Write-Log "This will overwrite any previous ComfyUI installations in the following directory:" -Color Yellow -Level "WARN"
Write-Log "Make sure to backup any important files before proceeding." -Color DarkYellow -Level "WARN"
Write-Log "Install Path: $InstallPath" -Color Yellow -Level "WARN"
Write-Host "[INFO] - Do you want to continue with the installation? (Y/N): " -ForegroundColor DarkCyan -NoNewline
$response = Read-Host
if ($response -notmatch '^[Yy]') {
    Write-Log "Installation cancelled by user." -Color Red -Level "ERROR"
    exit 1
}
Write-Log "" -usePrefix $false
# --- Step 1: Check and Install Python ---
Write-Log "Checking for Python installation..." -Color Magenta -Level "STEP 1"
$pythonPath = Get-Command python -ErrorAction SilentlyContinue
$pythonVersionOK = $false

if ($pythonPath) {
    $pythonExe = $pythonPath.Source
    if ($pythonExe -like "*WindowsApps*") {
        Write-Log "No valid Python found (Store alias detected). Starting installation." -Color DarkYellow -Level "WARN" -PrefixIndent 2
        $pythonVersionOK = $false
    } else {
        $pythonVersion = & $pythonExe --version 2>&1
        if ($pythonVersion -match 'Python (\d+\.\d+\.\d+)') {
            $versionParts = $matches[1] -split '\.'
            Write-Log "Python version detected: $pythonVersion" -Color DarkCyan -Level "INFO" -PrefixIndent 2
            Write-Log "" -usePrefix $false
            if ($versionParts.Count -ge 3) {
                $major = [int]$versionParts[0]
                $minor = [int]$versionParts[1]
                $patch = [int]$versionParts[2]
                if ($major -gt 3 -or ($major -eq 3 -and $minor -ge 12)) {
                    Write-Log "Python version is sufficient (3.12 or higher)." -Color Green -Level "OK" -PrefixIndent 2
                    $pythonVersionOK = $true
                }
            } else {
                Write-Log "Failed to parse Python version: $pythonVersion" -Color Red -Level "ERROR" -PrefixIndent 2
            }
        } else {
            Write-Log "Failed to retrieve Python version." -Color Red -Level "ERROR" -PrefixIndent 2
        }
    }
} else {
    Write-Log "Python is not installed." -Color Red -Level "ERROR" -PrefixIndent 2
}

if (-not $pythonVersionOK) {
    Write-Log "Python 3.12 or higher is required. Installing Python..." -Color Yellow -Level "INFO" -PrefixIndent 2
    $pythonInstallerUrl = "https://www.python.org/ftp/python/3.12.10/python-3.12.10-amd64.exe"
    $pythonInstallerPath = Join-Path $env:TEMP "python-3.12.10-installer.exe"
    Write-Log "Downloading Python installer from $pythonInstallerUrl" -Color Yellow -Level "INFO" -PrefixIndent 2
    Download-File -Uri $pythonInstallerUrl -OutFile $pythonInstallerPath
    if (-not (Test-Path $pythonInstallerPath)) {
        Write-Log "Failed to download Python installer." -Color Red -Level "ERROR" -PrefixIndent 2
        exit 1
    }
    Write-Log "Installing Python silently. This may take a few minutes..." -Color Yellow -Level "INFO" -PrefixIndent 2
    $process = Start-Process -FilePath $pythonInstallerPath -ArgumentList "/quiet InstallAllUsers=1 PrependPath=1 Include_launcher=1" -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        Write-Log "Python installation failed with exit code $process.ExitCode." -Color Red -Level "ERROR" -PrefixIndent 2
        exit 1
    }
    Remove-Item -Path $pythonInstallerPath -Force
    Write-Log "Python installation complete." -Color Green -Level "OK" -PrefixIndent 2
}

Write-Log "" -usePrefix $false

# --- Step 2: Installing dependencies (Aria2, 7-Zip, Git) ---
Write-Log "Checking and installing required tools..." -Color Magenta -Level "STEP 2"
Ensure-ToolInstalled -CommandName 'aria2c' -InstallAction { Install-Aria2-Binary }

Ensure-ToolInstalled -CommandName '7z' -CheckPath $sevenZipPath -InstallAction {
    $sevenZipInstaller = Join-Path $env:TEMP "7z-installer.exe"
    Download-File -Uri "https://www.7-zip.org/a/7z2201-x64.exe" -OutFile $sevenZipInstaller
    Start-Process -FilePath $sevenZipInstaller -ArgumentList "/S" -Wait
    Remove-Item $sevenZipInstaller
}

Ensure-ToolInstalled -CommandName 'git' -InstallAction {
    $gitInstaller = Join-Path $env:TEMP "Git-Installer.exe"
    Download-File -Uri "https://github.com/git-for-windows/git/releases/download/v2.41.0.windows.3/Git-2.41.0.3-64-bit.exe" -OutFile $gitInstaller
    Start-Process -FilePath $gitInstaller -ArgumentList "/VERYSILENT" -Wait
    Remove-Item $gitInstaller
}

Write-Log "" -usePrefix $false
Write-Log "All required tools installed and ready." -Color Green -Level "OK" -PrefixIndent 2

Invoke-AndLog "git" "config --system core.longpaths true"

Write-Log "" -usePrefix $false

# --- Step 3: Clone ComfyUI repository and create virtual environment ---
Write-Log "Cloning ComfyUI repository and setting up virtual environment..." -Color Magenta -Level "STEP 3"

$comfyuiRepoUrl = "https://github.com/comfyanonymous/ComfyUI.git"

if (Test-Path $comfyPath) {
    Write-Log "Removing existing ComfyUI directory for clean install..." -Color Yellow -Level "INFO" -PrefixIndent 2
    Write-Log "Ensuring no Python processes are running..." -Color DarkCyan -Level "INFO" -PrefixIndent 2
    Get-Process python -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Safe-RemoveDirectory -Path $comfyPath
    Write-Log "" -usePrefix $false
}

Write-Log "Cloning ComfyUI repository..." -Color Yellow -Level "INFO" -PrefixIndent 2
Invoke-AndLog "git" "clone $comfyuiRepoUrl `"$comfyPath`""
Invoke-AndLog "git" "config --global --add safe.directory `"$comfyPath`""
Write-Log "ComfyUI repository cloned successfully." -Color Green -Level "OK" -PrefixIndent 2

Write-Log "" -usePrefix $false
Write-Log "Creating virtual environment..." -Color Yellow -Level "INFO" -PrefixIndent 2
& python -m venv (Join-Path $comfyPath "venv")
if ($LASTEXITCODE -ne 0) {
    Write-Log "Failed to create virtual environment." -Color Red -Level "ERROR" -PrefixIndent 2
    exit 1
}

Write-Log "Virtual environment created successfully." -Color Green -Level "OK" -PrefixIndent 2

$foldersToCopy = @("custom_nodes", "input", "output", "models")

Write-Log "" -usePrefix $false
Write-Log "Copying necessary folders to the installation path..." -Color Magenta -Level "STEP 4"

foreach ($folder in $foldersToCopy) {
    $sourcePath = Join-Path -Path $comfyPath -ChildPath $folder
    $sourceName = $sourcePath.Replace($parentOfInstallPath, '').TrimStart('\', '/')
    if (-not (Test-Path $sourcePath)) {
        Write-Log "Source folder '$sourcePath' does not exist. Skipping." -Color DarkGray -Level "INFO" -PrefixIndent 2
        continue
    }
    $destPath = Join-Path -Path $InstallPath -ChildPath $folder
    $destName = $destPath.Replace($parentOfInstallPath, '').TrimStart('\', '/')
    if (Test-Path $destPath) {
        Write-Log "Removing existing folder: $destName" -Color Yellow -Level "INFO" -PrefixIndent 2
        Remove-Item -Recurse -Force $destPath
    }
    Copy-Item -Path $sourcePath -Destination $destPath -Recurse -Force
    Write-Log "Folder '$folder' copied successfully." -Color Green -Level "OK" -PrefixIndent 2
}

$userFolder = Join-Path -Path $comfyPath -ChildPath "user"
if (-not (Test-Path $userFolder)) {
    New-Item -ItemType Directory -Path $userFolder | Out-Null
}

Write-Log "" -usePrefix $false
Write-Log "Installing all required Python packages in the virtual environment..." -Color Magenta -Level "STEP 6"
Invoke-AndLog "$venvPython" "-m pip install --upgrade pip wheel"
Write-Log "Installing PyTorch (torch, torchvision, torchaudio) with CUDA 12.8 support..." -Color Yellow -Level "INFO" -PrefixIndent 2
Invoke-AndLog "$venvPython" "-m pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu128"
if ($LASTEXITCODE -ne 0) {
    Write-Log "Failed to install PyTorch with CUDA support." -Color Red -Level "ERROR" -PrefixIndent 2
    exit 1
}

$code = @"
try:
    import torch
    print(hasattr(torch, 'compile'))
except ImportError:
    print(False)
"@

$torchVersion = & $venvPython -c "import importlib.metadata; print(importlib.metadata.version('torch'))"
$cudaVersion = & $venvPython -c "import torch; print(torch.version.cuda)"
$torchCompiler = & $venvPython -c $code
Write-Log "Torch Version: $torchVersion" -Color Green -Level "OK" -PrefixIndent 2
Write-Log "CUDA Version: $cudaVersion" -Color Green -Level "OK" -PrefixIndent 2
if ($torchCompiler -eq $true) {
    $torchCompiler = "Enabled"
    Write-Log "Torch Compile Support: Enabled" -Color Green -Level "OK" -PrefixIndent 2
} else {
    $torchCompiler = "Disabled"
    Write-Log "Torch Compile Support: Disabled" -Color Red -Level "ERROR" -PrefixIndent 2
}

Write-Log "" -usePrefix $false
Write-Log "Installing ComfyUI dependencies..." -Color Yellow -Level "INFO" -PrefixIndent 2
Invoke-AndLog "$venvPython" "-m pip install -r `"$comfyPath\requirements.txt`""
if ($LASTEXITCODE -ne 0) {
    Write-Log "Failed to install ComfyUI dependencies." -Color Red -Level "ERROR" -PrefixIndent 2
    exit 1
}
Write-Log "ComfyUI dependencies installed successfully." -Color Green -Level "OK" -PrefixIndent 2

Write-Log "" -usePrefix $false
Write-Log "Downloading and installing additional dependencies..." -Color Magenta -Level "STEP 7"

Write-Log "Downloading Prebuilt Wheels..." -Color Yellow -Level "INFO" -PrefixIndent 2
$whlPath = Join-Path -Path $tempPath -ChildPath "whl"

foreach ($whlFile in $whlFiles) {
    $whlUrl = "$whlBaseUrl$whlFile"
    $outFile = Join-Path -Path $whlPath -ChildPath $whlFile
    Download-File -Uri $whlUrl -OutFile $outFile -PrefixIndent 4 -Color DarkGray
}

Write-Log "" -usePrefix $false
Write-Log "Installing Visual Studio Build Tools..." -Color Yellow -Level "INFO" -PrefixIndent 2
winget install --id Microsoft.VisualStudio.2022.BuildTools --override "--quiet --wait --norestart --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --add Microsoft.VisualStudio.Component.Windows11SDK.26100 --add Microsoft.VisualStudio.Component.VC.CMake.Project" --accept-package-agreements --accept-source-agreements -e --force

Write-Log "" -usePrefix $false
Write-Log "Installing xformers..." -Color Yellow -Level "INFO" -PrefixIndent 2
Invoke-AndLog "$venvPython" "-m pip install xformers --index-url https://download.pytorch.org/whl/cu128"
if ($LASTEXITCODE -ne 0) {
    Write-Log "Failed to install xformers." -Color Red -Level "ERROR" -PrefixIndent 2
    exit 1
}
Write-Log "Applying patches to xformers..." -Color Yellow -Level "INFO" -PrefixIndent 2
$xformersBaseDir = Join-Path $comfyPath "venv\Lib\site-packages\xformers"
$dirsToProcess = @(
    $xformersBaseDir,
    (Join-Path $xformersBaseDir "flash_attn_3")
)
foreach ($dir in $dirsToProcess) {
    $relativeDir = $dir.Replace($parentOfInstallPath, '').TrimStart('\', '/')
    if (Test-Path $dir) {      
        $exactFilePath = Join-Path $dir "pyd"
        if (Test-Path $exactFilePath) {
            Write-Log "Renaming 'pyd' to '_C.pyd' in [$relativeDir]" -Color Yellow -Level "INFO" -PrefixIndent 4
            try {
                Rename-Item -Path $exactFilePath -NewName "_C.pyd" -Force -ErrorAction Stop
                Write-Log "Renamed 'pyd' to '_C.pyd' successfully." -Color Green -Level "OK" -PrefixIndent 4
            } catch {
                Write-Log "Failed to rename 'pyd' to '_C.pyd': $_" -Color Red -Level "ERROR" -PrefixIndent 4
            }

        } else {
            $finalFilePath = Join-Path $dir "_C.pyd"
            if (Test-Path $finalFilePath) {
                Write-Log "'_C.pyd' already exists in [$relativeDir]. Skipping rename." -Color DarkGray -Level "INFO" -PrefixIndent 4
            } else {
                Write-Log "'pyd' not found in [$relativeDir]. Skipping rename." -Color DarkGray -Level "INFO" -PrefixIndent 4
            }
        }
    } else {
        Write-Log "Directory not found: [$relativeDir]" -Color Red -Level "ERROR" -PrefixIndent 4
    }
}
$xformerVersion = & $venvPython -c "import importlib.metadata; print(importlib.metadata.version('xformers'))"
Write-Log "xFormers Version: $xformerVersion" -Color Green -Level "OK" -PrefixIndent 2
Write-Log "" -usePrefix $false

Write-Log "Installing triton..." -Color Yellow -Level "INFO" -PrefixIndent 2
$tritonPath = Join-Path -Path $whlPath -ChildPath "triton-3.3.0-py3-none-any.whl"
if (Test-Path $tritonPath) {
    $success = $true

    Invoke-AndLog "$venvPython" "-m pip install `"$tritonPath`""
    if ($LASTEXITCODE -ne 0) {
        $success = $false
    }

    Invoke-AndLog "$venvPython" '-m pip install "triton-windows<3.4"'
    if ($LASTEXITCODE -ne 0) {
        $success = $false
    }
    if (-not $success) {
        Write-Log "Failed to install Triton." -Color Red -Level "ERROR" -PrefixIndent 2
        exit 1
    }
    $tritonVersion = & $venvPython -c "import importlib.metadata; print(importlib.metadata.version('triton'))"
    Write-Log "Triton Version: $tritonVersion" -Color Green -Level "OK" -PrefixIndent 2
} else {
    Write-Log "Triton wheel file not found: $tritonPath" -Color Red -Level "ERROR" -PrefixIndent 2
}
Write-Log "" -usePrefix $false

Write-Log "Installing flash attention..." -Color Yellow -Level "INFO" -PrefixIndent 2
$flashAttnPath = Join-Path -Path $whlPath -ChildPath "flash_attn-2.8.0+cu129torch2.7.1-cp312-cp312-win_amd64.whl"
if (Test-Path $flashAttnPath) {
    Invoke-AndLog "$venvPython" "-m pip install `"$flashAttnPath`""
    if ($LASTEXITCODE -ne 0) {
        Write-Log "Failed to install flash attention." -Color Red -Level "ERROR" -PrefixIndent 2
        exit 1
    }
    $flashAttnVersion = & $venvPython -c "import importlib.metadata; print(importlib.metadata.version('flash_attn'))"
    Write-Log "Flash attention Version: $flashAttnVersion" -Color Green -Level "OK" -PrefixIndent 2
} else {
    Write-Log "Flash attention wheel file not found: $flashAttnPath" -Color Red -Level "ERROR" -PrefixIndent 2
}
Write-Log "" -usePrefix $false

Write-Log "Installing sage attention..." -Color Yellow -Level "INFO" -PrefixIndent 2
$sageAttnPath = Join-Path -Path $whlPath -ChildPath "sageattention-2.2.0+cu129torch2.7.1-cp312-cp312-win_amd64.whl"
if (Test-Path $sageAttnPath) {
    Invoke-AndLog "$venvPython" "-m pip install `"$sageAttnPath`""
    if ($LASTEXITCODE -ne 0) {
        Write-Log "Failed to install sage attention." -Color Red -Level "ERROR" -PrefixIndent 2
        exit 1
    }
    $sageAttnVersion = & $venvPython -c "import importlib.metadata; print(importlib.metadata.version('sageattention'))"

    Write-Log "Sage attention Version: $sageAttnVersion" -Color Green -Level "OK" -PrefixIndent 2
} else {
    Write-Log "Sage attention wheel file not found: $sageAttnPath" -Color Red -Level "ERROR" -PrefixIndent 2
}
Write-Log "" -usePrefix $false

Write-Log "Installing causal conv1d..." -Color Yellow -Level "INFO" -PrefixIndent 2
$causalConvPath = Join-Path -Path $whlPath -ChildPath "causal_conv1d-1.5.0.post8+cu129torch2.7.1-cp312-cp312-win_amd64.whl"
if (Test-Path $causalConvPath) {
    Invoke-AndLog "$venvPython" "-m pip install `"$causalConvPath`""
    if ($LASTEXITCODE -ne 0) {
        Write-Log "Failed to install causal conv1d." -Color Red -Level "ERROR" -PrefixIndent 2
        exit 1
    }
    $causalConvVersion = & $venvPython -c "import importlib.metadata; print(importlib.metadata.version('causal_conv1d'))"
    Write-Log "Causal conv1d Version: $causalConvVersion" -Color Green -Level "OK" -PrefixIndent 2
} else {
    Write-Log "Causal conv1d wheel file not found: $causalConvPath" -Color Red -Level "ERROR" -PrefixIndent 2
}
Write-Log "" -usePrefix $false

Write-Log "Installing mamba ssm..." -Color Yellow -Level "INFO" -PrefixIndent 2
$mambaSsmPath = Join-Path -Path $whlPath -ChildPath "mamba_ssm-2.2.4+cu129torch2.7.1-cp312-cp312-win_amd64.whl"
if (Test-Path $mambaSsmPath) {
    Invoke-AndLog "$venvPython" "-m pip install `"$mambaSsmPath`""
    if ($LASTEXITCODE -ne 0) {
        Write-Log "Failed to install mamba ssm." -Color Red -Level "ERROR" -PrefixIndent 2
        exit 1
    }
    $mambaSsmVersion = & $venvPython -c "import importlib.metadata; print(importlib.metadata.version('mamba_ssm'))"
    Write-Log "Mamba ssm Version: $mambaSsmVersion" -Color Green -Level "OK" -PrefixIndent 2
} else {
    Write-Log "Mamba ssm wheel file not found: $mambaSsmPath" -Color Red -Level "ERROR" -PrefixIndent 2
}
Write-Log "" -usePrefix $false

Write-Log "Installing accelerate..." -Color Yellow -Level "INFO" -PrefixIndent 2
Invoke-AndLog "$venvPython" "-m pip install accelerate"
if ($LASTEXITCODE -ne 0) {
    Write-Log "Failed to install accelerate." -Color Red -Level "ERROR" -PrefixIndent 2
    exit 1
}
$accelerateVersion = & $venvPython -c "import importlib.metadata; print(importlib.metadata.version('accelerate'))"
Write-Log "Accelerate Version: $accelerateVersion" -Color Green -Level "OK" -PrefixIndent 2
Write-Log "" -usePrefix $false

$customNodesPath = Join-Path -Path $InstallPath -ChildPath "custom_nodes"
if (-not (Test-Path $customNodesPath)) {
    New-Item -ItemType Directory -Path $customNodesPath | Out-Null
}

$customNodesCsvPath = Join-Path -Path $tempPath -ChildPath "ComfyUI-QuickDeploy\ComfyUI-QuickDeploy-main\csv\custom_nodes.csv"

if (-not (Test-Path $customNodesCsvPath)) {
    Write-Log "Custom nodes CSV file not found, skipping custom nodes installation." -Color DarkGray -Level "INFO" -PrefixIndent 2
} else {
    $customNodes = Import-Csv -Path $customNodesCsvPath

    foreach ($node in $customNodes) {
        $nodeName = $node.Name
        $repoUrl = $node.RepoUrl

        $nodePath = if($node.Subfolder) {
            Join-Path -Path $customNodesPath -ChildPath $node.Subfolder
        } else {
            Join-Path -Path $customNodesPath -ChildPath $nodeName
        }

        if (-not (Test-Path $nodePath)) {
            Write-Log "Installing custom node: $nodeName" -Color Yellow -Level "INFO" -PrefixIndent 2

            $cloneTargetPath = if($node.Subfolder) {
                Split-Path -Path $nodePath -Parent
            } else {
                $nodePath
            }

            if ($nodeName -eq 'ComfyUI-Impact-Subpack') { $clonePath = Join-Path $cloneTargetPath "impact_subpack" } else { $clonePath = $cloneTargetPath }

            Invoke-AndLog "git" "clone $repoUrl `"$clonePath`""

            if ($node.RequirementsFile) {
                $reqPath = Join-Path -Path $nodePath -ChildPath $node.RequirementsFile
                if (Test-Path $reqPath) {
                    Write-Log "Installing requirements for custom node: $nodeName" -Color Yellow -Level "INFO" -PrefixIndent 4
                    Invoke-AndLog "$venvPython" "-m pip install -r `"$reqPath`""
                }
            }           
        } else {
            Write-Log "Custom node '$nodeName' already exists, skipping installation." -Color DarkGray -Level "INFO" -PrefixIndent 2
        }
    }
}