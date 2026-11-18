# Installs an MSIX on this PC for testing, signed with a certificate made here.
# Store builds do not need this: Microsoft signs what you upload to Partner Center.
# Run from the repository folder in an administrator PowerShell:
#   powershell -ExecutionPolicy Bypass -File packaging\test-install.ps1 dist\Iris_x64.msix
param([string]$Package = "dist\Iris_x64.msix")
$ErrorActionPreference = "Stop"
$publisher = (Get-Content packaging\msix.json | ConvertFrom-Json).publisher
$signtool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" -ErrorAction SilentlyContinue |
  Sort-Object FullName -Descending | Select-Object -First 1
if (-not $signtool) {
  Write-Host "Installing the Windows SDK signing tool with winget..."
  winget install -e --id Microsoft.WindowsSDK.10.0.26100 --accept-source-agreements --accept-package-agreements
  $signtool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" | Sort-Object FullName -Descending | Select-Object -First 1
}
$cert = New-SelfSignedCertificate -Type Custom -Subject $publisher -KeyUsage DigitalSignature -FriendlyName "Iris test" `
  -CertStoreLocation "Cert:\CurrentUser\My" -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3", "2.5.29.19={text}")
$pw = ConvertTo-SecureString -String "iris-test" -Force -AsPlainText
Export-PfxCertificate -Cert $cert -FilePath dist\Iris-test.pfx -Password $pw | Out-Null
Import-PfxCertificate -FilePath dist\Iris-test.pfx -CertStoreLocation Cert:\LocalMachine\TrustedPeople -Password $pw | Out-Null
& $signtool.FullName sign /fd SHA256 /f dist\Iris-test.pfx /p iris-test $Package
Add-AppxPackage $Package
Write-Host "Installed. Find Iris in the Start menu."
