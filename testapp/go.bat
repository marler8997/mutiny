@echo off
rem set MONO_PATH=C:\Program Files (x86)\Steam\steamapps\common\REPO\MonoBleedingEdge\EmbedRuntime
rem set PATH=%MONO_PATH%;%PATH%

copy "C:\Program Files (x86)\Steam\steamapps\common\REPO\MonoBleedingEdge\EmbedRuntime\mono-2.0-bdwgc.dll" %~dp0

"C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /out:%~dp0SimpleWindow.exe /target:winexe /reference:System.Windows.Forms.dll %~dp0SimpleWindow.cs
@if %errorlevel% neq 0 exit /b %errorlevel%

%~dp0SimpleWindow.exe
