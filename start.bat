@echo off & setlocal EnableExtensions EnableDelayedExpansion

:: ============================================================
::  RAG Agent - start.bat
::  Orchestration: stop -> cache clean -> venv + deps -> start
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
::  Configuration
:: ----------------------------------------------------------
set "VENV_DIR=%PROJECT_DIR%\.venv"
set "PYTHON_EXE=%VENV_DIR%\Scripts\python.exe"
set "PIP_EXE=%VENV_DIR%\Scripts\pip.exe"
set "ACTIVATE=%VENV_DIR%\Scripts\activate.bat"
set "MAIN_MODULE=rag_agent.py"
set "REQUIREMENTS=requirements.txt"
set "PID_FILE=%PROJECT_DIR%\.rag_agent.pid"
set "LOG_FILE=%PROJECT_DIR%\deploy.log"
set "MIN_PY_MAJOR=3"
set "MIN_PY_MINOR=10"

:: ----------------------------------------------------------
::  Parse CLI flags
:: ----------------------------------------------------------
set "FLAG_NO_CACHE=0"
set "FLAG_REBUILD=0"
set "FLAG_DRY_RUN=0"

:parse_args
if "%~1"=="" goto args_done
if /i "%~1"=="--no-cache" (set "FLAG_NO_CACHE=1" & shift & goto parse_args)
if /i "%~1"=="--rebuild"  (set "FLAG_REBUILD=1"  & shift & goto parse_args)
if /i "%~1"=="--dry-run"  (set "FLAG_DRY_RUN=1"  & shift & goto parse_args)
if /i "%~1"=="-h"         goto show_help
if /i "%~1"=="--help"     goto show_help
echo [WARN] Unknown flag ignored: %~1
shift
goto parse_args

:show_help
echo Usage: start.bat [--no-cache] [--rebuild] [--dry-run] [-h]
echo.
echo   --no-cache  Skip cache cleanup step
echo   --rebuild   Recreate virtual environment from scratch
echo   --dry-run   Print actions without executing destructive ones
echo   -h --help   Show this help message
exit /b 0

:args_done

:: ----------------------------------------------------------
::  Banner
:: ----------------------------------------------------------
echo.
echo ============================================================
echo   RAG Agent - Deploy ^& Start
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

for /f "tokens=2 delims=," %%P in (
    'wmic process where "Name='python.exe' and CommandLine like '%%rag_agent.py%%'" get ProcessId /format:csv 2^>nul'
) do (
    set "LPID=%%P"
    if defined LPID (
        set "_PIDCHK=!LPID!"
        echo !_PIDCHK!| findstr /r "^[0-9][0-9]*$" >nul 2>&1
        if !ERRORLEVEL! EQU 0 call :kill_pid "!LPID!" "matched rag_agent.py"
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

:: __pycache__ directories (only those whose basename is exactly __pycache__)
for /f "delims=" %%D in ('dir /s /b /ad "%PROJECT_DIR%\__pycache__" 2^>nul') do (
    if /i "%%~nxD"=="__pycache__" (
        if exist "%%~D" (
            if "%FLAG_DRY_RUN%"=="0" rd /s /q "%%~D" 2>nul
            echo   Removed: %%~D
        )
    )
)

:: .pyc files
for /f "delims=" %%F in ('dir /s /b /a-d "%PROJECT_DIR%\*.pyc" 2^>nul') do (
    if exist "%%~F" (
        if "%FLAG_DRY_RUN%"=="0" del /f /q "%%~F" 2>nul
        echo   Removed: %%~F
    )
)

:: .pyo files
for /f "delims=" %%F in ('dir /s /b /a-d "%PROJECT_DIR%\*.pyo" 2^>nul') do (
    if exist "%%~F" (
        if "%FLAG_DRY_RUN%"=="0" del /f /q "%%~F" 2>nul
        echo   Removed: %%~F
    )
)

:: Known cache / build directories at project root
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

:: Locate Python interpreter
set "SYS_PYTHON="
where python >nul 2>&1 && set "SYS_PYTHON=python"
if not defined SYS_PYTHON (
    where py >nul 2>&1 && set "SYS_PYTHON=py -3"
)
if not defined SYS_PYTHON (
    echo   [ERROR] Python not found in PATH. Install Python %MIN_PY_MAJOR%.%MIN_PY_MINOR%+ and retry.
    call :log "ERROR: python not found in PATH"
    exit /b 1
)

:: Verify Python version >= MIN_PY_MAJOR.MIN_PY_MINOR
set "PY_MAJOR=" & set "PY_MINOR="
for /f "tokens=1,2" %%A in ('%SYS_PYTHON% -c "import sys;print(sys.version_info.major,sys.version_info.minor)" 2^>nul') do (
    set "PY_MAJOR=%%A"
    set "PY_MINOR=%%B"
)
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

:: Optionally rebuild venv from scratch
if "%FLAG_REBUILD%"=="1" (
    if exist "%VENV_DIR%" (
        echo   Removing existing venv (--rebuild)
        if "%FLAG_DRY_RUN%"=="0" rd /s /q "%VENV_DIR%" 2>nul
    )
)

:: Create venv if missing
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

:: Upgrade pip / setuptools / wheel
echo   Upgrading pip...
if "%FLAG_DRY_RUN%"=="0" (
    "%PYTHON_EXE%" -m pip install --upgrade pip setuptools wheel -q
    if !ERRORLEVEL! NEQ 0 echo   [WARN] pip upgrade failed, continuing
)

:: Install requirements
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

:: Bootstrap .env from .env.example if needed
if not exist "%PROJECT_DIR%\.env" (
    if exist "%PROJECT_DIR%\.env.example" (
        if "%FLAG_DRY_RUN%"=="0" copy /y "%PROJECT_DIR%\.env.example" "%PROJECT_DIR%\.env" >nul
        echo   Created .env from .env.example - fill in your API keys!
    ) else (
        echo   [WARN] No .env and no .env.example found.
    )
)

echo   Done.
echo.

:: ============================================================
::  STEP 4/4 - Start project
:: ============================================================
echo [4/4] Starting RAG Agent...
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

"%PYTHON_EXE%" "%PROJECT_DIR%\%MAIN_MODULE%"
set "EXIT_CODE=!ERRORLEVEL!"

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