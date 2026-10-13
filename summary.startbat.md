# `start.bat` — шаблон оркестрации деплоя для Windows-проектов

Универсальный CMD-скрипт, который берёт на себя полный цикл запуска проекта:
**старые процессы → очистка кэша → сборка окружения → старт**.

Файл рассчитан на Python-проекты (venv + pip + requirements), но фазы 1, 2 и 4
переносятся на любой стек.

---

## 1. Архитектура: 4 фазы

```
┌─────────────────────────────────────────────────────────────┐
│  [1/4] STOP   — убить старые процессы (PID-файл + wmic)    │
│  [2/4] CLEAN  — удалить только известные cache-артефакты    │
│  [3/4] BUILD  — venv + pip install -r requirements.txt      │
│  [4/4] START  — запуск main-модуля                          │
└─────────────────────────────────────────────────────────────┘
```

Каждая фаза логируется в `deploy.log` через хелпер `:log`.

---

## 2. Полный шаблон

Сохраните как `start.bat` в корне проекта (UTF-8, без BOM):

```bat
@echo off & setlocal EnableExtensions EnableDelayedExpansion

:: ============================================================
::  <Project Name> - start.bat
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
::  Configuration  ←←← АДАПТИРУЙТЕ ПОД ПРОЕКТ ←←←
:: ----------------------------------------------------------
set "VENV_DIR=%PROJECT_DIR%\.venv"
set "PYTHON_EXE=%VENV_DIR%\Scripts\python.exe"
set "PIP_EXE=%VENV_DIR%\Scripts\pip.exe"
set "ACTIVATE=%VENV_DIR%\Scripts\activate.bat"
set "MAIN_MODULE=main.py"            REM ← имя точки входа
set "REQUIREMENTS=requirements.txt"  REM ← имя файла зависимостей
set "PID_FILE=%PROJECT_DIR%\.app.pid"
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
echo   <Project Name> - Deploy ^& Start
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

REM ←←← АДАПТИРУЙТЕ: имя процесса и имя main-модуля
for /f "tokens=2 delims=," %%P in (
    ''wmic process where "Name=''python.exe'' and CommandLine like ''%%main.py%%''" get ProcessId /format:csv 2^>nul''
) do (
    set "LPID=%%P"
    if defined LPID (
        set "_PIDCHK=!LPID!"
        echo !_PIDCHK!| findstr /r "^[0-9][0-9]*$" >nul 2>&1
        if !ERRORLEVEL! EQU 0 call :kill_pid "!LPID!" "matched main.py"
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
for /f "delims=" %%D in (''dir /s /b /ad "%PROJECT_DIR%\__pycache__" 2^>nul'') do (
    if /i "%%~nxD"=="__pycache__" (
        if exist "%%~D" (
            if "%FLAG_DRY_RUN%"=="0" rd /s /q "%%~D" 2>nul
            echo   Removed: %%~D
        )
    )
)

REM .pyc files
for /f "delims=" %%F in (''dir /s /b /a-d "%PROJECT_DIR%\*.pyc" 2^>nul'') do (
    if exist "%%~F" (
        if "%FLAG_DRY_RUN%"=="0" del /f /q "%%~F" 2>nul
        echo   Removed: %%~F
    )
)

REM .pyo files
for /f "delims=" %%F in (''dir /s /b /a-d "%PROJECT_DIR%\*.pyo" 2^>nul'') do (
    if exist "%%~F" (
        if "%FLAG_DRY_RUN%"=="0" del /f /q "%%~F" 2>nul
        echo   Removed: %%~F
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

REM Verify Python version >= MIN_PY_MAJOR.MIN_PY_MINOR
set "PY_MAJOR=" & set "PY_MINOR="
for /f "tokens=1,2" %%A in (''%SYS_PYTHON% -c "import sys;print(sys.version_info.major,sys.version_info.minor)" 2^>nul'') do (
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

REM Optionally rebuild venv from scratch
if "%FLAG_REBUILD%"=="1" (
    if exist "%VENV_DIR%" (
        echo   Removing existing venv (--rebuild)
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

echo   Done.
echo.

:: ============================================================
::  STEP 4/4 - Start project
:: ============================================================
echo [4/4] Starting <Project Name>...
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

---

## 3. Чек-лист адаптации под новый проект

Скопируйте шаблон и измените **только эти места**:

| # | Что | Где | Пример |
|---|-----|-----|--------|
| 1 | Имя проекта в баннере | строка `echo   <Project Name>` | `echo   My Bot - Deploy` |
| 2 | `MAIN_MODULE` | блок Configuration | `set "MAIN_MODULE=bot.py"` |
| 3 | `REQUIREMENTS` | блок Configuration | `set "REQUIREMENTS=pyproject.toml"` |
| 4 | `MIN_PY_MAJOR` / `MIN_PY_MINOR` | блок Configuration | `3` / `11` |
| 5 | Имя процесса в `wmic` | STEP 1 | `Name=''python.exe'' and CommandLine like ''%%bot.py%%''` |
| 6 | Имя в `:kill_pid` сообщении | STEP 1 | `"matched bot.py"` |
| 7 | Список cache-каталогов | STEP 2 | добавьте специфичные: `.next`, `.parcel-cache`, `node_modules\.cache` |
| 8 | Команда запуска | STEP 4 | `"%PYTHON_EXE%" -m uvicorn app:app` вместо `"%PYTHON_EXE%" "%MAIN_MODULE%"` |
| 9 | Имя PID-файла | блок Configuration | `set "PID_FILE=%PROJECT_DIR%\.bot.pid"` |

**Не трогайте** хелперы `:kill_pid` и `:log` — они универсальны.

---

## 4. CLI-флаги

| Флаг | Поведение |
|------|-----------|
| `--no-cache` | Пропускает STEP 2 целиком |
| `--rebuild` | Удаляет `.venv` перед STEP 3, затем создаёт заново |
| `--dry-run` | Все деструктивные операции (`rd`, `del`, `pip install`) пропускаются, только печать |
| `-h` / `--help` | Показывает справку и выходит |

Все флаги комбинируются: `start.bat --no-cache --dry-run`.

---

## 5. Типичные грабли CMD (must-know)

Эти ошибки ломают скрипт **молча** или с непонятными сообщениями. Запомните:

### 5.1. `echo.` внутри `if (...) (...)` блока

```bat
if "%X%"=="1" (
    echo.                  REM ← ПАРСЕР ЛОМАЕТСЯ: ". was unexpected at this time"
    goto somewhere
)
```

**Решение**: используйте `echo(` (со скобкой) или вынесите `echo` за скобки.

### 5.2. Многоточия `...` внутри `if (...)` блока

```bat
if "%X%"=="1" (
    echo Loading...        REM ← "... was unexpected at this time"
)
```

**Решение**: убирайте `...` из echo внутри блоков или экранируйте как `Loading^...`.

### 5.3. Парсинг версии Python

```bat
REM НЕПРАВИЛЬНО — Python выводит "3 12" через пробел, не через точку:
for /f "tokens=1,2 delims=." %%A in (''python -c "print(1,2)"'') do ...

REM ПРАВИЛЬНО — дефолтный разделитель for /f это пробел+таб:
for /f "tokens=1,2" %%A in (''python -c "print(1,2)"'') do ...
```

### 5.4. Редирект `2>nul` внутри `for /f`

```bat
REM В bat-файле `>` нужно экранировать как `^>`:
for /f "delims=" %%D in (''dir /s /b 2^>nul'') do ...
```

### 5.5. `goto` внутри `if (...) (...)` блока

```bat
if "%X%"=="1" (
    goto somewhere        REM ← иногда работает, но хрупко
)

REM НАДЁЖНЕЕ — вынести if в однострочную форму:
if "%X%"=="1" goto somewhere
```

### 5.6. Переменные в `for /f` без delayed expansion

```bat
setlocal EnableDelayedExpansion   REM ← обязательно в начале скрипта
for /f ... %%A in (...) do (
    set "X=%%A"
    echo !X!                    REM ← НЕ %X%, а !X!
)
```

### 5.7. `wmic` устарел (Windows 11 24H2+)

Если `wmic` недоступен, замените STEP 1 на PowerShell:

```bat
for /f "delims=" %%P in (''powershell -NoProfile -Command ^
    "Get-CimInstance Win32_Process -Filter \"Name=''python.exe''\" ^| ^
     Where-Object { $_.CommandLine -like ''*main.py*'' } ^| ^
     Select-Object -ExpandProperty ProcessId" 2^>nul'') do (
    call :kill_pid "%%P" "matched main.py"
)
```

### 5.8. Кириллица в выводе

```bat
chcp 65001 >nul 2>&1          REM ← UTF-8 консоль
REM Файл сохранять в UTF-8 БЕЗ BOM (PowerShell `Set-Content -Encoding UTF8` добавляет BOM — используйте `-Encoding UTF8` с осторожностью или конвертируйте).
```

---

## 6. Расширения (когда понадобится)

### 6.1. Запуск в фоне (для ботов / серверов)

Замените последний блок STEP 4:

```bat
if "%FLAG_DRY_RUN%"=="1" (
    echo   [DRY-RUN] Would start in background
    exit /b 0
)

start "" /B "%PYTHON_EXE%" "%PROJECT_DIR%\%MAIN_MODULE%"
timeout /t 2 /nobreak >nul
for /f "tokens=2" %%P in (''tasklist /fi "imagename eq python.exe" /fo csv ^| findstr /i "%MAIN_MODULE%"'') do (
    echo !PID_FILE_CONTENT!>nul
    echo %%P > "%PID_FILE%"
    echo   Started PID=%%P, PID file: %PID_FILE%
)
exit /b 0
```

### 6.2. Pre-start hook (миграции БД, прогрев кэша)

Добавьте перед STEP 4:

```bat
if exist "%PROJECT_DIR%\scripts\pre_start.py" (
    echo   Running pre-start hook...
    "%PYTHON_EXE%" "%PROJECT_DIR%\scripts\pre_start.py"
    if !ERRORLEVEL! NEQ 0 (
        echo   [ERROR] pre-start hook failed
        exit /b 1
    )
)
```

### 6.3. Post-start healthcheck

```bat
"%PYTHON_EXE%" "%PROJECT_DIR%\%MAIN_MODULE%" &
set "APP_PID=!ERRORLEVEL!"
timeout /t 5 /nobreak >nul
curl -fsS http://localhost:8000/health >nul 2>&1 && echo   Healthcheck OK || echo   [WARN] Healthcheck failed
```

---

## 7. Тестирование

Перед коммитом проверьте все 4 режима:

```bat
start.bat --help
start.bat --dry-run
start.bat --no-cache --dry-run
start.bat --rebuild --dry-run
```

Все должны завершаться с `exit code 0` и не выполнять деструктивных действий.

Для отладки добавьте временные маркеры:

```bat
echo MARKER-A
:: ... подозрительный блок ...
echo MARKER-B
```

Если маркер B не печатается — ошибка парсинга **между** маркерами.

---

## 8. Структура файла (быстрая навигация)

```
строки   1- 30   : заголовок, chcp, PROJECT_DIR, safety guard
строки  31- 60   : Configuration (адаптируйте!)
строки  61- 90   : парсинг CLI-флагов, --help
строки  91-110   : баннер, :log
строки 111-130   : STEP 1/4 — stop processes
строки 131-180   : STEP 2/4 — clean cache
строки 181-260   : STEP 3/4 — venv + pip
строки 261-290   : STEP 4/4 — start
строки 291-end   : хелперы :kill_pid, :log
```

---

## 9. Минимальная версия (если полная — overkill)

Для совсем простых проектов достаточно 30 строк:

```bat
@echo off & setlocal EnableExtensions EnableDelayedExpansion
chcp 65001 >nul 2>&1
set "PROJECT_DIR=%~dp0"
set "VENV_DIR=%PROJECT_DIR%\.venv"
set "PYTHON_EXE=%VENV_DIR%\Scripts\python.exe"

if not exist "%PYTHON_EXE%" (
    echo Creating venv...
    python -m venv "%VENV_DIR%" || exit /b 1
)

echo Installing deps...
"%PYTHON_EXE%" -m pip install -q --upgrade pip || exit /b 1
"%PYTHON_EXE%" -m pip install -q -r "%PROJECT_DIR%\requirements.txt" || exit /b 1

echo Starting...
"%PYTHON_EXE%" "%PROJECT_DIR%\main.py"
exit /b %ERRORLEVEL%
```

---

## 10. Связанные файлы

- `bot.py` — точка входа проекта (задаётся через `MAIN_MODULE` в блоке Configuration).
- `.gitignore` — должен содержать `.venv/`, `__pycache__/`, `*.pyc`, `.nemo_bot.pid`, `deploy.log`.
- `requirements.txt` — единственный источник правды о зависимостях.
