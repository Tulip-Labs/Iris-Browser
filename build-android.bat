@echo off
rem Lite for Android (Kotlin), built on Windows from the terminal. Double-click
rem it, or run it in a terminal. No Android Studio needed.
rem Makes dist\Lite.apk: copy it to the phone and open it, or install it with
rem   %LOCALAPPDATA%\Android\Sdk\platform-tools\adb install -r dist\Lite.apk
rem
rem The first run gets what is missing (about 600 MB): Java 17 with winget, and
rem Google's Android command-line tools with an SDK platform and build-tools
rem (tools\android-setup.ps1). Gradle then downloads itself and the Android
rem build plugin once (the android\gradlew wrapper).
setlocal enabledelayedexpansion
cd /d "%~dp0"

if "%ANDROID_HOME%"=="" if not "%ANDROID_SDK_ROOT%"=="" set "ANDROID_HOME=%ANDROID_SDK_ROOT%"
if "%ANDROID_HOME%"=="" set "ANDROID_HOME=%LOCALAPPDATA%\Android\Sdk"

set NEED=
if not exist "%ANDROID_HOME%\platforms\*" set NEED=1
if not exist "%ANDROID_HOME%\build-tools\*" set NEED=1
if not exist "%ANDROID_HOME%\cmdline-tools\latest\bin\sdkmanager.bat" set NEED=1
where javac >nul 2>nul || if "%JAVA_HOME%"=="" set NEED=1
if defined NEED (
  echo Getting the Android build tools ^(first time only^)...
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\android-setup.ps1 -NoNdk -EnvFile "%TEMP%\litego-android-env.bat"
  if errorlevel 1 ( echo The setup did not finish. Run this again; it continues where it stopped. & pause & exit /b 1 )
  if exist "%TEMP%\litego-android-env.bat" call "%TEMP%\litego-android-env.bat"
)
if "%JAVA_HOME%"=="" for /f "delims=" %%j in ('where javac 2^>nul') do if "!JAVA_HOME!"=="" for %%d in ("%%~dpj..") do set "JAVA_HOME=%%~fd"
if "%JAVA_HOME%"=="" ( echo Java was not found. Run tools\android-setup.ps1 again. & pause & exit /b 1 )

rem where the SDK is, for Gradle
set "SDKDIR=%ANDROID_HOME:\=/%"
> android\local.properties echo sdk.dir=%SDKDIR%

echo Building Lite for Android (the first time Gradle downloads itself, a few minutes)...
pushd android
call gradlew.bat --no-daemon assembleRelease
set ERR=%errorlevel%
popd
if not "%ERR%"=="0" ( echo Build failed. Send the messages above. & pause & exit /b 1 )

if not exist dist mkdir dist
copy /y android\app\build\outputs\apk\release\app-release.apk dist\Lite.apk >nul || ( echo The APK was not found. & pause & exit /b 1 )
echo.
echo Done: dist\Lite.apk
echo Install it: copy it to the phone and open it, or with the phone plugged in (USB debugging on):
echo   "%ANDROID_HOME%\platform-tools\adb" install -r dist\Lite.apk
pause
