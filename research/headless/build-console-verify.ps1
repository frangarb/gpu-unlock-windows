# GPL-2.0-only. Read-only console-chain verification image for one profile.
# No detach, no GPU writes, no boot entry: it verifies the display route, the
# two console consumers and the runtime EDID owner, then starts Windows.
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
 $defines=@('-DGU_SINGLE_RTX_CONSOLE','-DGU_DIAGNOSTIC_ONLY','-DGU_CONSOLE_PREPARE','-DGU_CONSOLE_VERIFY_ONLY',$hw.Define,"-DGU_TARGET_PCI_ID=0x$($hw.TargetPci)U")
 $includes=@('-I','compat','-I','../../deps/edk2/MdePkg/Include','-I','../../deps/edk2/MdePkg/Include/X64')
 $out='build/console-verify'
 [void][IO.Directory]::CreateDirectory((Join-Path $boot $out))
 $sources=@('handoff.c','prepare-console.c','console-flow.c','research-input.c','diagnostic.c','../efi_runtime.c')
 $objects=@()
 foreach($source in $sources){
  $obj="$out/"+[IO.Path]::GetFileNameWithoutExtension($source)+'.obj'
  & $Clang -target x86_64-pc-windows-msvc -std=c11 -ffreestanding -fno-builtin -fno-stack-protector -mno-red-zone -fshort-wchar -Os -Wall -Wextra -Werror @defines @includes -c $source -o $obj
  if($LASTEXITCODE -ne 0){throw "Compile failed: $source"};$objects+=$obj
 }
 $efi="$out/CONSOLE-VERIFY.EFI"
 & $LldLink /nologo /nodefaultlib /subsystem:efi_application /entry:efi_main /machine:x64 /base:0 /dynamicbase /nxcompat /timestamp:0 /opt:ref /opt:icf "/map:$out/CONSOLE-VERIFY.map" "/out:$efi" @objects
 if($LASTEXITCODE -ne 0){throw 'Console verify link failed'}
 & python ../unlock/verify_pe.py $efi "$out/CONSOLE-VERIFY.map" --output "$out/pe-verification.json"
 if($LASTEXITCODE -ne 0){throw 'PE verification failed'}
 $hash=(Get-FileHash -LiteralPath $efi -Algorithm SHA256).Hash
 [ordered]@{Mode='single-rtx-console-verify-only';HardwareProfile=$hw.Name;CanUnlock=$false;CanDetach=$false;CanWriteGpu=$false;
  LogName='\RTX3090-UNLOCK\CV00.TXT';EfiBytes=(Get-Item -LiteralPath $efi).Length;EfiSha256=$hash;HardwareTested=$false;BuiltUtc=[DateTime]::UtcNow.ToString('o')
 } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$out/manifest.json" -Encoding utf8
 if($Stage){
  $root='U:\EFI\WindowsGPUUnlock';[void][IO.Directory]::CreateDirectory($root)
  $target=Join-Path $root 'CONSOLE-VERIFY.EFI'
  if(Test-Path -LiteralPath $target){if((Get-FileHash -LiteralPath $target).Hash -ne $hash){throw 'Different console verify image exists; refusing to overwrite'}}
  else{[IO.File]::Copy((Join-Path $boot $efi),$target,$false)}
  "Staged $target; no boot entry created."
 }
 "Built $efi sha256=$hash; hardware untested."
} finally {Pop-Location}
