@echo off
setlocal EnableDelayedExpansion
echo TEST1
for /f "delims=" %%D in (`dir /s /b /ad "d:\nemo-bot-RAG\__pycache__" 2^>nul`) do (echo FOUND:%%D)
echo TEST1 DONE
echo TEST2
for %%E in (.pyc .pyo) do (echo EXT=%%E)
echo TEST2 DONE
