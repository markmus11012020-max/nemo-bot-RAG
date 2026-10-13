@echo off & setlocal EnableExtensions EnableDelayedExpansion

:: ============================================================
::  nemo-bot-RAG - start.bat
::  Orchestration: stop -> cache clean -> venv + deps -> start
::  Entry point: bot.py (Telegram RAG bot)
:: ============================================================

chcp 65001 >nul 2>&1

:: ----------------------------------------------------------
::  Resolve project directory
:: ----------------------------------------------------------
set "PROJECT_DIR=%~dp0"
if "%PROJECT_DIR:~-1%"=="\" set "PROJECT_DIR=%PROJECT_DIR:~0,-1%"

:: ----------------------------------------------------------
::  Safety: refuse to run inside system directories
:: ----------------------------------------------------------
set "_SAFE=1"
echo(%PROJECT_DIR% | findstr /i /c:"C:\Windows" /c:"C:\Program Files" /c:"C:\ProgramData" >nul 2>&1 && set "_SAFE=0"
echo(%PROJECT_DIR% | findstr /i /c:"C:\Users\Default" /c:"C:\Users\Public" >nul 2>&1 && set "_SAFE=0"
if "%_SAFE%"=="0" (
    echo [ERROR] Refusing to run inside system directory:
    echo         %PROJECT_DIR%
    exit /b 1
)

cd /d "%PROJECT_DIR%" || (echo [ERROR] Cannot cd to %PROJECT_DIR% & exit /b 1)

:: ----------------------------------------------------------
::  Configuration  (adapted for nemo-bot-RAG)
:: ----------------------------------------------------------
set "VENV_DIR=%PROJECT_DIR%\.venv"
set "PYTHON_EXE=%VENV_DIR%\Scripts\python.exe"
set "PIP_EXE=%VENV_DIR%\Scripts\pip.exe"
set "ACTIVATE=%VENV_DIR%\Scripts\activate.bat"
set "MAIN_MODULE=bot.py"
set "REQUIREMENTS=requirements.txt"
set "PID_FILE=%PROJECT_DIR%\.nemo_bot.pid"
set "LOG_FILE=%PROJECT_DIR%\deploy.log"
set "MIN_PY_MAJOR=3"
set "MIN_PY_MINOR=10"

:: ----------------------------------------------------------
::  Parse CLI flags
:: ----------------------------------------------------------
set "FLAG_NO_CACHE=0"
set "FLAG_REBUILD=0"
set "FLAG_DRY_RUN=0"
set "FLAG_FOREGROUND=0"

:parse_args
if "%~1"=="" goto args_done
if /i "%~1"=="--no-cache"     (set "FLAG_NO_CACHE=1" & shift & goto parse_args)
if /i "%~1"=="--rebuild"      (set "FLAG_REBUILD=1"  & shift & goto parse_args)
if /i "%~1"=="--dry-run"      (set "FLAG_DRY_RUN=1"  & shift & goto parse_args)
if /i "%~1"=="--foreground"   (set "FLAG_FOREGROUND=1" & shift & goto parse_args)
if /i "%~1"=="-h"             goto show_help
if /i "%~1"=="--help"         goto show_help
echo [WARN] Unknown flag ignored: %~1
shift
goto parse_args

:show_help
echo Usage: start.bat [--no-cache] [--rebuild] [--dry-run] [--foreground] [-h]
echo.
echo   --no-cache    Skip cache cleanup step
echo   --rebuild     Recreate virtual environment from scratch
echo   --dry-run     Print actions without executing destructive ones
echo   --foreground  Run bot in foreground (default, Ctrl+C to stop)
echo   -h --help     Show this help message
exit /b 0

:args_done

:: ----------------------------------------------------------
::  Banner
:: ----------------------------------------------------------
echo.
echo ============================================================
echo   nemo-bot-RAG - Deploy ^& Start
echo   %date% %time%
echo   Directory: %PROJECT_DIR%
echo ============================================================
echo.

call :log "Deploy started in %PROJECT_DIR%"

:: ============================================================
::  STEP 1/4 - Stop old processes
:: ============================================================
echo [1/4] Stopping old processes...
call :log "Step 1: stop old processes"

if exist "%PID_FILE%" (
    set /p OLD_PID=<"%PID_FILE%"
    if defined OLD_PID call :kill_pid "!OLD_PID!" "from PID file"
    del /f /q "%PID_FILE%" >nul 2>&1
)

REM Kill any python process running bot.py
REM NOTE: single outer quotes only. Doubling them ('') makes cmd fail to
REM resolve the command and leaves a stray "nul'" file behind.
for /f "tokens=2 delims=," %%P in (
    'wmic process where "Name='python.exe' and CommandLine like '%%bot.py%%'" get ProcessId /format:csv 2^>nul'
) do (
    set "LPID=%%P"
    if defined LPID (
        set "_PIDCHK=!LPID!"
        echo !_PIDCHK!| findstr /r "^[0-9][0-9]*$" >nul 2>&1
        if !ERRORLEVEL! EQU 0 call :kill_pid "!LPID!" "matched bot.py"
    )
)

echo   Done.
echo.

:: ============================================================
::  STEP 2/4 - Clean cache (safe: only known cache artifacts)
:: ============================================================
if "%FLAG_NO_CACHE%"=="1" (
    echo [2/4] Cache cleanup skipped ^(--no-cache^).
    goto skip_cache
)

echo [2/4] Cleaning cache...
call :log "Step 2: clean cache"

REM __pycache__ directories (only those whose basename is exactly __pycache__)
REM NOTE: "dir /s /b /ad <path>\__pycache__" lists SUBdirectories of that path,
REM which is always empty - so we scan the project root and filter by basename.
REM Paths inside .venv are skipped: wiping site-packages bytecode just forces a
REM slow recompile on the next start.
for /f "delims=" %%D in ('dir /s /b /ad "%PROJECT_DIR%" 2^>nul') do (
    if /i "%%~nxD"=="__pycache__" (
        set "CAND=%%D"
        if "!CAND:%VENV_DIR%=!"=="!CAND!" (
            if exist "%%~D" (
                if "%FLAG_DRY_RUN%"=="0" rd /s /q "%%~D" 2>nul
                echo   Removed: %%~D
            )
        )
    )
)

REM .pyc files (project only, .venv skipped)
for /f "delims=" %%F in ('dir /s /b /a-d "%PROJECT_DIR%\*.pyc" 2^>nul') do (
    set "CAND=%%F"
    if "!CAND:%VENV_DIR%=!"=="!CAND!" (
        if exist "%%~F" (
            if "%FLAG_DRY_RUN%"=="0" del /f /q "%%~F" 2>nul
            echo   Removed: %%~F
        )
    )
)

REM .pyo files (project only, .venv skipped)
for /f "delims=" %%F in ('dir /s /b /a-d "%PROJECT_DIR%\*.pyo" 2^>nul') do (
    set "CAND=%%F"
    if "!CAND:%VENV_DIR%=!"=="!CAND!" (
        if exist "%%~F" (
            if "%FLAG_DRY_RUN%"=="0" del /f /q "%%~F" 2>nul
            echo   Removed: %%~F
        )
    )
)

REM Known cache / build directories at project root
for %%N in (
    .pytest_cache .mypy_cache .ruff_cache .ipynb_checkpoints
    htmlcov .tox .nox .eggs build dist
) do (
    if exist "%PROJECT_DIR%\%%N" (
        if "%FLAG_DRY_RUN%"=="0" rd /s /q "%PROJECT_DIR%\%%N" 2>nul
        echo   Removed: %PROJECT_DIR%\%%N
    )
)
if exist "%PROJECT_DIR%\.coverage" (
    if "%FLAG_DRY_RUN%"=="0" del /f /q "%PROJECT_DIR%\.coverage" 2>nul
    echo   Removed: %PROJECT_DIR%\.coverage
)

echo   Done.
echo.
:skip_cache

:: ============================================================
::  STEP 3/4 - Build environment + install dependencies
:: ============================================================
echo [3/4] Building environment and installing dependencies...
call :log "Step 3: build env + install deps"

REM Locate Python interpreter
REM Prefer the Python launcher (py.exe) - it reliably finds a real interpreter
REM and avoids the Windows Store stub at ...\WindowsApps\python.exe.
REM Note: we use just "py" (not "py -3") because the space in "py -3" breaks
REM parsing inside for /f command substitution.
set "SYS_PYTHON="
where py >nul 2>&1 && set "SYS_PYTHON=py"
if not defined SYS_PYTHON (
    where python >nul 2>&1 && set "SYS_PYTHON=python"
)
if not defined SYS_PYTHON (
    echo   [ERROR] Python not found in PATH. Install Python %MIN_PY_MAJOR%.%MIN_PY_MINOR%+ and retry.
    call :log "ERROR: python not found in PATH"
    exit /b 1
)

REM Verify Python version >= MIN_PY_MAJOR.MIN_PY_MINOR
REM Use a temp file to capture Python output - more reliable than for /f backticks
set "PY_MAJOR=" & set "PY_MINOR="
set "_PYVER_FILE=%TEMP%\nemo_pyver_%RANDOM%.tmp"
%SYS_PYTHON% -c "import sys;print(sys.version_info.major,sys.version_info.minor)" > "%_PYVER_FILE%" 2>nul
for /f "tokens=1,2" %%A in ('type "%_PYVER_FILE%" 2^>nul') do (
    set "PY_MAJOR=%%A"
    set "PY_MINOR=%%B"
)
del /f /q "%_PYVER_FILE%" >nul 2>&1
if not defined PY_MAJOR (
    echo   [ERROR] Cannot determine Python version via: %SYS_PYTHON%
    exit /b 1
)
if %PY_MAJOR% LSS %MIN_PY_MAJOR% goto py_too_old
if %PY_MAJOR% EQU %MIN_PY_MAJOR% if %PY_MINOR% LSS %MIN_PY_MINOR% goto py_too_old
echo   Python %PY_MAJOR%.%PY_MINOR% detected.
goto py_ok
:py_too_old
echo   [ERROR] Python %PY_MAJOR%.%PY_MINOR% is too old. Need %MIN_PY_MAJOR%.%MIN_PY_MINOR%+.
call :log "ERROR: python %PY_MAJOR%.%PY_MINOR% too old"
exit /b 1
:py_ok

REM Optionally rebuild venv from scratch
if "%FLAG_REBUILD%"=="1" (
    if exist "%VENV_DIR%" (
        echo   Removing existing venv ^(--rebuild^)
        if "%FLAG_DRY_RUN%"=="0" rd /s /q "%VENV_DIR%" 2>nul
    )
)

REM Create venv if missing
if not exist "%PYTHON_EXE%" (
    echo   Creating virtual environment: %VENV_DIR%
    if "%FLAG_DRY_RUN%"=="0" (
        %SYS_PYTHON% -m venv "%VENV_DIR%"
        if !ERRORLEVEL! NEQ 0 (
            echo   [ERROR] Failed to create venv.
            call :log "ERROR: venv creation failed"
            exit /b 1
        )
    )
) else (
    echo   Virtual environment already exists.
)

REM Upgrade pip / setuptools / wheel
echo   Upgrading pip
if "%FLAG_DRY_RUN%"=="0" (
    "%PYTHON_EXE%" -m pip install --upgrade pip setuptools wheel -q
    if !ERRORLEVEL! NEQ 0 echo   [WARN] pip upgrade failed, continuing
)

REM Install requirements
if exist "%PROJECT_DIR%\%REQUIREMENTS%" (
    echo   Installing from %REQUIREMENTS%
    if "%FLAG_DRY_RUN%"=="0" (
        "%PIP_EXE%" install -r "%PROJECT_DIR%\%REQUIREMENTS%"
        if !ERRORLEVEL! NEQ 0 (
            echo   [ERROR] Dependency installation failed.
            call :log "ERROR: pip install failed"
            exit /b 1
        )
    )
) else (
    echo   [WARN] %REQUIREMENTS% not found - skipping install.
)

REM Bootstrap .env from .env.example if needed
if not exist "%PROJECT_DIR%\.env" (
    if exist "%PROJECT_DIR%\.env.example" (
        if "%FLAG_DRY_RUN%"=="0" copy /y "%PROJECT_DIR%\.env.example" "%PROJECT_DIR%\.env" >nul
        echo   Created .env from .env.example - fill in your API keys!
    ) else (
        echo   [WARN] No .env and no .env.example found.
    )
)

REM ----------------------------------------------------------
REM  Pre-start: verify ALL project modules import cleanly
REM  This proves config / memory / rag_agent / url_ingestor /
REM  tools / bot are all wired into the launch pipeline.
REM ----------------------------------------------------------
echo   Verifying project modules...
if "%FLAG_DRY_RUN%"=="0" (
    "%PYTHON_EXE%" -c "import config, memory, rag_agent, url_ingestor, tools; from config import RAGAgentConfig; from memory import UserMemory, should_remember; from rag_agent import RAGAgent; from url_ingestor import extract_urls, should_ingest_url; from tools import ALL_TOOLS; print('  [OK] config, memory, rag_agent, url_ingestor, tools')" 2>nul
    if !ERRORLEVEL! NEQ 0 (
        echo   [ERROR] Module import check failed. See traceback above.
        call :log "ERROR: module import check failed"
        exit /b 1
    )
) else (
    echo   [DRY-RUN] Would import: config, memory, rag_agent, url_ingestor, tools
)

echo   Done.
echo.

:: ============================================================
::  STEP 4/4 - Start project
:: ============================================================
echo [4/4] Starting nemo-bot-RAG...
echo ------------------------------------------------------------
call :log "Step 4: start project"

if not exist "%PROJECT_DIR%\%MAIN_MODULE%" (
    echo   [ERROR] %MAIN_MODULE% not found in %PROJECT_DIR%
    call :log "ERROR: %MAIN_MODULE% missing"
    exit /b 1
)

if "%FLAG_DRY_RUN%"=="1" (
    echo   [DRY-RUN] Would execute: "%PYTHON_EXE%" "%PROJECT_DIR%\%MAIN_MODULE%"
    echo.
    echo ============================================================
    exit /b 0
)

if "%FLAG_FOREGROUND%"=="1" (
    REM Explicit --foreground: just run it, user knows what they asked for
    "%PYTHON_EXE%" "%PROJECT_DIR%\%MAIN_MODULE%"
    set "EXIT_CODE=!ERRORLEVEL!"
) else (
    REM Default mode: also foreground. The bot is a long-running process that
    REM polls Telegram. Ctrl+C to stop it. For production use, run inside
    REM a Windows Service, Task Scheduler, or process manager (pm2, nssm).
    echo   Running in foreground. Press Ctrl+C to stop.
    echo.
    "%PYTHON_EXE%" "%PROJECT_DIR%\%MAIN_MODULE%"
    set "EXIT_CODE=!ERRORLEVEL!"
)

echo.
echo ------------------------------------------------------------
echo   Process finished with exit code: !EXIT_CODE!
echo ============================================================
call :log "Deploy finished with exit code !EXIT_CODE!"

endlocal & exit /b %EXIT_CODE%

:: ============================================================
::  Helper: kill a PID safely (force, with tree)
:: ============================================================
:kill_pid
set "_PID=%~1"
set "_WHY=%~2"
taskkill /PID !_PID! /F /T >nul 2>&1
if !ERRORLEVEL! EQU 0 (
    echo   Killed PID=!_PID! ^(!_WHY!^)
) else (
    echo   PID=!_PID! already stopped ^(!_WHY!^)
)
goto :eof

:: ============================================================
::  Helper: append a timestamped line to deploy.log
:: ============================================================
:log
echo [%date% %time%] %~1 >> "%LOG_FILE%" 2>nul
goto :eof

