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

# Define colors for output
$colors = @{
    Red = [ConsoleColor]::Red
    Green = [ConsoleColor]::Green
    Yellow = [ConsoleColor]::Yellow
    Blue = [ConsoleColor]::Blue
    Cyan = [ConsoleColor]::Cyan
    Reset = [ConsoleColor]::White
}

#===========================================================================
# SECTION 1: SCRIPT CONFIGURATION & HELPER FUNCTIONS
#===========================================================================

# --- Cleaning and configuring paths ---
$InstallPath = $InstallPath.TrimEnd('"')
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Setting base path as the main installation directory
$comfyPath = Join-Path -Path $InstallPath -ChildPath "ComfyUI"

# Function to write output with color
function Write-OutputWithColor {
    param (
        [string]$Message,
        [string]$Color = 'Reset'
    )
    $colorValue = $colors[$Color]
    $originalColor = $Host.UI.RawUI.ForegroundColor
    $Host.UI.RawUI.ForegroundColor = $colorValue
    Write-Host $Message
    $Host.UI.RawUI.ForegroundColor = $originalColor
}

Write-OutputWithColor "Starting ComfyUI installation in $comfyPath..." 'Cyan'