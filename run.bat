@echo off
REM Launch the Agentic Level Editor (windowed). Pass --once to render+dump+quit.
setlocal
set HERE=%~dp0
"%HERE%engine\Godot_v4.7-stable_win64.exe" --path "%HERE%project" %*
