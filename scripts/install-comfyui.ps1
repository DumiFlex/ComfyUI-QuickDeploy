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
    [string]$InstallPath = $PSScriptRoot,
    [string]$TempPath = $PSScriptRoot
)

#===========================================================================
# SECTION 1: SCRIPT CONFIGURATION & HELPER FUNCTIONS
#===========================================================================

# --- Cleaning and configuring paths ---
$InstallPath = $InstallPath.TrimEnd('"')
Write-Log "Installation path set to: $InstallPath" -Color Cyan -Level "INFO" -PrefixIndent 2
Write-Log "Temporary path set to: $TempPath" -Color Cyan -Level "INFO" -PrefixIndent 2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Setting base path as the main installation directory
$comfyPath = Join-Path -Path $InstallPath -ChildPath "ComfyUI"
$whlPath = Join-Path -Path $InstallPath -ChildPath "whl"
$logPath = Join-Path $InstallPath "logs"
$logFile = Join-Path $logPath "install_log.txt"
$sevenZipPath = "C:\Program Files\7-Zip\7z.exe"

$venvPythonPath = Join-Path -Path $comfyPath -ChildPath "venv\Scripts\python.exe"

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
        [string]$OutFile
    )

    if (Test-Path $OutFile) {
        Write-Log "Skipping: $((Split-Path $OutFile -Leaf)) (already exists)." -Color DarkGray -Level "INFO"
    } else {
        $fileName = Split-Path -Path $Uri -Leaf
        if (Get-Command 'aria2c' -ErrorAction SilentlyContinue) {
            Write-Log "[INFO] Downloading $fileName..." -Color Yellow -Level "INFO" -PrefixIndent 2
            $aria_args = "-c -x 16 -s 16 -k 1M --dir=`"$((Split-Path $OutFile -Parent))`" --out=`"$((Split-Path $OutFile -Leaf))`" `"$Uri`""
            Invoke-AndLog "aria2c" $aria_args
        } else {
            Write-Log "[WARN] Aria2 not found. Falling back to standard download: $fileName" -Color DarkYellow -Level "WARN" -PrefixIndent 2
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile
        }
    }
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
# --- Banner ---
Write-Log "-------------------------------------------------------------------------------" -Color Cyan -usePrefix $false
$asciiBanner = @'
           ______                ____      __  ______     ____    ____ 
          / ____/___  ____ ___  / __/_  __/ / / /  _/    / __ \  / __ \
         / /   / __ \/ __ `__ \/ /_/ / / / / / // /_____/ / / / / / / /
        / /___/ /_/ / / / / / / __/ /_/ / /_/ // /_____/ /_/ / / /_/ / 
        \____/\____/_/ /_/ /_/_/  \__, /\____/___/     \___\_\/_____/  
                                 /____/                                                            
'@
Write-Host $asciiBanner -ForegroundColor Cyan
Write-Log "-------------------------------------------------------------------------------" -Color Cyan -usePrefix $false
Write-Log "                      ComfyUI - Quick & Clean Installer                        " -Color Cyan -usePrefix $false
Write-Log "                           Version 1.0 by DumiFlex                             " -Color Cyan -usePrefix $false
Write-Log "-------------------------------------------------------------------------------" -Color Cyan -usePrefix $false
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
            Write-Log "Python version detected: $pythonVersion" -Color Blue -Level "INFO" -PrefixIndent 2
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

if (-not (Test-Path $comfyPath)) {
    Write-Log "Cloning ComfyUI repository..." -Color Yellow -Level "INFO" -PrefixIndent 2
    Invoke-AndLog "git" "clone $comfyuiRepoUrl `"$comfyPath`""
    Write-Log "ComfyUI repository cloned successfully." -Color Green -Level "OK" -PrefixIndent 2
} else {
    Write-Log "ComfyUI directory already exists." -Color DarkYellow -Level "WARN" -PrefixIndent 2
    Write-Log "This script requires a clean installation. Continuing will DELETE the existing folder and all its contents." -Color DarkYellow -Level "WARN" -PrefixIndent 2
    
    Write-Host "  [INFO] - Do you want to overwrite and continue with a fresh install? (Y/N): " -ForegroundColor DarkCyan -NoNewline
    $response = Read-Host
    if ($response -match '^[Yy]') {
        Write-Log "Removing existing ComfyUI directory for clean install..." -Color Yellow -Level "INFO" -PrefixIndent 4
        Remove-Item -Recurse -Force $comfyPath

        Write-Log "Cloning ComfyUI repository..." -Color Yellow -Level "INFO" -PrefixIndent 4
        Invoke-AndLog "git" "clone $comfyuiRepoUrl `"$comfyPath`""
        Write-Log "ComfyUI repository cloned successfully." -Color Green -Level "OK" -PrefixIndent 5
    } else {
        Write-Log "Installation cancelled by user." -Color Red -Level "ERROR" -PrefixIndent 2
        exit 1
    }
}

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
    $destPath = Join-Path -Path $InstallPath -ChildPath $folder
    if (Test-Path $sourcePath) {
        if (-not (Test-Path $destPath)) {
            Copy-Item -Path $sourcePath -Destination $destPath -Recurse -Force
            Write-Log "Folder '$folder' copied successfully." -Color Green -Level "OK" -PrefixIndent 2
        } else {
            Write-Log "Folder '$folder' already exists in the destination. Skipping copy." -Color DarkGray -Level "INFO" -PrefixIndent 2
        }
    } else {
        Write-Log "Source folder '$sourcePath' does not exist. Skipping." -Color DarkGray -Level "INFO" -PrefixIndent 2
    }
}

Write-Log "" -usePrefix $false
Write-Log "Installing all required Python packages in the virtual environment..." -Color Magenta -Level "STEP 6"
Invoke-AndLog "$venvPython" "-m pip install --upgrade pip wheel"
Write-Log "Installing torch, torchvision, and torchaudio with CUDA 12.8 support..." -Color Yellow -Level "INFO" -PrefixIndent 2
Invoke-AndLog "$venvPython" "-m pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu128"
Write-Log "Installing ComfyUI dependencies..." -Color Yellow -Level "INFO" -PrefixIndent 2
Invoke-AndLog "$venvPython" "-m pip install -r `"$comfyPath\requirements.txt`""

Write-Log "" -usePrefix $false
Write-Log "Installing additional dependencies..." -Color Magenta -Level "STEP 7"

Write-Log "Installing Visual Studio Build Tools..." -Color Yellow -Level "INFO" -PrefixIndent 2
winget install --id Microsoft.VisualStudio.2022.BuildTools -e --source winget --override "--quiet --wait --norestart --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --add Microsoft.VisualStudio.Component.Windows10SDK.20348"

Write-Log "Installing xformers..." -Color Yellow -Level "INFO" -PrefixIndent 2
Invoke-AndLog "$venvPython" "-m pip install xformers --index-url https://download.pytorch.org/whl/cu128"
Write-Log "Applying patches to xformers..." -Color Yellow -Level "INFO" -PrefixIndent 2
$xformersBaseDir = Join-Path $comfyPath "venv\Lib\site-packages\xformers"
$dirsToProcess = @(
    $xformersBaseDir,
    (Join-Path $xformersBaseDir "flash_attn_3")
)
foreach ($dir in $dirsToProcess) {
    if (Test-Path $dir) {
        $exactFilePath = Join-Path $dir "pyd"
        if (Test-Path $exactFilePath) {
            Write-Log "Renaming 'pyd' to '_C.pyd' in $dir" -Color Yellow -Level "INFO" -PrefixIndent 4
            try {
                Rename-Item -Path $exactFilePath -NewName "_C.pyd" -Force -ErrorAction Stop
                Write-Log "Renamed 'pyd' to '_C.pyd' successfully." -Color Green -Level "OK" -PrefixIndent 4
            } catch {
                Write-Log "Failed to rename 'pyd' to '_C.pyd': $_" -Color Red -Level "ERROR" -PrefixIndent 4
            }

        } else {
            $finalFilePath = Join-Path $dir "_C.pyd"
            if (Test-Path $finalFilePath) {
                Write-Log "'_C.pyd' already exists in $dir. Skipping rename." -Color DarkGray -Level "INFO" -PrefixIndent 4
            } else {
                Write-Log "'pyd' not found in $dir. Skipping rename." -Color DarkGray -Level "INFO" -PrefixIndent 4
            }
        }
    } else {
        Write-Log "Directory not found: $dir" -Color Red -Level "ERROR" -PrefixIndent 4
    }
}

Write-Log "Installing triton..." -Color Yellow -Level "INFO" -PrefixIndent 2
$tritonPath = Join-Path -Path $whlPath -ChildPath "triton-3.3.0-py3-none-any.whl"
