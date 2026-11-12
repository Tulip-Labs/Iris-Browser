@echo off
rem Lite Go for Android (the Go and Gio version), built on Windows from the terminal.
rem The main Android app is the Kotlin one: build-android.bat. Double-click it,
rem or run it in a terminal. No Android Studio needed.
rem Makes dist\LiteGo.apk (install it on a phone). "build-android.bat aab"
rem also makes dist\LiteGo.aab (for the Play Store); "all" builds for every
rem kind of processor (phones, old phones, emulators).
rem
rem The first run installs what is missing (about 2.5 GB, mostly the NDK):
rem Java 17 with winget, then Google's Android command-line tools, an SDK
rem platform, build-tools and the NDK with sdkmanager (tools\android-setup.ps1),
rem then gogio with go install.
setlocal enabledelayedexpansion
cd /d "%~dp0"

where go >nul 2>nul
if errorlevel 1 (
  echo Go is not installed. Installing it with winget...
  winget install -e --id GoLang.Go --accept-source-agreements --accept-package-agreements
  if errorlevel 1 ( echo Could not install Go. Get it from https://go.dev/dl and run this again. & pause & exit /b 1 )
  set "PATH=%ProgramFiles%\Go\bin;!PATH!"
)

if "%ANDROID_HOME%"=="" if not "%ANDROID_SDK_ROOT%"=="" set "ANDROID_HOME=%ANDROID_SDK_ROOT%"
if "%ANDROID_HOME%"=="" set "ANDROID_HOME=%LOCALAPPDATA%\Android\Sdk"

rem anything missing? then get it
set NEED=
if not exist "%ANDROID_HOME%\platforms\*" set NEED=1
if not exist "%ANDROID_HOME%\build-tools\*" set NEED=1
if not exist "%ANDROID_HOME%\ndk\*" set NEED=1
if not exist "%ANDROID_HOME%\cmdline-tools\latest\bin\sdkmanager.bat" set NEED=1
where javac >nul 2>nul || if "%JAVA_HOME%"=="" set NEED=1
if defined NEED (
  echo Getting the Android build tools ^(first time only^)...
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\android-setup.ps1 -EnvFile "%TEMP%\litego-android-env.bat"
  if errorlevel 1 ( echo The setup did not finish. Run this again; it continues where it stopped. & pause & exit /b 1 )
  if exist "%TEMP%\litego-android-env.bat" call "%TEMP%\litego-android-env.bat"
)
if not "%JAVA_HOME%"=="" set "PATH=%JAVA_HOME%\bin;%PATH%"
where javac >nul 2>nul || ( echo Java was not found. Run tools\android-setup.ps1 again. & pause & exit /b 1 )

rem the newest NDK and platform
if "%ANDROID_NDK_HOME%"=="" for /f "delims=" %%d in ('dir /b /ad /on "%ANDROID_HOME%\ndk" 2^>nul') do set "ANDROID_NDK_HOME=%ANDROID_HOME%\ndk\%%d"
set PLATFORM=
for /f "delims=" %%p in ('dir /b /ad /on "%ANDROID_HOME%\platforms" 2^>nul') do set "PLATFORM=%ANDROID_HOME%\platforms\%%p"
if not exist "%PLATFORM%\android.jar" ( echo No Android SDK platform was found in "%ANDROID_HOME%". & pause & exit /b 1 )

rem gogio: Gio's tool that turns a Go program into an Android app
for /f "delims=" %%g in ('go env GOPATH') do set "PATH=%%g\bin;!PATH!"
where gogio >nul 2>nul
if errorlevel 1 (
  echo Installing gogio...
  go install gioui.org/cmd/gogio@latest || ( echo Could not install gogio. & pause & exit /b 1 )
)

rem keep the build small in memory (under 2 GB)
set GOGC=50
set GOMAXPROCS=2
set GOFLAGS=-mod=mod

echo Running the tests...
go test ./core ./shell ./shields || ( echo Tests failed. & pause & exit /b 1 )

echo Compiling the WebView bridge (LiteWeb.java)...
if exist build\android rmdir /s /q build\android
mkdir build\android\classes
javac --release 11 -nowarn -classpath "%PLATFORM%\android.jar" -d build\android\classes webview\android\LiteWeb.java || ( echo LiteWeb.java did not compile. & pause & exit /b 1 )
rem gogio packs every .jar it finds in the program's packages
jar cf webview\litego_android.jar -C build\android\classes . || ( echo Could not make the jar. & pause & exit /b 1 )

if not exist dist mkdir dist
rem arm64 is every phone from the last years; "all" adds 32-bit ARM and x86 (emulators)
set ARCH=arm64
if /i "%1"=="all" set ARCH=arm64,arm,amd64
if /i "%2"=="all" set ARCH=arm64,arm,amd64

echo Building Lite Go for Android (%ARCH%)...
gogio -target android -arch %ARCH% -minsdk 26 -targetsdk 35 -appid org.tulipanlabs.litego -version 1.0.0.1 -icon assets\icon.png -schemes https,http -o dist\LiteGo.apk .\cmd\litego || ( echo Build failed. & pause & exit /b 1 )

if /i "%1"=="aab" (
  echo Building the Play Store bundle...
  gogio -target android -arch arm64,arm -minsdk 26 -targetsdk 35 -appid org.tulipanlabs.litego -version 1.0.0.1 -icon assets\icon.png -schemes https,http -o dist\LiteGo.aab .\cmd\litego || ( echo The bundle failed. & pause & exit /b 1 )
)

echo.
echo Done: dist\LiteGo.apk
echo Install it: copy it to the phone and open it, or with the phone plugged in (USB debugging on):
echo   "%ANDROID_HOME%\platform-tools\adb" install -r dist\LiteGo.apk
echo It is signed with this PC's debug key: fine for testing. For the Play Store, sign with your own key (gogio -signkey).
pause
