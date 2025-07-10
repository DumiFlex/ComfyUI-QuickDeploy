#Requires -RunAsAdministrator

param(
    [string]$InstallPath = $PSScriptRoot 
)

Write-Host "Installing ComfyUI to $InstallPath"