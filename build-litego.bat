@echo off
rem Lite Go build for Windows. Double-click it.
rem Makes dist\Lite Go Setup.exe (the installer) and dist\Lite Go\Lite Go.exe (portable).
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

rem keep the build small in memory (under 2 GB)
set GOGC=50
set GOMAXPROCS=2
set GOFLAGS=-mod=mod
set CGO_ENABLED=0
set GOOS=windows
if "%GOARCH%"=="" set GOARCH=amd64

echo Running the tests...
go test ./core ./shell ./setup ./shields || ( echo Tests failed. & pause & exit /b 1 )

echo Building Lite Go...
if not exist "dist\Lite Go" mkdir "dist\Lite Go"
go build -trimpath -ldflags "-H windowsgui -s -w" -o "dist\Lite Go\Lite Go.exe" .\cmd\litego || ( echo Build failed. & pause & exit /b 1 )
go run tools\sum.go "dist\Lite Go\Lite Go.exe" || ( pause & exit /b 1 )
copy /y LICENSE.md "dist\Lite Go\" >nul
copy /y NOTICE "dist\Lite Go\" >nul
copy /y THIRD_PARTY_NOTICES.md "dist\Lite Go\" >nul

echo Packing the setup...
go run tools\gz.go "dist\Lite Go\Lite Go.exe" setup\payload\LiteGo.exe.gz || ( pause & exit /b 1 )
copy /y LICENSE.md setup\payload\ >nul
copy /y NOTICE setup\payload\ >nul
copy /y THIRD_PARTY_NOTICES.md setup\payload\ >nul
go build -trimpath -ldflags "-H windowsgui -s -w" -o "dist\Lite Go Setup.exe" .\cmd\litego-setup || ( echo Setup build failed. & pause & exit /b 1 )
powershell -NoProfile -Command "Compress-Archive -Force -Path 'dist\Lite Go' -DestinationPath 'dist\LiteGo-portable.zip'"

echo Packing for the Microsoft Store (MSIX for x64 and ARM64, and a bundle of both)...
go run tools\msix.go -exe "dist\Lite Go\Lite Go.exe" -arch x64 -out dist\LiteGo_x64.msix || ( pause & exit /b 1 )
set GOARCH=arm64
go build -trimpath -ldflags "-H windowsgui -s -w" -o dist\LiteGo-arm64.exe .\cmd\litego || ( pause & exit /b 1 )
set GOARCH=
go run tools\msix.go -exe dist\LiteGo-arm64.exe -arch arm64 -out dist\LiteGo_arm64.msix || ( pause & exit /b 1 )
go run tools\msix.go -bundle dist\LiteGo.msixbundle dist\LiteGo_x64.msix dist\LiteGo_arm64.msix || ( pause & exit /b 1 )
del dist\LiteGo-arm64.exe

echo.
echo Done:
echo   dist\Lite Go Setup.exe      the installer
echo   dist\Lite Go\Lite Go.exe    portable (needs the WebView2 runtime, which Windows 10 and 11 have)
echo   dist\LiteGo.msixbundle      for the Microsoft Store (x64 and ARM64; the Store signs it)
pause
