# GPL-2.0-only. Release rehearsal image: console consumers (stages 1-2), then the
# runtime EDID/mouse driver and nvgop (stages 3-4), PCI decode restore, cold
# verification, then Windows. It never loads or runs the unlock application,
# never writes a GPU register and creates no boot entry.
param(
 [ValidateSet('asrock-b450m-rtx3060')][string]$HardwareProfile='asrock-b450m-rtx3060',
 [string]$Clang='clang',
 [string]$LldLink='lld-link',
 [string]$VcVars='C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/VC/Auxiliary/Build/vcvars64.bat',
 [switch]$Stage
)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$boot=Join-Path $repo 'internal-boot/boot'
$table=@{
 'asrock-b450m-rtx3060'=[ordered]@{Define='-DGU_PROFILE_ASROCK_B450M_RTX3060';Name='ASROCK-B450M-HDV-R4.0-P10.60-RTX3060';TargetPci='250410de'}
}
$hw=$table[$HardwareProfile]
Push-Location -LiteralPath $boot
try {
 if(!(Test-Path -LiteralPath 'platform-config.h')){throw 'Configure exact local partitions first'}
 if(!(Test-Path -LiteralPath 'generated.h')){throw 'Configure the local image contract first'}
 $lines=& cmd.exe /d /c "call `"$VcVars`" >nul && set"
 if($LASTEXITCODE -ne 0){throw 'MSVC environment failed'}
 foreach($line in $lines){if($line -match '^([^=]+)=(.*)$'){[Environment]::SetEnvironmentVariable($matches[1],$matches[2],'Process')}}
 $defines=@('-DGU_SINGLE_RTX_CONSOLE','-DGU_DIAGNOSTIC_ONLY','-DGU_CONSOLE_PREPARE','-DGU_CONSOLE_RELEASE_FULL',$hw.Define,"-DGU_TARGET_PCI_ID=0x$($hw.TargetPci)U")
 $includes=@('-I','compat','-I','../../deps/edk2/MdePkg/Include','-I','../../deps/edk2/MdePkg/Include/X64')
 $out='build/release-full'
 [void][IO.Directory]::CreateDirectory((Join-Path $boot $out))
 $sources=@('handoff.c','full-release.c','console-flow.c','research-input.c','diagnostic.c','../unlock/checks.c','../unlock/sha256.c','../efi_runtime.c')
 $objects=@()
 foreach($source in $sources){
  $obj="$out/"+[IO.Path]::GetFileNameWithoutExtension($source)+'.obj'
  & $Clang -target x86_64-pc-windows-msvc -std=c11 -ffreestanding -fno-builtin -fno-stack-protector -mno-red-zone -fshort-wchar -Os -Wall -Wextra -Werror @defines @includes -c $source -o $obj
  if($LASTEXITCODE -ne 0){throw "Compile failed: $source"};$objects+=$obj
 }
 $efi="$out/RELEASE-FULL.EFI"
 & $LldLink /nologo /nodefaultlib /subsystem:efi_application /entry:efi_main /machine:x64 /base:0 /dynamicbase /nxcompat /timestamp:0 /opt:ref /opt:icf "/map:$out/RELEASE-FULL.map" "/out:$efi" @objects
 if($LASTEXITCODE -ne 0){throw 'Release-full link failed'}
 & python ../unlock/verify_pe.py $efi "$out/RELEASE-FULL.map" --output "$out/pe-verification.json"
 if($LASTEXITCODE -ne 0){throw 'PE verification failed'}
 $hash=(Get-FileHash -LiteralPath $efi -Algorithm SHA256).Hash
 [ordered]@{Mode='single-rtx-full-release-rehearsal';HardwareProfile=$hw.Name;CanUnlock=$false;CanDetach=$true;
  CanDetachNvOwner=$true;CanDetachRuntimeEdid=$true;CanRemoveGop=$true;CanWriteGpu=$false;
  LogName='\RTX3090-UNLOCK\R2C##.TXT';EfiBytes=(Get-Item -LiteralPath $efi).Length;EfiSha256=$hash;HardwareTested=$false;BuiltUtc=[DateTime]::UtcNow.ToString('o')
 } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$out/manifest.json" -Encoding utf8
 if($Stage){
  $root='U:\EFI\WindowsGPUUnlock';[void][IO.Directory]::CreateDirectory($root)
  $target=Join-Path $root 'RELEASE-FULL.EFI'
  if(Test-Path -LiteralPath $target){if((Get-FileHash -LiteralPath $target).Hash -ne $hash){throw 'Different release-full image exists; refusing to overwrite'}}
  else{[IO.File]::Copy((Join-Path $boot $efi),$target,$false)}
  "Staged $target; no boot entry created."
 }
 "Built $efi sha256=$hash; hardware untested."
} finally {Pop-Location}
