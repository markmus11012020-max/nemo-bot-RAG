@echo off
setlocal EnableDelayedExpansion
chcp 65001 >nul 2>&1

:: ============================================================
::  RAG Agent — start.bat
::  Оркестрация: stop → cache clean → venv + deps → start
:: ============================================================

set "PROJECT_DIR=%~dp0"
cd /d "%PROJECT_DIR%"

set "VENV_DIR=%PROJECT_DIR%.venv"
set "PYTHON_EXE=%VENV_DIR%\Scripts\python.exe"
set "PIP_EXE=%VENV_DIR%\Scripts\pip.exe"
set "MAIN_MODULE=rag_agent.py"
set "REQUIREMENTS=requirements.txt"
set "PID_FILE=%PROJECT_DIR%.rag_agent.pid"

echo.
echo ============================================================
echo   RAG Agent — Deploy ^& Start
echo ============================================================
echo   Directory: %PROJECT_DIR%
echo.

:: ----------------------------------------------------------
::  1. STOP old processes
:: ----------------------------------------------------------
echo [1/4] Stopping old processes...

:: Kill by PID file if present
if exist "%PID_FILE%" (
    set /p OLD_PID=<"%PID_FILE%"
    if defined OLD_PID (
        taskkill /PID !OLD_PID! /F /T >nul 2>&1
        if !ERRORLEVEL! EQU 0 (
            echo   Killed process PID=!OLD_PID!
        ) else (
            echo   Process PID=!OLD_PID! already stopped
        )
    )
    del /f /q "%PID_FILE%" >nul 2>&1
)

:: Kill any python process running rag_agent.py
for /f "tokens=2 delims=," %%P in (
    'wmic process where "CommandLine like '%%rag_agent.py%%' and Name='python.exe'" get ProcessId /format:csv 2^>nul'
) do (
    if not "%%P"=="" (
        taskkill /PID %%P /F /T >nul 2>&1
        if !ERRORLEVEL! EQU 0 echo   Killed leftover python PID=%%P
    )
)

:: Alternative via tasklist / findstr (more portable)
for /f "tokens=2" %%P in (
    'tasklist /FI "IMAGENAME eq python.exe" /FO LIST 2^>nul ^| findstr /I "PID:"'
) do (
    wmic process where "ProcessId=%%P" get CommandLine 2>nul | findstr /I "rag_agent.py" >nul 2>&1
    if !ERRORLEVEL! EQU 0 (
        taskkill /PID %%P /F /T >nul 2>&1
        if !ERRORLEVEL! EQU 0 echo   Killed python PID=%%P ^(rag_agent^)
    )
)

echo   Done.
echo.

:: ----------------------------------------------------------
::  2. CLEAN cache
:: ----------------------------------------------------------
echo [2/4] Cleaning cache...

:: __pycache__ directories
for /d /r "%PROJECT_DIR%" %%D in (__pycache__) do (
    if exist "%%D" (
        rd /s /q "%%D" 2>nul
        echo   Removed: %%D
    )
)

:: *.pyc / *.pyo
for /r "%PROJECT_DIR%" %%F in (*.pyc *.pyo) do (
    if exist "%%F" (
        del /f /q "%%F" 2>nul
        echo   Removed: %%F
    )
)

:: pytest / mypy / ruff / coverage caches
if exist "%PROJECT_DIR%.pytest_cache" rd /s /q "%PROJECT_DIR%.pytest_cache" 2>nul
if exist "%PROJECT_DIR%.mypy_cache"   rd /s /q "%PROJECT_DIR%.mypy_cache" 2>nul
if exist "%PROJECT_DIR%.ruff_cache"   rd /s /q "%PROJECT_DIR%.ruff_cache" 2>nul
if exist "%PROJECT_DIR%.coverage"     del /f /q "%PROJECT_DIR%.coverage" 2>nul
if exist "%PROJECT_DIR%htmlcov"       rd /s /q "%PROJECT_DIR%htmlcov" 2>nul

echo   Done.
echo.

:: ----------------------------------------------------------
::  3. BUILD environment + install dependencies
:: ----------------------------------------------------------
echo [3/4] Building environment and installing dependencies...

:: Check python is available
where python >nul 2>&1
if !ERRORLEVEL! NEQ 0 (
    where py >nul 2>&1
    if !ERRORLEVEL! NEQ 0 (
        echo   [ERROR] Python not found in PATH. Install Python 3.10+ and retry.
        exit /b 1
    )
    set "SYS_PYTHON=py -3"
) else (
    set "SYS_PYTHON=python"
)

:: Create venv if missing
if not exist "%PYTHON_EXE%" (
    echo   Creating virtual environment: %VENV_DIR%
    %SYS_PYTHON% -m venv "%VENV_DIR%"
    if !ERRORLEVEL! NEQ 0 (
        echo   [ERROR] Failed to create venv.
        exit /b 1
    )
) else (
    echo   Virtual environment already exists.
)

:: Upgrade pip / setuptools / wheel
echo   Upgrading pip...
"%PYTHON_EXE%" -m pip install --upgrade pip setuptools wheel -q
if !ERRORLEVEL! NEQ 0 (
    echo   [WARN] pip upgrade failed, continuing...
)

:: Install / update dependencies
if exist "%PROJECT_DIR%%REQUIREMENTS%" (
    echo   Installing from %REQUIREMENTS% ...
    "%PIP_EXE%" install -r "%PROJECT_DIR%%REQUIREMENTS%"
    if !ERRORLEVEL! NEQ 0 (
        echo   [ERROR] Dependency installation failed.
        exit /b 1
    )
) else (
    echo   [WARN] %REQUIREMENTS% not found — skipping install.
)

:: Ensure .env exists (copy from example if needed)
if not exist "%PROJECT_DIR%.env" (
    if exist "%PROJECT_DIR%.env.example" (
        copy /y "%PROJECT_DIR%.env.example" "%PROJECT_DIR%.env" >nul
        echo   Created .env from .env.example — fill in your API keys!
    ) else (
        echo   [WARN] No .env and no .env.example found.
    )
)

echo   Done.
echo.

:: ----------------------------------------------------------
::  4. START project
:: ----------------------------------------------------------
echo [4/4] Starting RAG Agent...
echo ------------------------------------------------------------

if not exist "%PROJECT_DIR%%MAIN_MODULE%" (
    echo   [ERROR] %MAIN_MODULE% not found.
    exit /b 1
)

:: Run in current console (foreground). For background use start /b.
"%PYTHON_EXE%" "%PROJECT_DIR%%MAIN_MODULE%"
set "EXIT_CODE=!ERRORLEVEL!"

echo.
echo ------------------------------------------------------------
echo   Process finished with exit code: !EXIT_CODE!
echo ============================================================

endlocal
exit /b %EXIT_CODE%
