@echo off
rem Iris build for Windows. Double-click it.
rem Makes dist\Iris Setup.exe (the installer) and dist\Iris\Iris.exe (portable).
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

echo Building Iris...
if not exist "dist\Iris" mkdir "dist\Iris"
go build -trimpath -ldflags "-H windowsgui -s -w" -o "dist\Iris\Iris.exe" .\cmd\iris || ( echo Build failed. & pause & exit /b 1 )
go run tools\sum.go "dist\Iris\Iris.exe" || ( pause & exit /b 1 )
copy /y LICENSE "dist\Iris\" >nul
copy /y NOTICE "dist\Iris\" >nul
copy /y THIRD_PARTY_NOTICES.md "dist\Iris\" >nul

echo Packing the setup...
go run tools\gz.go "dist\Iris\Iris.exe" setup\payload\Iris.exe.gz || ( pause & exit /b 1 )
copy /y LICENSE setup\payload\ >nul
copy /y NOTICE setup\payload\ >nul
copy /y THIRD_PARTY_NOTICES.md setup\payload\ >nul
go build -trimpath -ldflags "-H windowsgui -s -w" -o "dist\Iris Setup.exe" .\cmd\iris-setup || ( echo Setup build failed. & pause & exit /b 1 )
powershell -NoProfile -Command "Compress-Archive -Force -Path 'dist\Iris' -DestinationPath 'dist\Iris-portable.zip'"

echo Packing for the Microsoft Store (MSIX for x64 and ARM64, and a bundle of both)...
go run tools\msix.go -exe "dist\Iris\Iris.exe" -arch x64 -out dist\Iris_x64.msix || ( pause & exit /b 1 )
set GOARCH=arm64
go build -trimpath -ldflags "-H windowsgui -s -w" -o dist\Iris-arm64.exe .\cmd\iris || ( pause & exit /b 1 )
set GOARCH=
go run tools\msix.go -exe dist\Iris-arm64.exe -arch arm64 -out dist\Iris_arm64.msix || ( pause & exit /b 1 )
go run tools\msix.go -bundle dist\Iris.msixbundle dist\Iris_x64.msix dist\Iris_arm64.msix || ( pause & exit /b 1 )
del dist\Iris-arm64.exe

echo.
echo Done:
echo   dist\Iris Setup.exe      the installer
echo   dist\Iris\Iris.exe    portable (needs the WebView2 runtime, which Windows 10 and 11 have)
echo   dist\Iris.msixbundle      for the Microsoft Store (x64 and ARM64; the Store signs it)
pause
