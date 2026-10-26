# GPL-2.0-only. New manual observation entry only; preserve current boot priority.
param([switch]$Register,[switch]$ConsoleR2,[switch]$HeadlessUnlock,[switch]$Preflight,[switch]$ConsoleVerify,[switch]$ReleaseFull,[switch]$WriteFull)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $repo 'internal-boot/install/automatic-policy.ps1')
$stateFile=Join-Path $PSScriptRoot 'registration.local.json'
if($ConsoleR2){$stateFile=Join-Path $PSScriptRoot 'r2-registration.local.json'}
if($HeadlessUnlock){$stateFile=Join-Path $PSScriptRoot 'headless-registration.local.json'}
if($Preflight){$stateFile=Join-Path $PSScriptRoot 'preflight-registration.local.json'}
if($ConsoleVerify){$stateFile=Join-Path $PSScriptRoot 'console-verify-registration.local.json'}
if($ReleaseFull){$stateFile=Join-Path $PSScriptRoot 'release-full-registration.local.json'}
if($WriteFull){$stateFile=Join-Path $PSScriptRoot 'write-full-registration.local.json'}
if(@($ConsoleR2,$HeadlessUnlock,$Preflight,$ConsoleVerify,$ReleaseFull,$WriteFull | Where-Object {$_}).Count -gt 1){throw 'Choose one research mode'}
$config=Get-Content -LiteralPath (Join-Path $repo 'internal-boot/local-config.json') -Raw | ConvertFrom-Json
function Bcd([string[]]$Arguments){$lines=@(& bcdedit @Arguments);if($LASTEXITCODE -ne 0){throw ('BCDEdit failed: '+($Arguments -join ' '))};return ($lines -join "`r`n")}
function Ids([string]$Text){return @([regex]::Matches($Text,'(?mi)^(?:identifier|identificador)\s+(\{[0-9a-f-]{36}\})') | ForEach-Object {$_.Groups[1].Value})}
function Order([string]$Text){
 $m=[regex]::Match($Text,'(?ms)^displayorder\s+(.*?)(?=\r?\n\S|\z)');if(!$m.Success){throw 'No firmware order'}
 $v=@([regex]::Matches($m.Groups[1].Value,'\{(?:bootmgr|[0-9a-f-]{36})\}') | ForEach-Object {$_.Value})
 if($v -notcontains '{bootmgr}' -or @($v | Select-Object -Unique).Count -ne $v.Count){throw 'Invalid firmware order'};return $v
}
function SetOrder([string[]]$Values){[void](Bcd (@('/set','{fwbootmgr}','displayorder')+$Values))}
function ExistsBcd([string]$Id){$null=& bcdedit /enum $Id;return $LASTEXITCODE -eq 0}
function Target {
 $p=Get-Partition -DriveLetter $config.UnlockDriveLetter;$d=Get-Disk -Number $p.DiskNumber;$v=$p | Get-Volume
 if($p.Guid -ne $config.UnlockPartitionGuid -or $p.IsSystem -or $p.Offset -ne $config.UnlockOffset -or $p.Size -ne $config.UnlockSize -or $d.UniqueId -ne $config.UnlockDiskUniqueId -or $p.GptType -ne '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -or $v.FileSystem -ne 'FAT32' -or !$v.Path){throw 'Configured observation ESP identity changed'}
 return $v.Path
}
function CheckWindows {
 $w=@(Get-Partition | Where-Object {$_.Guid -eq $config.WindowsPartitionGuid})
 if($w.Count -ne 1 -or !$w[0].IsSystem -or $config.WindowsPartitionGuid -eq $config.UnlockPartitionGuid){throw 'Windows ESP identity changed'}
}
$root=Target
CheckWindows
if(Confirm-SecureBootUEFI){throw 'Unsigned observation EFI requires Secure Boot disabled'}
$encryption=Get-BitLockerVolume -MountPoint C:
if([int]$encryption.VolumeStatus -ne 0 -or [int]$encryption.ProtectionStatus -ne 0){throw 'Encryption state changed; observation installer does not change encryption settings'}
$name='GPU Headless Observe - NO UNLOCK';$path='\EFI\WindowsGPUUnlock\OBSERVE.EFI'
if($Preflight){
 # Read-only preflight of the reviewed profile for this machine: the manifest
 # must say it cannot arm, and it writes only its log on this ESP.
 $m=Get-Content -LiteralPath (Join-Path $repo 'internal-boot/unlock/build/internal/build-manifest.json') -Raw | ConvertFrom-Json
 if($m.Mode -ne 'diagnostic-preflight-only' -or $m.CanArm -ne $false -or $m.HardwareProfile -ne 'ASROCK-B450M-HDV-R4.0-P10.60-RTX3060'){throw 'Unexpected preflight contract'}
 $source=Join-Path $repo 'internal-boot/unlock/build/internal/RTX3090-PREFLIGHT-INTERNAL.EFI'
 $hash=$m.EfiSha256
 $name='GPU 3060 Preflight - NO WRITE';$path='\EFI\WindowsGPUUnlock\PREFLIGHT.EFI'
}elseif($HeadlessUnlock){
 $m=Get-Content -LiteralPath (Join-Path $repo 'internal-boot/boot/build/headless/manifest.json') -Raw | ConvertFrom-Json
 $hash='6839bbc9987fa26b794dc6e2ffe98791642ac6e21ef01c388da9fffef3a878a3'
 $childHash='4dce4c2d06e4950af39cd20bdb267f888df8e3563cbc7011be5aeffcfd3ca469'
 if($m.Mode -ne 'single-rtx-headless-unlock-then-windows' -or $m.CanUnlock -ne $true -or $m.RequiresHumanKey -ne $false -or $m.ChildSha256 -ne $childHash -or $m.ChildBytes -ne 67584){throw 'Unexpected headless unlock contract'}
 $source=Join-Path $repo 'internal-boot/boot/build/headless/HEADLESS.EFI'
 $child=Join-Path $repo 'internal-boot/unlock/build/experimental/entryLatchedSs1Full/internal/automatic/headless-research/RTX3090-EXPERIMENTAL-entryLatchedSs1Full-INTERNAL-AUTO-HEADLESS-RESEARCH.EFI'
 $childManifest=Get-Content (Join-Path (Split-Path $child) 'build-manifest.json') -Raw | ConvertFrom-Json
 if($childManifest.Mode -ne 'headless-research-automatic-internal-exact-card-unlock' -or $childManifest.StockProfile -ne 'entryLatchedSs1Full' -or $childManifest.EfiSha256 -ne $childHash -or (Get-FileHash -LiteralPath $child).Hash -ne $childHash){throw 'Headless child build identity mismatch'}
 # New filenames only: preserve every existing manual, automatic and R2 image.
 $childTarget=Join-Path $root 'EFI\WindowsGPUUnlock\UNLOCK-HEADLESS.EFI'
 if(Test-Path -LiteralPath $childTarget){if((Get-FileHash -LiteralPath $childTarget).Hash -ne $childHash){throw 'Different headless child exists; refusing overwrite'}}
 else{[IO.File]::Copy($child,$childTarget,$false)}
 $name='GPU Headless UNLOCK - EXPERIMENTAL';$path='\EFI\WindowsGPUUnlock\HEADLESS.EFI'
}elseif($ConsoleVerify){
 # Console-chain verification for this machine: it may never detach or write.
 $m=Get-Content -LiteralPath (Join-Path $repo 'internal-boot/boot/build/console-verify/manifest.json') -Raw | ConvertFrom-Json
 if($m.Mode -ne 'single-rtx-console-verify-only' -or $m.CanDetach -ne $false -or $m.CanUnlock -ne $false -or $m.CanWriteGpu -ne $false -or $m.HardwareProfile -ne 'ASROCK-B450M-HDV-R4.0-P10.60-RTX3060'){throw 'Unexpected console verify contract'}
 $source=Join-Path $repo 'internal-boot/boot/build/console-verify/CONSOLE-VERIFY.EFI'
 $hash=$m.EfiSha256
 $name='GPU 3060 Console Verify - NO WRITE';$path='\EFI\WindowsGPUUnlock\CONSOLE-VERIFY.EFI'
}elseif($WriteFull){
 # Write-capable pair for this machine: the release rehearsal above is green, so
 # the wrapper may load the exact-card unlock child and run it once.
 $m=Get-Content -LiteralPath (Join-Path $repo 'internal-boot/boot/build/write3060/manifest.json') -Raw | ConvertFrom-Json
 if($m.Mode -ne 'single-rtx-headless-exact-card-unlock' -or $m.CanUnlock -ne $true -or $m.CanWriteGpu -ne $true -or $m.HardwareProfile -ne 'ASROCK-B450M-HDV-R4.0-P10.60-RTX3060'){throw 'Unexpected write pair contract'}
 $source=Join-Path $repo 'internal-boot/boot/build/write3060/WRITE3060.EFI'
 $hash=$m.EfiSha256
 $child=Join-Path $repo 'internal-boot/unlock/build/experimental/entryLatchedSs1Full/internal/automatic/headless-research/RTX3090-EXPERIMENTAL-entryLatchedSs1Full-INTERNAL-AUTO-HEADLESS-RESEARCH.EFI'
 $childHash=$m.ChildSha256
 if((Get-FileHash -LiteralPath $child).Hash.ToLowerInvariant() -ne $childHash -or (Get-Item -LiteralPath $child).Length -ne $m.ChildBytes -or $m.ChildName -ne 'UNLOCK-HEADLESS.EFI'){throw 'Write pair child identity mismatch'}
 $name='GPU 3060 UNLOCK - HEADLESS';$path='\EFI\WindowsGPUUnlock\WRITE3060.EFI'
}elseif($ReleaseFull){
 # Full release rehearsal: both console consumers, then the runtime EDID/mouse
 # driver and nvgop, PCI decode restore and a cold verification, then Windows.
 # It must never be able to unlock or write GPU state.
 $m=Get-Content -LiteralPath (Join-Path $repo 'internal-boot/boot/build/release-full/manifest.json') -Raw | ConvertFrom-Json
 if($m.Mode -ne 'single-rtx-full-release-rehearsal' -or $m.CanUnlock -ne $false -or $m.CanWriteGpu -ne $false -or $m.CanDetach -ne $true -or $m.CanDetachNvOwner -ne $true -or $m.CanDetachRuntimeEdid -ne $true -or $m.CanRemoveGop -ne $true -or $m.HardwareProfile -ne 'ASROCK-B450M-HDV-R4.0-P10.60-RTX3060'){throw 'Unexpected full release rehearsal contract'}
 $source=Join-Path $repo 'internal-boot/boot/build/release-full/RELEASE-FULL.EFI'
 $hash=$m.EfiSha256
 $name='GPU 3060 Full Release - NO UNLOCK';$path='\EFI\WindowsGPUUnlock\RELEASE-FULL.EFI'
}elseif($ConsoleR2){
 $m=Get-Content -LiteralPath (Join-Path $repo 'internal-boot/boot/build/r2/manifest.json') -Raw | ConvertFrom-Json
 if($m.Mode -ne 'single-rtx-console-consumers-only' -or $m.RequiresHumanKey -ne $false -or $m.CanUnlock -ne $false -or $m.CanDetach -ne $true -or $m.CanDetachNvOwner -ne $false -or $m.CanDetachRuntimeEdid -ne $false -or $m.CanRemoveGop -ne $false){throw 'Unexpected R2 capabilities'}
 # Same machine gate as the verification entry: the release image must be this
 # board's own build, and its hash comes from that build.
 if($m.HardwareProfile -ne 'ASROCK-B450M-HDV-R4.0-P10.60-RTX3060'){throw 'Console release image is for another profile'}
 $source=Join-Path $repo 'internal-boot/boot/build/r2/R2-CONSOLE.EFI'
 $hash=$m.EfiSha256
 $name='GPU 3060 Console Release - NO UNLOCK';$path='\EFI\WindowsGPUUnlock\CONSOLE-RELEASE.EFI'
}else{
 $m=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'build/manifest.json') -Raw | ConvertFrom-Json
 if($m.Mode -ne 'headless-research-observation-only' -or $m.CanUnlock -ne $false -or $m.CanDetach -ne $false){throw 'Unexpected observation capabilities'}
 $source=Join-Path $PSScriptRoot 'build/OBSERVE.EFI'
 if($m.HardwareProfile -eq 'discovery'){
  # A discovery image is machine-specific by construction and was never a
  # reviewed constant, so its own build manifest supplies the hash. It still
  # cannot arm anything: the capability checks above are unchanged.
  $hash=$m.EfiSha256; $name='GPU Discovery Observe - NO UNLOCK'
 }else{
  $hash='4c0672952a2b2f4a1e97520be1fe3332cc1a519efd9dbf5d3326ff900790988e'
 }
}
if($m.EfiSha256 -ne $hash -or (Get-FileHash -LiteralPath $source).Hash -ne $hash){throw 'This registration requires the reviewed local observation image; different profiles need separate review'}
$target=Join-Path $root $path.TrimStart('\')
# The image logs and dumps into \RTX3090-UNLOCK; FAT32 cannot create that file
# without its directory, so both trees must exist. Directories only, no state.
[void][IO.Directory]::CreateDirectory((Join-Path $root 'EFI\WindowsGPUUnlock'))
[void][IO.Directory]::CreateDirectory((Join-Path $root 'RTX3090-UNLOCK'))
if($Preflight){[void][IO.Directory]::CreateDirectory((Join-Path $root 'RTX3090-PREFLIGHT'))}
if(Test-Path -LiteralPath $target){if((Get-FileHash -LiteralPath $target).Hash -ne $hash){throw 'Different observation EFI exists; never overwrite'}}
else{[IO.File]::Copy($source,$target,$false)}
if($WriteFull){
 $childTarget=Join-Path $root 'EFI\WindowsGPUUnlock\UNLOCK-HEADLESS.EFI'
 if(Test-Path -LiteralPath $childTarget){if((Get-FileHash -LiteralPath $childTarget).Hash.ToLowerInvariant() -ne $childHash){throw 'A different unlock child is already staged; never overwrite'}}
 else{[IO.File]::Copy($child,$childTarget,$false)}
 # The child reads the five firmware assets from \RTX3090-UNLOCK\ASSETS and
 # stops at stage=assets before touching the card if any is missing or differs.
 $assetDir=Join-Path $root 'RTX3090-UNLOCK\ASSETS'
 [void][IO.Directory]::CreateDirectory($assetDir)
 foreach($a in (Get-Content -LiteralPath (Join-Path $repo 'internal-boot/unlock/assets.json') -Raw | ConvertFrom-Json)){
  $src=Join-Path $repo ('assets/out/'+$a.Name)
  if(!(Test-Path -LiteralPath $src) -or (Get-Item -LiteralPath $src).Length -ne [int64]$a.Bytes -or (Get-FileHash -LiteralPath $src).Hash.ToLowerInvariant() -ne $a.Sha256){throw ('Firmware asset missing or changed: '+$a.Name)}
  $dst=Join-Path $assetDir $a.Name
  if(Test-Path -LiteralPath $dst){if((Get-FileHash -LiteralPath $dst).Hash.ToLowerInvariant() -ne $a.Sha256){throw ('A different asset is installed: '+$a.Name)}}
  else{[IO.File]::Copy($src,$dst,$false)}
  if((Get-Item -LiteralPath $dst).Length -ne [int64]$a.Bytes -or (Get-FileHash -LiteralPath $dst).Hash.ToLowerInvariant() -ne $a.Sha256){throw ('Staged asset readback mismatch: '+$a.Name)}
 }
}
function CheckTarget {CheckWindows;if((Target) -ne $root -or (Get-FileHash -LiteralPath $target).Hash -ne $hash){throw 'Observation target changed'};if(($HeadlessUnlock -or $WriteFull) -and (Get-FileHash -LiteralPath $childTarget).Hash.ToLowerInvariant() -ne $childHash){throw 'Headless child target changed'}}
CheckTarget
if(!$Register){Write-Output 'Observation EFI staged only; no boot entry/order changes.';return}
if(Test-Path -LiteralPath $stateFile){throw 'Registration state already exists; inspect it before registering again'}
$fw=Bcd @('/enum','{fwbootmgr}');$order=Order $fw;$manager=Bcd @('/enum','{bootmgr}');$firmwareBefore=Bcd @('/enum','firmware')
if($fw -match '(?mi)^bootsequence\s+'){throw 'Pending BootNext: observation registration refused'}
# Preserve every existing entry, including its device/path/description.
$existing=@{}
foreach($old in $order){$existing[$old]=Bcd @('/enum',$old)}
$beforeIds=Ids (Bcd @('/enum','all'));$reg=@{Id=$null}
$backup=Join-Path $env:ProgramData ('WindowsGPUUnlock\ResearchBackups\'+(Get-Date -Format 'yyyyMMdd-HHmmssfff'))
[void][IO.Directory]::CreateDirectory($backup)
[void](Bcd @('/export',(Join-Path $backup 'BCD-export')))
[IO.File]::WriteAllText((Join-Path $backup 'firmware-before.txt'),$firmwareBefore)
$state=[ordered]@{EntryId=$null;Name=$name;Path=$path;BackupRoot=$backup;BootOrderBefore=$order;EfiSha256=$hash;CanUnlock=([bool]$HeadlessUnlock -or [bool]$WriteFull);CanDetach=([bool]$ConsoleR2 -or [bool]$HeadlessUnlock -or [bool]$ReleaseFull -or [bool]$WriteFull);Status='registering';HardwareTested=$false}
CheckTarget
if((Bcd @('/enum','{fwbootmgr}')) -cne $fw -or (Bcd @('/enum','firmware')) -cne $firmwareBefore){throw 'Firmware changed before registration'}
Invoke-AutomaticTransition -Steps @(
 {
  try{[void](Bcd @('/copy','{bootmgr}','/d',$name))}
  finally{
   $entries=@{}
   foreach($candidate in (Ids (Bcd @('/enum','all')))){if($beforeIds -notcontains $candidate){$entries[$candidate]=Bcd @('/enum',$candidate)}}
   $reg.Id=Resolve-NewBootCopy -BeforeIds $beforeIds -AfterEntries $entries -Source $manager -Name $name
  }
  $state.EntryId=$reg.Id
  $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $stateFile -Encoding utf8
 },
 {[void](Bcd @('/set',$reg.Id,'device',('partition='+$config.UnlockDriveLetter+':')))},
 {[void](Bcd @('/set',$reg.Id,'path',$path))},
 {SetOrder (@($order)+@($reg.Id))}
) -Verify {
 $after=Bcd @('/enum','{fwbootmgr}');$entry=Bcd @('/enum',$reg.Id)
 if(((Order $after) -join ',') -cne ((@($order)+@($reg.Id)) -join ',') -or $after -match '(?mi)^bootsequence\s+' -or $entry -notmatch ('(?mi)^path\s+'+[regex]::Escape($path)+'\s*$') -or $entry -notmatch ('(?m)^description\s+'+[regex]::Escape($name)+'\s*$') -or $entry -notmatch ('(?mi)^device\s+partition='+[regex]::Escape($config.UnlockDriveLetter)+':\s*$')){throw 'Observation entry verification failed'}
 foreach($old in $order){if((Bcd @('/enum',$old)) -cne $existing[$old]){throw 'Existing boot entry changed'}}
 CheckTarget
 $state.Status='registered';$state['RegisteredUtc']=[DateTime]::UtcNow.ToString('o')
 $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $stateFile -Encoding utf8
 $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $backup 'registration.json') -Encoding utf8
 [IO.File]::WriteAllText((Join-Path $backup 'firmware-after.txt'),(Bcd @('/enum','firmware')))
} -Rollback {
 Invoke-RecoveryActions -Actions @({SetOrder $order},{if($reg.Id -and (ExistsBcd $reg.Id)){[void](Bcd @('/delete',$reg.Id))}})
 if(!$reg.Id -or (Bcd @('/enum','{fwbootmgr}')) -cne $fw -or (ExistsBcd $reg.Id)){throw ('Recovery incomplete; inspect '+$backup)}
 foreach($old in $order){if((Bcd @('/enum',$old)) -cne $existing[$old]){throw ('Existing entry differs; inspect '+$backup)}}
 if(Test-Path -LiteralPath $stateFile){$owned=Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json;if($owned.EntryId -ne $reg.Id){throw 'State changed; refusing to remove it'};Remove-Item -LiteralPath $stateFile -ErrorAction Stop}
}
Write-Output "Registered $name at the end of F8 menu. Default order prefix preserved; no BootNext/reboot/BIOS changes. Backup: $backup"
