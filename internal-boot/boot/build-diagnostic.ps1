param([string]$Clang='clang',[string]$LldLink='lld-link',[string]$Python='python',[ValidateSet('b650m-3090fe','b660m-3070ti','discovery')][string]$HardwareProfile='b650m-3090fe')
$ErrorActionPreference='Stop'
$profileDefine=$(switch($HardwareProfile){'discovery'{'-DGU_PROFILE_DISCOVERY'} 'b660m-3070ti'{'-DGU_PROFILE_B660M_3070TI'} default{'-DGU_PROFILE_B650M_3090FE'}})
Push-Location -LiteralPath $PSScriptRoot
try {
 New-Item -ItemType Directory -Path build/diagnostic -Force | Out-Null
 $sources=@('handoff.c','diagnostic.c','../efi_runtime.c','probe.c','../unlock/sha256.c')
 $objects=@()
 foreach($source in $sources) {
  $obj='build/diagnostic/'+[IO.Path]::GetFileNameWithoutExtension($source)+'.obj'
  & $Clang -target x86_64-pc-windows-msvc -std=c11 -ffreestanding -fno-builtin -fno-stack-protector -mno-red-zone -fshort-wchar -Os -Wall -Wextra -Werror -DGU_DIAGNOSTIC_ONLY -DGU_DIAGNOSTIC_PROBE $profileDefine -I ../../deps/edk2/MdePkg/Include -I ../../deps/edk2/MdePkg/Include/X64 -c $source -o $obj
  if($LASTEXITCODE -ne 0){throw "Compile failed: $source"}
  $objects+=$obj
 }
 & $LldLink /nologo /nodefaultlib /subsystem:efi_application /entry:efi_main /machine:x64 /base:0 /dynamicbase /nxcompat /timestamp:0 /opt:ref /opt:icf /map:build/diagnostic/DIAGNOSTIC.map /out:build/diagnostic/DIAGNOSTIC.EFI @objects
 if($LASTEXITCODE -ne 0){throw 'Diagnostic link failed'}
 & $Python ../unlock/verify_pe.py build/diagnostic/DIAGNOSTIC.EFI build/diagnostic/DIAGNOSTIC.map --output build/diagnostic/pe-verification.json
 if($LASTEXITCODE -ne 0){throw 'Diagnostic PE verification failed'}
 $sourceManifest=@(($sources+@('diagnostic.h','media.h','probe.h','../unlock/machine-profile.h')) | ForEach-Object {
  [ordered]@{Path=$_;Sha256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash}
 })
 [ordered]@{
  HardwareTested=$false;Mode='graph-capture-then-normal-windows';CanUnlock=$false
  HardwareProfile=$HardwareProfile;ProfileDefine=$profileDefine
  CanDetach=$false;WritesFirmwareVariables=$false
  EfiSha256=(Get-FileHash -LiteralPath build/diagnostic/DIAGNOSTIC.EFI -Algorithm SHA256).Hash
  BuiltUtc=[DateTime]::UtcNow.ToString('o');Sources=$sourceManifest
 } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath build/diagnostic/manifest.json -Encoding utf8
} finally {Pop-Location}
