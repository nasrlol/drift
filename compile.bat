@echo off
rem author: nasr
setlocal EnableDelayedExpansion

set MODE=debug
set FIRST=%~1
if not "%FIRST%"=="" if not "%FIRST:~0,1%"=="-" (
	set MODE=%FIRST%
	shift
)
set EXTRA=
:collect
if not "%~1"=="" (
	set EXTRA=!EXTRA! %1
	shift
	goto collect
)

set BUILD_DIR=build
set OFLAGS=-vet -vet-cast -strict-style -warnings-as-errors -error-pos-style:unix

if not exist %BUILD_DIR% mkdir %BUILD_DIR%
echo Build start %time%

if "%MODE%"=="debug" goto debug
if "%MODE%"=="profile" goto profile
if "%MODE%"=="release" goto release
echo usage: compile.bat [debug^|profile^|release] [extra odin flags]
exit /b 1

:debug
echo Building %BUILD_DIR%\drift.exe + %BUILD_DIR%\game.dll [debug, hot reload]
for /f "delims=" %%r in ('odin root') do set ODIN_DIR=%%r
copy /y "%ODIN_DIR%\vendor\raylib\windows\raylib.dll" %BUILD_DIR%\ >nul || exit /b 1
del /q %BUILD_DIR%\game_*.pdb 2>nul
odin build source\game %OFLAGS% -debug -o:none -use-separate-modules -build-mode:dll ^
	-define:RAYLIB_SHARED=true -define:DRIFT_DEBUG=true -pdb-name:%BUILD_DIR%\game_%RANDOM%.pdb ^
	-out:%BUILD_DIR%\game_tmp.dll %EXTRA% || exit /b 1
move /y %BUILD_DIR%\game_tmp.dll %BUILD_DIR%\game.dll >nul || exit /b 1
tasklist /fi "imagename eq drift.exe" | find /i "drift.exe" >nul
if not errorlevel 1 (
	echo drift.exe is running, only game.dll was rebuilt
	goto done
)
odin build source\host %OFLAGS% -debug -o:none -out:%BUILD_DIR%\drift.exe %EXTRA% || exit /b 1
goto done

:profile
echo Building %BUILD_DIR%\drift.exe [profile, single exe]
odin build source\release %OFLAGS% -debug -o:speed -define:DRIFT_PROFILE=true -out:%BUILD_DIR%\drift.exe %EXTRA% || exit /b 1
goto done

:release
echo Building %BUILD_DIR%\drift.exe [release, single exe]
odin build source\release %OFLAGS% -o:speed -disable-assert -subsystem:windows ^
	-out:%BUILD_DIR%\drift.exe %EXTRA% || exit /b 1
goto done

:done
echo ==== BUILD SUCCESS, end %time% ====
