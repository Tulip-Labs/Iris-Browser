@echo off
rem Iris build for Windows. Double-click it.
rem Makes dist\Iris.msixbundle (x64 and ARM64), the only Windows package:
rem the Microsoft Store signs it, and winget installs the same bundle.
rem The page engine (Electron) is staged next to the program; Servo's bridge,
rem when built (webview\servo\lib\irisservo.dll), needs a Windows C compiler
rem (MinGW) for the x64 build.
setlocal enabledelayedexpansion
cd /d "%~dp0"

where go >nul 2>nul
if errorlevel 1 (
  echo Go is not installed. Installing it with winget...
  winget install -e --id GoLang.Go --accept-source-agreements --accept-package-agreements
  if errorlevel 1 ( echo Could not install Go. Get it from https://go.dev/dl and run this again. & pause & exit /b 1 )
  set "PATH=%ProgramFiles%\Go\bin;%PATH%"
)
go version || ( echo Go did not start. Open a new window and run this again. & pause & exit /b 1 )

where node >nul 2>nul
if errorlevel 1 (
  echo Node.js is not installed. Installing it with winget (Electron comes from npm)...
  winget install -e --id OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements
  if errorlevel 1 ( echo Could not install Node.js. Get it from https://nodejs.org and run this again. & pause & exit /b 1 )
  set "PATH=%ProgramFiles%\nodejs;%PATH%"
)
where npm >nul 2>nul || ( echo npm did not start. Open a new window and run this again. & pause & exit /b 1 )

rem keep the build small in memory (under 2 GB)
set GOGC=50
set GOMAXPROCS=2
set GOFLAGS=-mod=mod
set CGO_ENABLED=0
set GOOS=windows
set GOARCH=amd64

echo Running the tests...
go test ./core ./shell ./setup ./shields || ( echo Tests failed. & pause & exit /b 1 )

echo Building Iris...
if not exist "dist\Iris" mkdir "dist\Iris"
call :stage_electron x64 dist\Iris || ( pause & exit /b 1 )

rem Servo for the light pages, when its bridge is built (webview\servo\lib)
set SERVO_TAGS=
set SERVO_EXTRA=
if exist "webview\servo\lib\irisservo.dll" (
  where x86_64-w64-mingw32-gcc >nul 2>nul
  if errorlevel 1 (
    echo Servo's bridge is built but no Windows C compiler was found.
    echo Install MinGW (for example MSYS2, then pacman -S mingw-w64-x86_64-gcc) and put it on PATH,
    echo or delete webview\servo\lib\irisservo.dll to build without Servo.
    pause & exit /b 1
  )
  set SERVO_TAGS=-tags servo
  set CGO_ENABLED=1
  set CC=x86_64-w64-mingw32-gcc
  copy /y "webview\servo\lib\irisservo.dll" "dist\Iris\" >nul
  set SERVO_EXTRA=-extra dist\Iris\irisservo.dll
  echo With Servo for light pages (x64)
)
go build %SERVO_TAGS% -trimpath -ldflags "-H windowsgui -s -w" -o "dist\Iris\Iris.exe" .\cmd\iris || ( echo Build failed. & pause & exit /b 1 )
go run tools\sum.go "dist\Iris\Iris.exe" || ( pause & exit /b 1 )
copy /y LICENSE "dist\Iris\" >nul
copy /y NOTICE "dist\Iris\" >nul
copy /y THIRD_PARTY_NOTICES.md "dist\Iris\" >nul

echo Packing for the Microsoft Store (MSIX for x64 and ARM64, and a bundle of both)...
go run tools\msix.go -exe "dist\Iris\Iris.exe" -arch x64 -extra dist\Iris\electron %SERVO_EXTRA% -out dist\Iris_x64.msix || ( pause & exit /b 1 )

rem ARM64: the same, Electron-only (Servo's bridge is built for x64; the
rem arm64 bridge is the same cargo xwin build for aarch64-pc-windows-msvc)
set CGO_ENABLED=0
set CC=
set GOARCH=arm64
if not exist "dist\Iris-arm64" mkdir "dist\Iris-arm64"
call :stage_electron arm64 dist\Iris-arm64 || ( pause & exit /b 1 )
go build -trimpath -ldflags "-H windowsgui -s -w" -o dist\Iris-arm64\Iris.exe .\cmd\iris || ( pause & exit /b 1 )
go run tools\sum.go "dist\Iris-arm64\Iris.exe" || ( pause & exit /b 1 )
copy /y LICENSE "dist\Iris-arm64\" >nul
copy /y NOTICE "dist\Iris-arm64\" >nul
copy /y THIRD_PARTY_NOTICES.md "dist\Iris-arm64\" >nul
go run tools\msix.go -exe dist\Iris-arm64\Iris.exe -arch arm64 -extra dist\Iris-arm64\electron -out dist\Iris_arm64.msix || ( pause & exit /b 1 )
go run tools\msix.go -bundle dist\Iris.msixbundle dist\Iris_x64.msix dist\Iris_arm64.msix || ( pause & exit /b 1 )

echo.
echo Done:
echo   dist\Iris.msixbundle      the only Windows package: for the Microsoft Store (x64 and ARM64; the Store signs it) and winget
pause
exit /b 0

rem stage_electron stages Electron's Windows build into %2\electron: the
rem binary (from npm, for %1: x64 or arm64) and Iris's helper as its app
rem (resources\app).
:stage_electron
setlocal
set "EARCH=%~1"
set "EDIR=%~2"
set "TMP=%TEMP%\iris-electron-%EARCH%"
if exist "%TMP%" rmdir /s /q "%TMP%"
mkdir "%TMP%"
copy /y "webview\electron\helper\package.json" "%TMP%\" >nul
copy /y "webview\electron\helper\main.js" "%TMP%\" >nul
copy /y "webview\electron\helper\preload.js" "%TMP%\" >nul
pushd "%TMP%"
set "npm_config_arch=%EARCH%"
call npm install --no-audit --no-fund --loglevel=error
if not exist "node_modules\electron\dist\electron.exe" (
  pushd "node_modules\electron"
  call node install.js
  popd
)
if not exist "node_modules\electron\dist\electron.exe" (
  echo Electron's Windows binary is missing.
  popd
  endlocal & exit /b 1
)
for /f "usebackq delims=" %%v in ("node_modules\electron\dist\version") do echo Electron %%v for Windows %EARCH%
popd
if exist "%EDIR%\electron" rmdir /s /q "%EDIR%\electron"
xcopy /e /i /q "%TMP%\node_modules\electron\dist" "%EDIR%\electron" >nul
del /q "%EDIR%\electron\resources\default_app.asar" 2>nul
mkdir "%EDIR%\electron\resources\app"
copy /y "webview\electron\helper\main.js" "%EDIR%\electron\resources\app\" >nul
copy /y "webview\electron\helper\preload.js" "%EDIR%\electron\resources\app\" >nul
copy /y "webview\electron\helper\package.json" "%EDIR%\electron\resources\app\" >nul
rmdir /s /q "%TMP%\node_modules\electron"
rmdir /s /q "%TMP%\node_modules\@electron"
rem the helper never runs these CLIs, and their shims point into the
rem Electron package just removed
rmdir /s /q "%TMP%\node_modules\.bin"
xcopy /e /i /q "%TMP%\node_modules" "%EDIR%\electron\resources\app\node_modules" >nul
copy /y "%EDIR%\electron\version" "%EDIR%\ELECTRON_VERSION" >nul
rem only the strings Iris's readers use (Chromium falls back to English)
powershell -NoProfile -Command "Get-ChildItem '%EDIR%\electron\locales' -Filter *.pak | Where-Object { $_.Name -notin 'en-US.pak','es.pak','es-419.pak' } | Remove-Item" 2>nul
rmdir /s /q "%TMP%"
endlocal & exit /b 0
