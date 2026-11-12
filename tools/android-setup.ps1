# Lite Go: gets everything needed to build the Android app, from the terminal
# only (no Android Studio). Run by build-android.bat when something is missing;
# safe to run again (it skips what is already there).
#
#   Java 17          winget (Eclipse Temurin)
#   Android SDK      Google's command-line tools, into %LOCALAPPDATA%\Android\Sdk
#     platform-tools, an SDK platform, build-tools and the NDK, with sdkmanager
#
# About 2.5 GB of disk, most of it the NDK (the C toolchain Go uses for Android).
#
# -EnvFile writes "set" lines for the calling .bat (JAVA_HOME, ANDROID_HOME).

param([string]$EnvFile = '')

# 'Continue': the Android tools write warnings to stderr, which Windows
# PowerShell would otherwise treat as errors; failures are checked below.
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue' # downloads are much faster without the progress bar

function Say($s) { Write-Host "  $s" }

# ---- Java 17 ----
function Find-Jdk {
	if ($env:JAVA_HOME -and (Test-Path "$env:JAVA_HOME\bin\javac.exe")) { return $env:JAVA_HOME }
	$c = Get-Command javac -ErrorAction SilentlyContinue
	if ($c) { return (Split-Path (Split-Path $c.Source)) }
	foreach ($root in @("$env:ProgramFiles\Eclipse Adoptium", "$env:ProgramFiles\Microsoft", "$env:ProgramFiles\Java")) {
		if (Test-Path $root) {
			$d = Get-ChildItem $root -Directory | Where-Object { Test-Path "$($_.FullName)\bin\javac.exe" } | Sort-Object Name -Descending | Select-Object -First 1
			if ($d) { return $d.FullName }
		}
	}
	return $null
}

$jdk = Find-Jdk
if (-not $jdk) {
	Say 'Installing Java 17 (Eclipse Temurin) with winget...'
	winget install -e --id EclipseAdoptium.Temurin.17.JDK --accept-source-agreements --accept-package-agreements | Out-Null
	$jdk = Find-Jdk
	if (-not $jdk) { throw 'Java did not install. Install a JDK 17 and run this again.' }
}
$env:JAVA_HOME = $jdk
$env:Path = "$jdk\bin;$env:Path"
Say "Java: $jdk"

# ---- Android SDK command-line tools ----
$sdk = $env:ANDROID_HOME
if (-not $sdk) { $sdk = $env:ANDROID_SDK_ROOT }
if (-not $sdk) { $sdk = "$env:LOCALAPPDATA\Android\Sdk" }
New-Item -ItemType Directory -Force $sdk | Out-Null
$sdkm = "$sdk\cmdline-tools\latest\bin\sdkmanager.bat"

if (-not (Test-Path $sdkm)) {
	Say 'Downloading Google''s Android command-line tools...'
	# the newest version, from Google's own list of SDK packages
	$name = $null
	try {
		$xml = (Invoke-WebRequest -UseBasicParsing 'https://dl.google.com/android/repository/repository2-3.xml').Content
		$name = [regex]::Matches($xml, 'commandlinetools-win-(\d+)_latest\.zip') |
			Sort-Object { [int64]$_.Groups[1].Value } -Descending | Select-Object -First 1 | ForEach-Object { $_.Value }
	} catch {}
	if (-not $name) { $name = 'commandlinetools-win-11076708_latest.zip' }
	$zip = Join-Path $env:TEMP $name
	Invoke-WebRequest -UseBasicParsing "https://dl.google.com/android/repository/$name" -OutFile $zip
	if (-not (Test-Path $zip)) { throw 'Could not download the Android command-line tools.' }
	$tmp = Join-Path $env:TEMP 'litego-cmdline-tools'
	if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
	Expand-Archive $zip $tmp -ErrorAction Stop
	New-Item -ItemType Directory -Force "$sdk\cmdline-tools" | Out-Null
	if (Test-Path "$sdk\cmdline-tools\latest") { Remove-Item -Recurse -Force "$sdk\cmdline-tools\latest" }
	Move-Item "$tmp\cmdline-tools" "$sdk\cmdline-tools\latest"
	Remove-Item -Force $zip
	Remove-Item -Recurse -Force $tmp
}
Say "Android SDK: $sdk"

# ---- the packages: newest platform, build-tools and NDK ----
function VersionOf($pkg) {
	$v = ($pkg -replace '^[^;]+;', '') -replace '^android-', ''
	try { return [version]($v + $(if ($v -notmatch '\.') { '.0' } else { '' })) } catch { return [version]'0.0' }
}

function Newest($list, $prefix) {
	$list | ForEach-Object { if ($_ -match "^\s*($([regex]::Escape($prefix))[^\s|]+)") { $Matches[1] } } |
		Where-Object { $_ -notmatch '(rc|alpha|beta|preview|-ext)' } |
		Sort-Object { VersionOf $_ } -Descending -Unique |
		Select-Object -First 1
}

$want = @()
if (-not (Test-Path "$sdk\platform-tools\adb.exe")) { $want += 'platform-tools' }
$haveBT = (Test-Path "$sdk\build-tools") -and (Get-ChildItem "$sdk\build-tools" -Directory -ErrorAction SilentlyContinue)
$havePF = (Test-Path "$sdk\platforms") -and (Get-ChildItem "$sdk\platforms" -Directory -ErrorAction SilentlyContinue)
$haveNDK = (Test-Path "$sdk\ndk") -and (Get-ChildItem "$sdk\ndk" -Directory -ErrorAction SilentlyContinue)
if (-not ($haveBT -and $havePF -and $haveNDK)) {
	Say 'Looking up the newest Android packages...'
	$list = & $sdkm --sdk_root="$sdk" --list 2>$null
	if (-not $havePF) {
		$p = Newest $list 'platforms;android-'
		if (-not $p) { $p = 'platforms;android-35' }
		$want += $p
	}
	if (-not $haveBT) {
		$b = Newest $list 'build-tools;'
		if (-not $b) { $b = 'build-tools;35.0.0' }
		$want += $b
	}
	if (-not $haveNDK) {
		$n = Newest $list 'ndk;'
		if (-not $n) { $n = 'ndk;27.2.12479018' }
		$want += $n
	}
}

if ($want.Count -gt 0) {
	Say 'Accepting the Android SDK licenses...'
	('y' + [Environment]::NewLine) * 30 | & $sdkm --sdk_root="$sdk" --licenses | Out-Null
	foreach ($p in $want) {
		Say "Installing $p (this can take a while)..."
		& $sdkm --sdk_root="$sdk" --install $p | Out-Null
		if ($LASTEXITCODE -ne 0) { throw "sdkmanager could not install $p" }
	}
}

# remember where things are, for new terminals too
[Environment]::SetEnvironmentVariable('ANDROID_HOME', $sdk, 'User')
[Environment]::SetEnvironmentVariable('JAVA_HOME', $jdk, 'User')
if ($EnvFile) {
	"@set ""JAVA_HOME=$jdk""`r`n@set ""ANDROID_HOME=$sdk""`r`n" | Set-Content -Encoding ASCII $EnvFile
}
Say 'Ready to build Lite Go for Android.'
