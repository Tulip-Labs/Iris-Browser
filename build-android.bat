@echo off
rem Lite Go for Android, built on Windows. Double-click it.
rem Makes dist\LiteGo.apk (install it on a phone) - with "aab" as the first
rem argument it also makes dist\LiteGo.aab (for the Play Store).
rem
rem Needs, once:
rem   - Go (installed for the Windows build)
rem   - Android Studio's SDK: in Android Studio, SDK Manager, install an
rem     "Android SDK Platform" (34 or newer), "Android SDK Build-Tools",
rem     "NDK (Side by side)" and "Android SDK Command-line Tools".
rem     Android Studio itself is only needed for that; Lite Go has no Android
rem     Studio project.
rem   - Java 17 (Android Studio brings one: its "jbr" folder).
setlocal enabledelayedexpansion
cd /d "%~dp0"

rem the Android SDK
if "%ANDROID_HOME%"=="" if not "%ANDROID_SDK_ROOT%"=="" set "ANDROID_HOME=%ANDROID_SDK_ROOT%"
if "%ANDROID_HOME%"=="" set "ANDROID_HOME=%LOCALAPPDATA%\Android\Sdk"
if not exist "%ANDROID_HOME%\platforms" ( echo The Android SDK is not in "%ANDROID_HOME%". Install it with Android Studio's SDK Manager, or set ANDROID_HOME. & pause & exit /b 1 )

rem the newest NDK
if "%ANDROID_NDK_HOME%"=="" for /f "delims=" %%d in ('dir /b /ad /on "%ANDROID_HOME%\ndk" 2^>nul') do set "ANDROID_NDK_HOME=%ANDROID_HOME%\ndk\%%d"
if "%ANDROID_NDK_HOME%"=="" ( echo The Android NDK is missing. In Android Studio: SDK Manager, SDK Tools, "NDK (Side by side)". & pause & exit /b 1 )

rem the newest platform (android.jar, to compile LiteWeb.java)
set PLATFORM=
for /f "delims=" %%p in ('dir /b /ad /on "%ANDROID_HOME%\platforms"') do set "PLATFORM=%ANDROID_HOME%\platforms\%%p"
if not exist "%PLATFORM%\android.jar" ( echo No Android SDK Platform is installed. & pause & exit /b 1 )

rem Java: Android Studio's own, if there is no other
where javac >nul 2>nul
if errorlevel 1 if exist "%ProgramFiles%\Android\Android Studio\jbr\bin\javac.exe" set "JAVA_HOME=%ProgramFiles%\Android\Android Studio\jbr"
if not "%JAVA_HOME%"=="" set "PATH=%JAVA_HOME%\bin;%PATH%"
where javac >nul 2>nul || ( echo Java is missing. Install Android Studio, or a JDK 17. & pause & exit /b 1 )

rem gogio: Gio's tool that turns a Go program into an Android app
where gogio >nul 2>nul
if errorlevel 1 (
  echo Installing gogio...
  go install gioui.org/cmd/gogio@latest || ( echo Could not install gogio. & pause & exit /b 1 )
  for /f "delims=" %%g in ('go env GOPATH') do set "PATH=%%g\bin;!PATH!"
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
