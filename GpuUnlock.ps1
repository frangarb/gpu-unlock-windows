# SPDX-License-Identifier: GPL-2.0-only
#
# NVIDIA Ampere unlock for Windows - end-user tool for one reviewed machine.
#
#   .\GpuUnlock.ps1 -Verify        check this boot: did the unlock run and is
#                                  the card running at full tensor rate?
#   .\GpuUnlock.ps1 -Activate      stage the images and add the firmware entry
#                                  (F8 menu; Windows stays the default)
#   .\GpuUnlock.ps1 -Activate -Automatic
#                                  also boot it automatically (turns Fast
#                                  Startup off)
#   .\GpuUnlock.ps1 -Deactivate    remove the entry and restore the boot order
#
# The unlock lives in firmware RAM only: a full power-off returns the card to
# factory state, and nothing here modifies the GPU, its BIOS or its driver.
param(
  [switch]$Activate,
  [switch]$Deactivate,
  [switch]$Verify,
  [switch]$Automatic
)
$ErrorActionPreference='Stop'
$repo=$PSScriptRoot
. (Join-Path $repo 'internal-boot/install/automatic-policy.ps1')

$entryName='NVIDIA Ampere Unlock - RTX 3060'
$entryPath='\EFI\WindowsGPUUnlock\WRITE3060.EFI'
$childName='UNLOCK-HEADLESS.EFI'
$stateDir=Join-Path $env:ProgramData 'WindowsGPUUnlock'
$stateFile=Join-Path $stateDir 'install.json'
$logDir='RTX3090-UNLOCK'
$power='HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'

if(@($Activate,$Deactivate,$Verify | Where-Object {$_}).Count -ne 1){throw 'Choose one action: -Activate, -Deactivate or -Verify'}
if($Automatic -and !$Activate){throw '-Automatic only applies to -Activate'}

