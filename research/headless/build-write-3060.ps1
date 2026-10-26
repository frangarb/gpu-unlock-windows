# GPL-2.0-only. Write-capable headless pair for the GA106 console-on-target
# profile: the exact-card unlock child plus the wrapper that releases all three
# console owners, loads the child from the ESP after hashing it, and starts
# Windows. Building it changes no device state; running it does.
param(
 [string]$Clang='clang',
 [string]$LldLink='lld-link',
 [string]$Python='python',
 [ValidateSet('asrock-b450m-rtx3060')][string]$HardwareProfile='asrock-b450m-rtx3060'
)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$unlock=Join-Path $repo 'internal-boot/unlock'
$boot=Join-Path $repo 'internal-boot/boot'
$table=@{
 'asrock-b450m-rtx3060'=[ordered]@{Define='-DGU_PROFILE_ASROCK_B450M_RTX3060';Name='ASROCK-B450M-HDV-R4.0-P10.60-RTX3060'}
}
$hw=$table[$HardwareProfile]
& (Join-Path $unlock 'build.ps1') -ExperimentalUnlock -StockProfile entryLatchedSs1Full -InternalBoot -AutomaticBoot -HeadlessResearch `
  -HardwareProfile $HardwareProfile -Clang $Clang -LldLink $LldLink -Python $Python
if(!$?){throw 'Unlock child build failed'}
$child=Join-Path $unlock 'build/experimental/entryLatchedSs1Full/internal/automatic/headless-research/RTX3090-EXPERIMENTAL-entryLatchedSs1Full-INTERNAL-AUTO-HEADLESS-RESEARCH.EFI'
$cm=Get-Content -LiteralPath (Join-Path (Split-Path $child) 'build-manifest.json') -Raw | ConvertFrom-Json
$hash=(Get-FileHash -LiteralPath $child).Hash.ToLowerInvariant()
if($cm.Mode -ne 'headless-research-automatic-internal-exact-card-unlock' -or $cm.EfiSha256 -ne $hash -or
   $cm.StockProfile -ne 'entryLatchedSs1Full' -or !$cm.CanArm -or $cm.HardwareProfile -ne $hw.Name){throw 'Unlock child contract mismatch'}
Push-Location (Join-Path $repo 'internal-boot/boot')
try {
 [void][IO.Directory]::CreateDirectory((Join-Path $PWD 'build/headless'))
 [void][IO.Directory]::CreateDirectory((Join-Path $PWD 'build/write3060'))
 @('/* Local headless child contract; GPL-2.0-only. */',('#define GU_UNLOCK_SHA256 "'+$hash+'"'),('#define GU_UNLOCK_BYTES '+(Get-Item $child).Length)) | Set-Content build/headless/child-contract.h -Encoding ascii
 $sources=@('handoff.c','full-release.c','full-flow.c','diagnostic.c','../unlock/checks.c','../unlock/sha256.c','../efi_runtime.c')
 $objects=@()
 foreach($source in $sources) {
  $obj='build/write3060/'+[IO.Path]::GetFileNameWithoutExtension($source)+'.obj'
  & $Clang -target x86_64-pc-windows-msvc -std=c11 -ffreestanding -fno-builtin -fno-stack-protector -mno-red-zone -fshort-wchar -Os -Wall -Wextra -Werror -DGU_HEADLESS_RESEARCH -DGU_SINGLE_RTX_CONSOLE -DGU_FULL_UNLOCK -DGU_AUTOMATIC_BOOT $hw.Define -I ../../deps/edk2/MdePkg/Include -I ../../deps/edk2/MdePkg/Include/X64 -c $source -o $obj
  if($LASTEXITCODE -ne 0){throw "Wrapper compile failed: $source"};$objects+=$obj
 }
 & $LldLink /nologo /nodefaultlib /subsystem:efi_application /entry:efi_main /machine:x64 /base:0 /dynamicbase /nxcompat /timestamp:0 /opt:ref /opt:icf /map:build/write3060/WRITE3060.map /out:build/write3060/WRITE3060.EFI @objects
 if($LASTEXITCODE -ne 0){throw 'Wrapper link failed'}
 & $Python ../unlock/verify_pe.py build/write3060/WRITE3060.EFI build/write3060/WRITE3060.map --output build/write3060/pe-verification.json
 if($LASTEXITCODE -ne 0){throw 'Wrapper PE verification failed'}
 [ordered]@{Mode='single-rtx-headless-exact-card-unlock';HardwareProfile=$hw.Name;CanUnlock=$true;CanWriteGpu=$true;RequiresHumanKey=$false;HardwareTested=$false;
  ChildName='UNLOCK-HEADLESS.EFI';ChildSha256=$hash;ChildBytes=(Get-Item $child).Length;ChildManifestSha256=(Get-FileHash -LiteralPath (Join-Path (Split-Path $child) 'build-manifest.json')).Hash;
  EfiSha256=(Get-FileHash -LiteralPath build/write3060/WRITE3060.EFI).Hash;EfiBytes=(Get-Item -LiteralPath build/write3060/WRITE3060.EFI).Length;
  LogName='\RTX3090-UNLOCK\HLS000000.TXT';BuiltUtc=[DateTime]::UtcNow.ToString('o')
 } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath build/write3060/manifest.json -Encoding utf8
} finally {Pop-Location}
"Built write pair for $($hw.Name): wrapper $((Get-FileHash -LiteralPath (Join-Path $boot 'build/write3060/WRITE3060.EFI')).Hash) child $hash; hardware untested."
