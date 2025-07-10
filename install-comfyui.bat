@echo off
setlocal EnableDelayedExpansion

set "GITHUB_REPO=https://github.com/DumiFlex/ComfyUI-QuickDeploy"

:: Define ANSI color codes
set "ESC="
set "RESET=%ESC%[0m"
set "GREEN=%ESC%[32m"
set "YELLOW=%ESC%[33m"
set "CYAN=%ESC%[36m"
set "RED=%ESC%[31m"

:: Project info
set "PROJECT_NAME=CozyComfyUI"
set "SCRIPTS_DIR=%~dp0scripts"

:: Request admin if needed
net session >nul 2>&1
if %errorlevel% NEQ 0 (
    echo !YELLOW![INFO] Requesting administrator privileges for %PROJECT_NAME% setup...!RESET!
    powershell.exe -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit
)

echo !GREEN![OK] Administrator rights confirmed.!RESET!
echo.

:: Create temp directory
echo !CYAN![INFO] Setting up temporary directory...!RESET!
set "TEMP_DIR=%~dp0temp"
if exist "%TEMP_DIR%" rd /s /q "%TEMP_DIR%"
mkdir "%TEMP_DIR%"

set "REPO_ZIP_URL=%GITHUB_REPO%/archive/refs/heads/main.zip"
set "ZIP_FILE=%TEMP_DIR%\ComfyUI-QuickDeploy.zip"
set "EXTRACT_DIR=%TEMP_DIR%\ComfyUI-QuickDeploy"

:: Download the repository zip
echo !CYAN![INFO] Downloading repo ZIP archive...!RESET!
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri '%REPO_ZIP_URL%' -OutFile '%ZIP_FILE%'"

if %errorlevel% NEQ 0 (
    echo !RED![ERROR] Failed to download the repository archive from %GITHUB_REPO%!RESET!
    pause
    exit /b 1
)

echo !GREEN![OK] Repository archive downloaded successfully.!RESET!

:: Extract the required files
echo !CYAN![INFO] Extracting repository archive...!RESET!
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "Expand-Archive -Path '%ZIP_FILE%' -DestinationPath '%EXTRACT_DIR%' -Force"

if %errorlevel% NEQ 0 (
    echo !RED![ERROR] Failed to extract the repository archive!RESET!
    pause
    exit /b 1
)

echo !GREEN![OK] Repository archive extracted successfully.!RESET!

:: Copy relevant files from the extracted directory to the current directory
echo !CYAN![INFO] Copying relevant files from the repository...!RESET!
if not exist "%EXTRACT_DIR%\ComfyUI-QuickDeploy-main" (
    echo !RED![ERROR] Extracted directory does not contain the expected structure!RESET!
    pause
    exit /b 1
)

set "SRC_DIR=%EXTRACT_DIR%\ComfyUI-QuickDeploy-main"
set "DEST_DIR=%~dp0"
:: Remove any trailing backslash just in case (optional safety)
if "%DEST_DIR:~-1%"=="\" set "DEST_DIR=%DEST_DIR:~0,-1%"


set "EXCLUDE_FILES=README.md,LICENSE,install-comfyui.bat"
set "EXCLUDE_DIRS=docs,tests,examples"

set "EXCLUDE_FILES_ARGS="
for %%F in (%EXCLUDE_FILES%) do (
    set "EXCLUDE_FILES_ARGS=!EXCLUDE_FILES_ARGS! /XF %%F"
)

set "EXCLUDE_DIRS_ARGS="
for %%D in (%EXCLUDE_DIRS%) do (
    set "EXCLUDE_DIRS_ARGS=!EXCLUDE_DIRS_ARGS! /XD %%D"
)

robocopy "%SRC_DIR%" "%DEST_DIR%" /E /Z /V /NP /R:3 /W:5 !EXCLUDE_FILES_ARGS! !EXCLUDE_DIRS_ARGS! >nul 2>&1

if %errorlevel% GEQ 8 (
    echo !RED![ERROR] Failed to copy files from the repository!RESET!
    pause
    exit /b 1
)

echo !GREEN![OK] Files copied successfully from the repository!RESET!

pause
exit

:: Create scripts folder if missing
if not exist "%SCRIPTS_DIR%" (
    echo !YELLOW![INFO] Creating scripts folder: %SCRIPTS_DIR%!RESET!
    mkdir "%SCRIPTS_DIR%"
)

:: Download URLs
set "URL_INSTALL_PS=https://yourdomain.com/scripts/install.ps1"
set "URL_UPDATE_PS=https://yourdomain.com/scripts/update.ps1"
:: ... add more URLs as needed

:: Download scripts
echo !CYAN![INFO] Downloading setup scripts...!RESET!
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri '%URL_INSTALL_PS%' -OutFile '%SCRIPTS_DIR%\install.ps1'"

:: TODO: Add error checking after each download

echo !GREEN![OK] All scripts downloaded.!RESET!
echo.

:: Run the installer
echo !CYAN![INFO] Launching the main install script...!RESET!
powershell.exe -ExecutionPolicy Bypass -File "%SCRIPTS_DIR%\install.ps1" -InstallPath "%~dp0"

:: Cleanup
echo !CYAN![INFO] Cleaning up temporary files...!RESET!
rd /s /q "%TEMP_DIR%"

echo.
echo !CYAN![INFO] Installation complete.!RESET!
pause
