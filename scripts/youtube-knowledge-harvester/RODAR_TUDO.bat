@echo off
chcp 65001 >nul
set PYTHONUTF8=1
set PYTHONIOENCODING=utf-8
cd /d "%~dp0"
where py >nul 2>nul && (set PY=py -3) || (set PY=python)
%PY% --version >nul 2>nul || (
  echo Python nao encontrado. Instale em https://www.python.org/downloads/ marcando "Add Python to PATH" e clique de novo.
  pause & exit /b 1
)
%PY% bootstrap.py
echo.
pause
