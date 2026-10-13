@echo off
setlocal EnableDelayedExpansion
chcp 65001 >nul 2>&1

:: ============================================================
::  RAG Agent — start.bat  (safe version)
::  Оркестрация: stop → cache clean → venv + deps → start
:: ============================================================

:: Project directory (always ends with \ from %~dp0 — strip it for safety)
set "PROJECT_DIR=%~dp0"
if "%PROJECT_DIR:~-1%"=="\" set "PROJECT_DIR=%PROJECT_DIR:~0,-1%"

cd /d "%PROJECT_DIR%"
if errorlevel 1 (
    echo [ERROR] Cannot cd to project directory: %PROJECT_DIR%
    exit /b 1
)

set "VENV_DIR=%PROJECT_DIR%\.venv"
set "PYTHON_EXE=%VENV_DIR%\Scripts\python.exe"
set "PIP_EXE=%VENV_DIR%\Scripts\pip.exe"
set "MAIN_MODULE=rag_agent.py"
set "REQUIREMENTS=requirements.txt"
set "PID_FILE=%PROJECT_DIR%\.rag_agent.pid"

echo.
echo ============================================================
echo   RAG Agent — Deploy ^& Start
echo ============================================================
echo   Directory: %PROJECT_DIR%
echo.

:: ----------------------------------------------------------
::  1. STOP old processes (only rag_agent.py)
:: ----------------------------------------------------------
echo [1/4] Stopping old processes...

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

:: Kill only python processes whose command line contains rag_agent.py
for /f "tokens=2 delims=," %%P in (
    'wmic process where "Name='python.exe' and CommandLine like '%%rag_agent.py%%'" get ProcessId /format:csv 2^>nul'
) do (
    if not "%%P"=="" (
        echo %%P| findstr /r "^[0-9][0-9]*$" >nul 2>&1
        if !ERRORLEVEL! EQU 0 (
            taskkill /PID %%P /F /T >nul 2>&1
            if !ERRORLEVEL! EQU 0 echo   Killed leftover python PID=%%P
        )
    )
)

echo   Done.
echo.

:: ----------------------------------------------------------
::  2. CLEAN cache — SAFE: only exact __pycache__ / *.pyc / known dirs
:: ----------------------------------------------------------
echo [2/4] Cleaning cache...

:: Remove __pycache__ folders only if path ends with \__pycache__
:: Using dir /s /b to avoid dangerous for /d /r with trailing slash
for /f "delims=" %%D in ('dir /s /b /ad "%PROJECT_DIR%\__pycache__" 2^>nul') do (
    echo %%~D| findstr /i /e "\\__pycache__" >nul 2>&1
    if !ERRORLEVEL! EQU 0 (
        if exist "%%~D" (
            rd /s /q "%%~D" 2>nul
            if not exist "%%~D" echo   Removed: %%~D
        )
    )
)

:: Remove only *.pyc and *.pyo files under project
for /f "delims=" %%F in ('dir /s /b /a-d "%PROJECT_DIR%\*.pyc" 2^>nul') do (
    if exist "%%~F" (
        del /f /q "%%~F" 2>nul
        echo   Removed: %%~F
    )
)
for /f "delims=" %%F in ('dir /s /b /a-d "%PROJECT_DIR%\*.pyo" 2^>nul') do (
    if exist "%%~F" (
        del /f /q "%%~F" 2>nul
        echo   Removed: %%~F
    )
)

:: Known cache directories at project root only (not recursive wildcards)
if exist "%PROJECT_DIR%\.pytest_cache" (
    rd /s /q "%PROJECT_DIR%\.pytest_cache" 2>nul
    echo   Removed: %PROJECT_DIR%\.pytest_cache
)
if exist "%PROJECT_DIR%\.mypy_cache" (
    rd /s /q "%PROJECT_DIR%\.mypy_cache" 2>nul
    echo   Removed: %PROJECT_DIR%\.mypy_cache
)
if exist "%PROJECT_DIR%\.ruff_cache" (
    rd /s /q "%PROJECT_DIR%\.ruff_cache" 2>nul
    echo   Removed: %PROJECT_DIR%\.ruff_cache
)
if exist "%PROJECT_DIR%\htmlcov" (
    rd /s /q "%PROJECT_DIR%\htmlcov" 2>nul
    echo   Removed: %PROJECT_DIR%\htmlcov
)
if exist "%PROJECT_DIR%\.coverage" (
    del /f /q "%PROJECT_DIR%\.coverage" 2>nul
    echo   Removed: %PROJECT_DIR%\.coverage
)

echo   Done.
echo.

:: ----------------------------------------------------------
::  3. BUILD environment + install dependencies
:: ----------------------------------------------------------
echo [3/4] Building environment and installing dependencies...

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

echo   Upgrading pip...
"%PYTHON_EXE%" -m pip install --upgrade pip setuptools wheel -q
if !ERRORLEVEL! NEQ 0 (
    echo   [WARN] pip upgrade failed, continuing...
)

if exist "%PROJECT_DIR%\%REQUIREMENTS%" (
    echo   Installing from %REQUIREMENTS% ...
    "%PIP_EXE%" install -r "%PROJECT_DIR%\%REQUIREMENTS%"
    if !ERRORLEVEL! NEQ 0 (
        echo   [ERROR] Dependency installation failed.
        exit /b 1
    )
) else (
    echo   [WARN] %REQUIREMENTS% not found — skipping install.
)

if not exist "%PROJECT_DIR%\.env" (
    if exist "%PROJECT_DIR%\.env.example" (
        copy /y "%PROJECT_DIR%\.env.example" "%PROJECT_DIR%\.env" >nul
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

if not exist "%PROJECT_DIR%\%MAIN_MODULE%" (
    echo   [ERROR] %MAIN_MODULE% not found in %PROJECT_DIR%
    exit /b 1
)

"%PYTHON_EXE%" "%PROJECT_DIR%\%MAIN_MODULE%"
set "EXIT_CODE=!ERRORLEVEL!"

echo.
echo ------------------------------------------------------------
echo   Process finished with exit code: !EXIT_CODE!
echo ============================================================

endlocal
exit /b %EXIT_CODE%