function Bcd([string[]]$Arguments){
  $lines=@(& bcdedit @Arguments)
  if($LASTEXITCODE -ne 0){throw ('bcdedit failed: '+($Arguments -join ' '))}
  return ($lines -join "`r`n")
}
function Order([string]$Text){
  $m=[regex]::Match($Text,'(?ms)^displayorder\s+(.*?)(?=\r?\n\S|\z)')
  if(!$m.Success){throw 'No firmware display order'}
  return @([regex]::Matches($m.Groups[1].Value,'\{(?:bootmgr|[0-9a-f-]{36})\}') | ForEach-Object {$_.Value})
}
function SetOrder([string[]]$Values){[void](Bcd (@('/set','{fwbootmgr}','displayorder')+$Values))}
function ReadHiber{
  $k=Get-Item -LiteralPath $power
  $exists=$k.GetValueNames() -contains 'HiberbootEnabled'
  return @{Exists=$exists;Value=$(if($exists){[int]$k.GetValue('HiberbootEnabled')}else{$null})}
}
function SetHiber($Plan){
  if($Plan.Exists){[void](New-ItemProperty -LiteralPath $power -Name HiberbootEnabled -PropertyType DWord -Value ([int]$Plan.Value) -Force)}
  elseif((Get-Item -LiteralPath $power).GetValueNames() -contains 'HiberbootEnabled'){Remove-ItemProperty -LiteralPath $power -Name HiberbootEnabled}
}
function SaveState($Value){$Value | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $stateFile -Encoding utf8}
function LoadState{if(Test-Path -LiteralPath $stateFile){Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json}else{$null}}
function EntryId{
  $ids=@([regex]::Matches((Bcd @('/enum','firmware')),'(?mi)^(?:identifier|identificador)\s+(\{[0-9a-f-]{36}\})') | ForEach-Object {$_.Groups[1].Value})
  foreach($id in $ids){
    if($id -eq '{fwbootmgr}' -or $id -eq '{bootmgr}'){continue}
    $entry=Bcd @('/enum',$id)
    if($entry -match ('(?m)^description\s+'+[regex]::Escape($entryName)+'\s*$') -and $entry -match ('(?mi)^path\s+'+[regex]::Escape($entryPath)+'\s*$')){return $id}
  }
  return $null
}
function Target{
  $cfg=Get-Content -LiteralPath (Join-Path $repo 'internal-boot/local-config.json') -Raw | ConvertFrom-Json
  $part=Get-Partition -DriveLetter $cfg.UnlockDriveLetter
  $vol=$part | Get-Volume
  if($part.Guid -ne $cfg.UnlockPartitionGuid -or $part.IsSystem -or $part.GptType -ne '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -or $vol.FileSystem -ne 'FAT32' -or !$vol.Path){
    throw 'The dedicated unlock partition is not the configured one'
  }
  return $vol.Path
}
function DriveLetter{
  $cfg=Get-Content -LiteralPath (Join-Path $repo 'internal-boot/local-config.json') -Raw | ConvertFrom-Json
  return [string]$cfg.UnlockDriveLetter
}
function AssertMachine{
  $board=(Get-CimInstance Win32_BaseBoard).Product
  $bios=(Get-CimInstance Win32_BIOS).SMBIOSBIOSVersion
  if($board -ne 'B450M-HDV R4.0' -or $bios -ne 'P10.60'){throw ("This tool is built and reviewed for ASRock B450M-HDV R4.0 BIOS P10.60, not $board $bios")}
  $gpu=@(Get-CimInstance Win32_PnPEntity | Where-Object {$_.DeviceID -match '^PCI\\VEN_10DE&DEV_2504'})
  if($gpu.Count -ne 1){throw 'Expected exactly one NVIDIA device 10de:2504 (RTX 3060)'}
  if(Confirm-SecureBootUEFI){throw 'Secure Boot is on: this unsigned EFI cannot run. Disable it in firmware first.'}
}
function Images($Manifest){
  return @(
    [pscustomobject]@{Source=(Join-Path $repo 'internal-boot/boot/build/write3060/WRITE3060.EFI');Dest='EFI\WindowsGPUUnlock\WRITE3060.EFI';Hash=$Manifest.EfiSha256},
    [pscustomobject]@{Source=(Join-Path $repo 'internal-boot/unlock/build/experimental/entryLatchedSs1Full/internal/automatic/headless-research/RTX3090-EXPERIMENTAL-entryLatchedSs1Full-INTERNAL-AUTO-HEADLESS-RESEARCH.EFI');Dest=('EFI\WindowsGPUUnlock\'+$childName);Hash=$Manifest.ChildSha256}
  )
}
function AssertStaged([string]$Root,$Manifest){
  foreach($image in (Images $Manifest)){
    $file=Join-Path $Root $image.Dest
    if(!(Test-Path -LiteralPath $file) -or (Get-FileHash -LiteralPath $file).Hash -ne $image.Hash){throw ('Missing or different image: '+$image.Dest)}
  }
  foreach($a in (Get-Content -LiteralPath (Join-Path $repo 'internal-boot/unlock/assets.json') -Raw | ConvertFrom-Json)){
    $file=Join-Path $Root ($logDir+'\ASSETS\'+$a.Name)
    if(!(Test-Path -LiteralPath $file) -or (Get-Item -LiteralPath $file).Length -ne [int64]$a.Bytes -or (Get-FileHash -LiteralPath $file).Hash.ToLowerInvariant() -ne $a.Sha256){throw ('Missing or different firmware asset: '+$a.Name)}
  }
}
function Verify{
  $root=Target
  $dir=Join-Path $root $logDir
  if(!(Test-Path -LiteralPath $dir)){throw 'No unlock log directory on the unlock partition: the unlock never ran here'}
  $logs=@(Get-ChildItem -LiteralPath $dir -Filter 'HLS*.TXT' | Sort-Object Name)
  if($logs.Count -eq 0){throw 'No unlock log found: boot the NVIDIA Ampere Unlock entry first'}

  $last=$logs[-1]
  $runs=@(Get-ChildItem -LiteralPath $dir -Directory -Filter 'AUTO*' | Sort-Object Name)
  $report=$(if($runs.Count){Join-Path (Join-Path $dir $runs[-1].Name) 'REPORT.TXT'}else{''})
  $wrapper=Get-Content -LiteralPath $last.FullName -Raw
  $final=$(if(Test-Path -LiteralPath $report){Select-String -LiteralPath $report -Pattern '^FINAL ' | Select-Object -Last 1 | ForEach-Object {$_.Line}}else{''})
  $ok=$wrapper -match 'original-unlock-return status=0x0000000000000000' -and $final -match 'stage=transaction' -and $final -match 'attempted=1'
  Write-Output ("log: {0}" -f $last.Name)
  Write-Output ("child: {0}" -f $final)
  if(!$ok){
    Write-Output 'RESULT: the unlock did NOT complete on the last run.'
    Write-Output 'Nothing was changed on the card unless attempted=1; power cycle and read the log above.'
    exit 1
  }
  Write-Output 'RESULT: the unlock ran and the transaction completed.'

  $bench=Join-Path $repo 'research/bench/build/tensor_rate.exe'
  if(Test-Path -LiteralPath $bench){
    $out=& $bench 4096 20
    $out | ForEach-Object {Write-Output $_}
    $fp16=[double]([regex]::Match(($out -join "`n"),'fp16-in fp32-acc\s*:\s*([0-9.]+)').Groups[1].Value)
    if($fp16 -ge 35){Write-Output ("RESULT: full tensor rate ({0:N1} TFLOPS): the card is unlocked." -f $fp16)}
    elseif($fp16 -gt 0){Write-Output ("RESULT: GeForce rate ({0:N1} TFLOPS): this boot did not unlock. Was Windows booted instead of the unlock entry, or did the machine cold boot since?" -f $fp16)}
    else{Write-Output 'RESULT: the benchmark could not be measured.'}
  } else {
    Write-Output 'Tensor benchmark not built; run nvcc -O3 -arch=sm_86 research/bench/tensor_rate.cu -lcublas -o research/bench/build/tensor_rate.exe'
  }
  Write-Output 'A full power-off returns the card to factory state; nothing persistent was changed.'
}

if($Verify){AssertMachine;Verify;return}

AssertMachine
$root=Target
if($Deactivate){
  $id=EntryId
  if(!$id){Write-Output 'No unlock entry is registered; nothing to remove.';return}
  $before=Bcd @('/enum','{fwbootmgr}')
  $order=Order $before
  $state=LoadState
  Invoke-AutomaticTransition -Steps @(
    {[void](Bcd @('/delete',$id))},
    {SetOrder @($order | Where-Object {$_ -ne $id})}
  ) -Verify {
    if(EntryId){throw 'The unlock entry is still registered'}
    $now=Order (Bcd @('/enum','{fwbootmgr}'))
    $want=@($order | Where-Object {$_ -ne $id})
    if(($now -join ',') -cne ($want -join ',')){throw ('Boot order is '+(($now -join ',')+'; expected '+($want -join ',')))}
  } -Rollback {
    Write-Warning 'Removal stopped; inspect with: bcdedit /enum firmware'
  }
  if($state -and $state.HiberbootBefore){SetHiber $state.HiberbootBefore}
  Remove-Item -LiteralPath $stateFile -ErrorAction SilentlyContinue
  Write-Output 'Unlock entry removed and boot order restored. Images stay on the unlock partition.'
  Write-Output 'The card is already back to factory behaviour after the next full power-off.'
  return
}

# -Activate
$manifest=Get-Content -LiteralPath (Join-Path $repo 'internal-boot/boot/build/write3060/manifest.json') -Raw | ConvertFrom-Json
if($manifest.CanUnlock -ne $true -or $manifest.HardwareProfile -ne 'ASROCK-B450M-HDV-R4.0-P10.60-RTX3060'){throw 'This build is not the reviewed unlock pair for this machine'}
foreach($image in (Images $manifest)){
  if((Get-FileHash -LiteralPath $image.Source).Hash -ne $image.Hash){throw ('Build file changed: '+$image.Source)}
  $dest=Join-Path $root $image.Dest
  if(Test-Path -LiteralPath $dest){if((Get-FileHash -LiteralPath $dest).Hash -ne $image.Hash){throw ('Refusing to overwrite a different file: '+$image.Dest)}}
  else{[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest));[IO.File]::Copy($image.Source,$dest,$false)}
}
[void][IO.Directory]::CreateDirectory((Join-Path $root ($logDir+'\ASSETS')))
foreach($a in (Get-Content -LiteralPath (Join-Path $repo 'internal-boot/unlock/assets.json') -Raw | ConvertFrom-Json)){
  $src=Join-Path $repo ('assets/out/'+$a.Name)
  $dest=Join-Path $root ($logDir+'\ASSETS\'+$a.Name)
  if(Test-Path -LiteralPath $dest){
    if((Get-FileHash -LiteralPath $dest).Hash.ToLowerInvariant() -ne $a.Sha256){throw ('A different firmware asset is installed: '+$a.Name)}
  } else {
    if((Get-Item -LiteralPath $src).Length -ne [int64]$a.Bytes -or (Get-FileHash -LiteralPath $src).Hash.ToLowerInvariant() -ne $a.Sha256){throw ('Local asset missing or changed: '+$a.Name)}
    [IO.File]::Copy($src,$dest,$false)
  }
}
AssertStaged $root $manifest

$existing=EntryId
$order=Order (Bcd @('/enum','{fwbootmgr}'))
$fwBefore=Bcd @('/enum','{fwbootmgr}')
if($fwBefore -match '(?mi)^bootsequence\s+'){throw 'A one-time boot override is pending; reboot first'}
if(!$existing){
  if($order -notcontains '{bootmgr}'){throw 'The firmware entry list has no Windows Boot Manager; refusing to touch it'}
  $copyName=$entryName
  while((Bcd @('/enum','firmware')) -match ('(?m)^description\s+'+[regex]::Escape($copyName)+'\s*$')){$copyName=$copyName+' (2)'}
  $before=@([regex]::Matches((Bcd @('/enum','all')),'(?mi)^(?:identifier|identificador)\s+(\{[0-9a-f-]{36}\})') | ForEach-Object {$_.Groups[1].Value})
  $manager=Bcd @('/enum','{bootmgr}')
  $state=[ordered]@{EntryId=$null;Path=$entryPath;BootOrderBefore=$order;HiberbootBefore=(ReadHiber);Mode='activating';HardwareTested=$true}
  SaveState $state
  $reg=@{Id=$null}
  Invoke-AutomaticTransition -Steps @(
    {
      try{[void](Bcd @('/copy','{bootmgr}','/d',$copyName))}
      finally{
        $after=@([regex]::Matches((Bcd @('/enum','all')),'(?mi)^(?:identifier|identificador)\s+(\{[0-9a-f-]{36}\})') | ForEach-Object {$_.Groups[1].Value})
        $entries=@{}
        foreach($id in $after){if($before -notcontains $id){$entries[$id]=Bcd @('/enum',$id)}}
        $reg.Id=Resolve-NewBootCopy -BeforeIds $before -AfterEntries $entries -Source $manager -Name $copyName
      }
      $state.EntryId=$reg.Id;SaveState $state
    },
    {[void](Bcd @('/set',$reg.Id,'device',('partition='+(DriveLetter)+':')))},
    {[void](Bcd @('/set',$reg.Id,'path',$entryPath))},
    {[void](Bcd @('/set',$reg.Id,'description',$entryName))},
    {SetOrder (@($order)+@($reg.Id))}
  ) -Verify {
    $entry=Bcd @('/enum',$reg.Id)
    if($entry -notmatch ('(?mi)^path\s+'+[regex]::Escape($entryPath)+'\s*$') -or $entry -notmatch ('(?mi)^device\s+partition='+[regex]::Escape((DriveLetter))+':\s*$') -or $entry -notmatch ('(?m)^description\s+'+[regex]::Escape($entryName)+'\s*$')){throw 'Registered entry does not match'}
    if(((Order (Bcd @('/enum','{fwbootmgr}'))) -join ',') -cne ((@($order)+@($reg.Id)) -join ',')){throw 'Boot order changed unexpectedly'}
    AssertStaged $root $manifest
    $state.Mode='activated';SaveState $state
  } -Rollback {
    Invoke-RecoveryActions -Actions @({SetOrder $order},{if($reg.Id){$null=& bcdedit /enum $reg.Id 2>$null;if($LASTEXITCODE -eq 0){[void](Bcd @('/delete',$reg.Id))}}})
    Remove-Item -LiteralPath $stateFile -ErrorAction SilentlyContinue
  }
  Write-Output ('Registered "{0}" at the end of the F8 menu; Windows stays the default.' -f $entryName)
} else {
  if($order -notcontains $existing){SetOrder (@($order)+@($existing))}
  Write-Output ('"{0}" is already registered.' -f $entryName)
}

if($Automatic){
  $id=EntryId
  if(!$id){throw 'No entry to promote'}
  $order=Order (Bcd @('/enum','{fwbootmgr}'))
  $state=LoadState
  if(!$state){$state=[ordered]@{EntryId=$id;Path=$entryPath;BootOrderBefore=$order;Mode='activated';HardwareTested=$true};SaveState $state}
  $plan=@($id)+@($order | Where-Object {$_ -ne $id})
  Invoke-AutomaticTransition -Steps @(
    {SetHiber @{Exists=$true;Value=0}},
    {SetOrder $plan}
  ) -Verify {
    if(((Order (Bcd @('/enum','{fwbootmgr}'))) -join ',') -cne ($plan -join ',')){throw 'Automatic order not applied'}
    if((ReadHiber).Value -ne 0){throw 'Fast Startup is still on'}
    $state.Mode='automatic';SaveState $state
  } -Rollback {
    Invoke-RecoveryActions -Actions @({SetOrder $order},{SetHiber $state.HiberbootBefore})
  }
  Write-Output 'Automatic mode: the unlock runs at every boot before Windows. Fast Startup is off.'
}

Write-Output ''
Write-Output 'Next: restart, open the firmware boot menu (F8 on this board) and pick'
Write-Output ('  "{0}"' -f $entryName)
Write-Output 'The screen goes dark after the release; Windows brings the card back.'
Write-Output 'Then run: .\GpuUnlock.ps1 -Verify'
Write-Output 'To undo everything: .\GpuUnlock.ps1 -Deactivate  (and a full power-off)'
