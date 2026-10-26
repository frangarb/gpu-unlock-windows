# SPDX-License-Identifier: GPL-2.0-only
#
# NVIDIA Ampere unlock for Windows - end-user tool for one reviewed machine.
#
#   .\GpuUnlock.ps1 -Gui           window: status, verify, activate, deactivate
#   .\GpuUnlock.ps1 -Status        one screen of state; no writes, no reboot
#   .\GpuUnlock.ps1 -Status -Json  the same state, machine-readable
#   .\GpuUnlock.ps1 -Verify        check this boot: did the unlock run and is
#                                  the card running at full tensor rate?
#   .\GpuUnlock.ps1 -Baseline      record the locked rate once, on a clean boot
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
  [switch]$Automatic,
  [switch]$Gui,
  [switch]$Status,
  [switch]$Json,
  [switch]$Baseline,
  [switch]$SelfCheck,
  [ValidateSet('Verify','Measure','Activate','Deactivate','Automatic')][string]$StartAction
)
$ErrorActionPreference='Stop'
$repo=$PSScriptRoot
. (Join-Path $repo 'internal-boot/install/automatic-policy.ps1')

$entryName='NVIDIA Ampere Unlock - RTX 3060'
$entryPath='\EFI\WindowsGPUUnlock\WRITE3060.EFI'
$childName='UNLOCK-HEADLESS.EFI'
$stateDir=Join-Path $env:ProgramData 'WindowsGPUUnlock'
$stateFile=Join-Path $stateDir 'install.json'
$baselineFile=Join-Path $stateDir 'baseline.json'
$logDir='RTX3090-UNLOCK'
$power='HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
# One place for the measurement: 4096 x 20 is the shape every recorded number
# in evidence/ uses. Smaller shapes understate this part (2048/3 reads ~35).
$benchN=4096
$benchReps=20
# Measured on this part: locked ~25, unlocked 45-48 TFLOPS FP16->FP32.
$unlockFp16=35

if($Json -and !$Status){throw '-Json only applies to -Status'}
if($SelfCheck -and !$Gui){throw '-SelfCheck only applies to -Gui'}
if($StartAction -and !$Gui){throw '-StartAction only applies to -Gui'}
if(!$Gui -and @($Activate,$Deactivate,$Verify,$Status,$Baseline | Where-Object {$_}).Count -ne 1){
  throw 'Choose one action: -Gui, -Status, -Verify, -Baseline, -Activate or -Deactivate'
}
if($Gui -and @($Activate,$Deactivate,$Verify,$Baseline | Where-Object {$_}).Count -gt 1){throw 'Choose one action'}
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
function SaveState($Value){
  [void][IO.Directory]::CreateDirectory($stateDir)
  $Value | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $stateFile -Encoding utf8
}
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
}
# Removal deliberately does not check this: an entry must always be removable.
function AssertSecureBootOff{
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

# --- read-only state, measurement and baseline -----------------------------

function Test-Admin{
  $id=[Security.Principal.WindowsIdentity]::GetCurrent()
  return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-Benchmark{
  $exe=Join-Path $repo 'research/bench/build/tensor_rate.exe'
  if(!(Test-Path -LiteralPath $exe)){return $null}
  $out=@(& $exe $benchN $benchReps)
  $text=$out -join "`n"
  $fp16=[double]([regex]::Match($text,'fp16-in fp32-acc\s*:\s*([0-9.]+)').Groups[1].Value)
  return [pscustomobject]@{
    Raw=$out
    Fp16=$fp16
    Tf32=[double]([regex]::Match($text,'tf32-in fp32-acc\s*:\s*([0-9.]+)').Groups[1].Value)
    Fp32=[double]([regex]::Match($text,'fp32 simt\s*:\s*([0-9.]+)').Groups[1].Value)
  }
}

# 35 TFLOPS sits between the two rates this part actually produces; the GeForce
# limit is ~25 and a full-rate card reads 45-48 with the same shape.
function Get-UnlockVerdict([double]$Fp16){
  if($Fp16 -ge $unlockFp16){return 'unlocked'}
  if($Fp16 -gt 0){return 'locked'}
  return 'unknown'
}

function Read-Baseline{
  if(!(Test-Path -LiteralPath $baselineFile)){return $null}
  return Get-Content -LiteralPath $baselineFile -Raw | ConvertFrom-Json
}

function Get-GpuUnlockStatus{
  $board=(Get-CimInstance Win32_BaseBoard).Product
  $bios=(Get-CimInstance Win32_BIOS).SMBIOSBIOSVersion
  $gpu=@(Get-CimInstance Win32_PnPEntity | Where-Object {$_.DeviceID -match '^PCI\\VEN_10DE&DEV_2504'})
  try{$secureBoot=Confirm-SecureBootUEFI}catch{$secureBoot=$null}
  $id=$null
  $order=@()
  $entryLast=$false
  try{
    $id=EntryId
    $order=Order (Bcd @('/enum','{fwbootmgr}'))
    $entryLast=($id -and $order.Count -gt 0 -and $order[-1] -eq $id)
  }catch{$id=$null}
  $last=$null
  $final=''
  $logs=0
  try{
    $dir=Join-Path (Target) $logDir
    $found=@(Get-ChildItem -LiteralPath $dir -Filter 'HLS*.TXT' -ErrorAction Stop | Sort-Object Name)
    $logs=$found.Count
    if($logs){
      $last=$found[-1]
      $runs=@(Get-ChildItem -LiteralPath $dir -Directory -Filter 'AUTO*' | Sort-Object Name)
      $report=$(if($runs.Count){Join-Path (Join-Path $dir $runs[-1].Name) 'REPORT.TXT'}else{''})
      if(Test-Path -LiteralPath $report){$final=Select-String -LiteralPath $report -Pattern '^FINAL ' | Select-Object -Last 1 | ForEach-Object {$_.Line}}
    }
  }catch{}
  $runOk=[bool]($last -and (Get-Content -LiteralPath $last.FullName -Raw) -match 'original-unlock-return status=0x0000000000000000' -and $final -match 'stage=transaction' -and $final -match 'attempted=1')
  $baseline=Read-Baseline
  return [pscustomobject]@{
    Machine=$board
    Bios=$bios
    MachineOk=($board -eq 'B450M-HDV R4.0' -and $bios -eq 'P10.60')
    Gpu=$(if($gpu.Count){$gpu[0].Name}else{''})
    GpuOk=($gpu.Count -eq 1)
    SecureBoot=$secureBoot
    Admin=(Test-Admin)
    EntryRegistered=[bool]$id
    EntryId=$id
    EntryLast=$entryLast
    Automatic=[bool]($id -and $order.Count -gt 0 -and $order[0] -eq $id)
    Logs=$logs
    LastLog=$(if($last){$last.Name}else{''})
    LastLogTime=$(if($last){$last.LastWriteTime.ToString('yyyy-MM-dd HH:mm')}else{''})
    RunOk=$runOk
    Stage=$(if($final -match 'stage=(\S+)'){$Matches[1]}else{''})
    Attempted=[bool]($final -match 'attempted=1')
    BaselineFp16=$(if($baseline){[double]$baseline.Fp16}else{$null})
    BaselineUtc=$(if($baseline){[string]$baseline.MeasuredUtc}else{$null})
    Verdict=$null
  }
}

function Format-Status($S){
  $sb=$(if($S.SecureBoot -eq $true){'on (the unsigned EFI cannot run)'}elseif($S.SecureBoot -eq $false){'off'}else{'unknown (needs administrator)'})
  $entry=$(if($S.EntryRegistered){$S.EntryId+' last in the F8 menu'}else{'not registered'})
  if($S.EntryRegistered -and !$S.EntryLast){$entry=$S.EntryId+' registered, not last in the F8 menu'}
  if($S.Automatic){$entry=$S.EntryId+' automatic (first, Windows second)'}
  $run=$(if($S.LastLog){$S.LastLog+' at '+$S.LastLogTime}else{'never ran here'})
  if($S.Stage){$run=$run+' - stage='+$S.Stage+' attempted='+([int]$S.Attempted)}
  $base=$(if($S.BaselineFp16){(('{0:N1} TFLOPS recorded at {1}' -f $S.BaselineFp16,$S.BaselineUtc))}else{'not recorded (run -Baseline on a clean boot)'})
  $lines=@(
    ('machine:     {0} BIOS {1} {2}' -f $S.Machine,$S.Bios,$(if($S.MachineOk){'(supported)'}else{'(NOT the reviewed machine)'})),
    ('gpu:         {0} {1}' -f $(if($S.Gpu){$S.Gpu}else{'10de:2504 not found'}),$(if($S.GpuOk){'(supported)'}else{'(check the card)'})),
    ('secure boot: '+$sb),
    ('admin:       '+$(if($S.Admin){'yes'}else{'no (activate and deactivate need it)'})),
    ('entry:       '+$entry),
    ('last run:    '+$run),
    ('logs:       '+$S.Logs+' on the unlock partition'),
    ('baseline:    '+$base)
  )
  return ($lines -join "`n")
}

# Prints the run and sets $script:LastVerify (Ok, Bench); output stays on the
# pipeline so the window and the console show the same text.
function Invoke-Verify{
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
    $script:LastVerify=[pscustomobject]@{Ok=$false;Bench=$null}
    return
  }
  Write-Output 'RESULT: the unlock ran and the transaction completed.'

  $bench=Get-Benchmark
  if($bench -and $bench.Fp16 -gt 0){
    $bench.Raw | ForEach-Object {Write-Output $_}
    $verdict=Get-UnlockVerdict $bench.Fp16
    if($verdict -eq 'unlocked'){Write-Output ("RESULT: full tensor rate ({0:N1} TFLOPS): the card is unlocked." -f $bench.Fp16)}
    else{Write-Output ("RESULT: GeForce rate ({0:N1} TFLOPS): this boot did not unlock. Was Windows booted instead of the unlock entry, or did the machine cold boot since?" -f $bench.Fp16)}
    $baseline=Read-Baseline
    if($baseline -and [double]$baseline.Fp16 -gt 0){
      $gain=(($bench.Fp16/[double]$baseline.Fp16)-1)*100
      Write-Output ("baseline: {0:N1} TFLOPS on {1:d} -> {2:+0;-0}% FP16" -f [double]$baseline.Fp16,$baseline.MeasuredUtc,$gain)
    }
  } else {
    Write-Output 'Tensor benchmark not built; run nvcc -O3 -arch=sm_86 research/bench/tensor_rate.cu -lcublas -o research/bench/build/tensor_rate.exe'
  }
  Write-Output 'A full power-off returns the card to factory state; nothing persistent was changed.'
  $script:LastVerify=[pscustomobject]@{Ok=$true;Bench=$bench}
}

function Invoke-Baseline{
  AssertMachine
  AssertSecureBootOff
  $bench=Get-Benchmark
  if(!$bench -or $bench.Fp16 -le 0){throw ('The tensor benchmark could not be measured; build it first: nvcc -O3 -arch=sm_86 research/bench/tensor_rate.cu -lcublas -o research/bench/build/tensor_rate.exe')}
  if((Get-UnlockVerdict $bench.Fp16) -eq 'unlocked'){
    throw ('This boot measures {0:N1} TFLOPS, so the card is unlocked and this is not a locked baseline. Power off, boot Windows without the unlock entry and run -Baseline again.' -f $bench.Fp16)
  }
  $now=(Get-Date).ToUniversalTime()
  [void][IO.Directory]::CreateDirectory($stateDir)
  [ordered]@{
    Gpu='NVIDIA GeForce RTX 3060 12GB (10de:2504)'
    Fp16=[math]::Round($bench.Fp16,2)
    Tf32=[math]::Round($bench.Tf32,2)
    Fp32=[math]::Round($bench.Fp32,2)
    N=$benchN
    Reps=$benchReps
    MeasuredUtc=$now.ToString('o')
    BootUtc=((Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o'))
  } | ConvertTo-Json | Set-Content -LiteralPath $baselineFile -Encoding utf8
  Write-Output ('baseline recorded: {0:N2} TFLOPS FP16, {1:N2} TF32 ({2})' -f $bench.Fp16,$bench.Tf32,$baselineFile)
  Write-Output 'Boot the unlock entry and run -Verify to see the measured gain.'
}

# --- mutations -------------------------------------------------------------

function Invoke-Deactivate{
  AssertMachine
  $root=Target
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
}

function Invoke-Activate([switch]$Automatic){
  AssertMachine
  AssertSecureBootOff
  $root=Target
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
}

# --- window ----------------------------------------------------------------

function Restart-Elevated([string]$Action){
  $file=Join-Path $PSHOME 'powershell.exe'
  if(!(Test-Path -LiteralPath $file)){$file='powershell.exe'}
  $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-Gui')
  if($Action){$arguments+=@('-StartAction',$Action)}
  Start-Process -FilePath $file -Verb RunAs -ArgumentList $arguments
}

function Show-GpuUnlockWindow{
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  [void][System.Windows.Forms.Application]::EnableVisualStyles()

  $admin=Test-Admin
  $state=@{Bench=$null;SelfCheck=$SelfCheck}

  $form=New-Object System.Windows.Forms.Form
  $form.Text='NVIDIA Ampere Unlock - RTX 3060'
  $form.ClientSize=New-Object System.Drawing.Size(760,600)
  $form.StartPosition='CenterScreen'
  $form.FormBorderStyle='FixedSingle'
  $form.MaximizeBox=$false
  $form.Font=New-Object System.Drawing.Font('Segoe UI',9)
  $form.BackColor=[System.Drawing.Color]::FromArgb(250,250,250)

  $badge=New-Object System.Windows.Forms.Label
  $badge.Location=New-Object System.Drawing.Point(20,14)
  $badge.Size=New-Object System.Drawing.Size(720,46)
  $badge.TextAlign='MiddleCenter'
  $badge.Font=New-Object System.Drawing.Font('Segoe UI',16,[System.Drawing.FontStyle]::Bold)
  $badge.Text='CHECKING'
  $form.Controls.Add($badge)

  $captions=@('Machine','GPU','Secure Boot','Boot entry','Last attempt','Transaction','Tensor rate')
  $values=@()
  for($i=0;$i -lt $captions.Count;$i++){
    $key=New-Object System.Windows.Forms.Label
    $key.Text=$captions[$i]
    $key.Location=New-Object System.Drawing.Point(20,(78+($i*26)))
    $key.Size=New-Object System.Drawing.Size(120,20)
    $key.Font=New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Bold)
    $key.ForeColor=[System.Drawing.Color]::FromArgb(70,70,70)
    $form.Controls.Add($key)
    $v=New-Object System.Windows.Forms.Label
    $v.Location=New-Object System.Drawing.Point(145,(78+($i*26)))
    $v.Size=New-Object System.Drawing.Size(600,20)
    $form.Controls.Add($v)
    $values+=$v
  }

  $out=New-Object System.Windows.Forms.TextBox
  $out.Location=New-Object System.Drawing.Point(20,330)
  $out.Size=New-Object System.Drawing.Size(720,236)
  $out.Multiline=$true
  $out.ReadOnly=$true
  $out.ScrollBars='Vertical'
  $out.WordWrap=$false
  $out.Font=New-Object System.Drawing.Font('Consolas',9)
  $out.BackColor=[System.Drawing.Color]::White
  $out.Text='Press VERIFY to read the last run and measure the card.'
  $form.Controls.Add($out)

  $banner=New-Object System.Windows.Forms.Label
  $banner.Location=New-Object System.Drawing.Point(20,296)
  $banner.Size=New-Object System.Drawing.Size(720,26)
  $banner.ForeColor=[System.Drawing.Color]::FromArgb(150,60,0)
  $banner.Text=$(if($admin){''}else{'Not elevated: VERIFY and MEASURE work; ACTIVATE and DEACTIVATE will ask for administrator.'})
  $form.Controls.Add($banner)

  $refresh={
    if($script:LastVerify -and $script:LastVerify.Bench -and $script:LastVerify.Bench.Fp16 -gt 0){$state.Bench=$script:LastVerify.Bench}
    $s=Get-GpuUnlockStatus
    $values[0].Text=('{0} - BIOS {1}{2}' -f $s.Machine,$s.Bios,$(if($s.MachineOk){''}else{'  (NOT the reviewed machine)'}))
    $values[1].Text=('{0}{1}' -f $(if($s.Gpu){$s.Gpu}else{'10de:2504 not found'}),$(if($s.GpuOk){'  (10de:2504)'}else{'  (check the card)'}))
    $values[2].Text=$(if($s.SecureBoot -eq $true){'ON - the unsigned EFI cannot run'}elseif($s.SecureBoot -eq $false){'off'}else{'unknown (needs administrator)'})
    if($s.Automatic){$values[3].Text=('{0}  automatic: first, Windows second' -f $s.EntryId)}
    elseif($s.EntryRegistered){$values[3].Text=('{0}{1}' -f $s.EntryId,$(if($s.EntryLast){'  last in the F8 menu (manual)'}else{'  registered, not last in the F8 menu'}))}
    else{$values[3].Text='not registered'}
    $values[4].Text=$(if($s.LastLog){'{0} at {1}' -f $s.LastLog,$s.LastLogTime}else{'never ran on this machine'})
    $values[5].Text=$(if($s.Stage){'stage={0}  attempted={1}' -f $s.Stage,[int]$s.Attempted}else{'no report yet'})
    if($state.Bench -and $state.Bench.Fp16 -gt 0){
      $text=('{0:N1} TFLOPS FP16 / {1:N1} TF32' -f $state.Bench.Fp16,$state.Bench.Tf32)
      if($s.BaselineFp16 -gt 0){$text+=(('   ({0:+0;-0}% vs baseline {1:N1})' -f ((($state.Bench.Fp16/$s.BaselineFp16)-1)*100),$s.BaselineFp16))}
      elseif(!$s.RunOk){}else{$text+='   (no baseline yet: run -Baseline on a clean boot)'}
      $values[6].Text=$text
    } elseif($s.BaselineFp16){
      $values[6].Text=('not measured this window   (baseline {0:N1} TFLOPS)' -f $s.BaselineFp16)
    } else {
      $values[6].Text='not measured yet'
    }
    $verdict=$(if($state.Bench){Get-UnlockVerdict $state.Bench.Fp16}else{'unknown'})
    if($verdict -eq 'unlocked'){
      $badge.Text='UNLOCKED - full tensor rate'
      $badge.BackColor=[System.Drawing.Color]::FromArgb(22,120,60)
      $badge.ForeColor=[System.Drawing.Color]::White
    } elseif($verdict -eq 'locked'){
      $badge.Text='LOCKED - GeForce tensor rate'
      $badge.BackColor=[System.Drawing.Color]::FromArgb(160,40,40)
      $badge.ForeColor=[System.Drawing.Color]::White
    } elseif($s.RunOk){
      $badge.Text='NOT MEASURED - the transaction completed on the last run'
      $badge.BackColor=[System.Drawing.Color]::FromArgb(70,80,95)
      $badge.ForeColor=[System.Drawing.Color]::White
    } else {
      $badge.Text='UNKNOWN - verify to measure'
      $badge.BackColor=[System.Drawing.Color]::FromArgb(210,210,210)
      $badge.ForeColor=[System.Drawing.Color]::FromArgb(60,60,60)
    }
  }

  $run={
    param([string]$Label,[scriptblock]$Action,[switch]$NeedsAdmin)
    if($NeedsAdmin -and !$admin){
      Restart-Elevated $Label
      $form.Close()
      return
    }
    if($out.Text -eq 'Press VERIFY to read the last run and measure the card.'){$out.Text=''}
    $out.AppendText(("`r`n== {0} ==`r`n" -f $Label))
    try{
      $text=(& $Action *>&1 | Out-String)
      if($text.Trim()){$out.AppendText($text)}
    } catch {
      $message='ERROR: '+$_.Exception.Message
      $out.AppendText($message+"`r`n")
      [Console]::Error.WriteLine($message)
    }
    $out.SelectionStart=$out.Text.Length
    $out.ScrollToCaret()
    & $refresh
  }

  function New-ActionButton([string]$Text,[int]$X,[int]$Width,[scriptblock]$OnClick){
    $b=New-Object System.Windows.Forms.Button
    $b.Text=$Text
    $b.Location=New-Object System.Drawing.Point($X,258)
    $b.Size=New-Object System.Drawing.Size($Width,28)
    $b.UseVisualStyleBackColor=$true
    $b.Add_Click($OnClick)
    $form.Controls.Add($b)
    return $b
  }

  [void](New-ActionButton 'VERIFY' 20 100 { & $run 'Verify' { Invoke-Verify } })
  [void](New-ActionButton 'MEASURE' 128 90 { & $run 'Measure' { $b=Get-Benchmark; if(!$b){'Tensor benchmark not built; see docs/BENCHMARK.en.md'}else{$state.Bench=$b; $b.Raw; ('verdict: '+ (Get-UnlockVerdict $b.Fp16))} } })
  [void](New-ActionButton 'ACTIVATE' 226 90 { & $run 'Activate' { Invoke-Activate } -NeedsAdmin })
  $auto=New-Object System.Windows.Forms.CheckBox
  $auto.Text='also automatic'
  $auto.Location=New-Object System.Drawing.Point(324,262)
  $auto.Size=New-Object System.Drawing.Size(120,22)
  $form.Controls.Add($auto)
  $auto.Add_Click({
    if(!$auto.Checked){return}
    $answer=[System.Windows.Forms.MessageBox]::Show(
      "Automatic mode puts the unlock first and Windows second, and turns Fast Startup off.`r`n`r`nContinue?",
      'Automatic boot','YesNo','Question')
    if($answer -ne 'Yes'){$auto.Checked=$false;return}
    & $run 'Activate automatic' { Invoke-Activate -Automatic } -NeedsAdmin
  })
  [void](New-ActionButton 'DEACTIVATE' 452 100 {
    $answer=[System.Windows.Forms.MessageBox]::Show(
      "Remove the boot entry and restore the previous order?`r`n`r`nImages stay on the unlock partition and a full power-off returns the card to factory state.",
      'Deactivate','YesNo','Question')
    if($answer -eq 'Yes'){ & $run 'Deactivate' { Invoke-Deactivate } -NeedsAdmin }
  })
  [void](New-ActionButton 'LOGS' 560 88 {
    try{Start-Process explorer.exe (Join-Path (Target) $logDir)}catch{$out.AppendText(('ERROR: '+$_.Exception.Message)+"`r`n")}
  })
  [void](New-ActionButton 'HELP' 656 84 {
    try{Start-Process (Join-Path $repo 'docs/USER-GUIDE.es.md')}catch{$out.AppendText(('ERROR: '+$_.Exception.Message)+"`r`n")}
  })

  $foot=New-Object System.Windows.Forms.Label
  $foot.Location=New-Object System.Drawing.Point(20,572)
  $foot.Size=New-Object System.Drawing.Size(720,18)
  $foot.ForeColor=[System.Drawing.Color]::FromArgb(90,90,90)
  $foot.Text='The unlock lives in the GPU firmware RAM only: a full power-off returns the card to factory state.'
  $form.Controls.Add($foot)

  if($SelfCheck){
    $buttons=@($form.Controls | Where-Object {$_ -is [System.Windows.Forms.Button]})
    $names=@($buttons | ForEach-Object {$_.Text})
    if($buttons.Count -ne 6 -or $names -notcontains 'VERIFY' -or $names -notcontains 'ACTIVATE' -or $names -notcontains 'DEACTIVATE'){throw ('GUI self-check failed: buttons '+($names -join ','))}
    if(!$out.Multiline -or !$out.ReadOnly){throw 'GUI self-check failed: output box'}
    & $refresh
    if($values[0].Text -notmatch 'BIOS'){throw 'GUI self-check failed: status rows were not filled'}
    if($badge.Text -eq 'CHECKING'){throw 'GUI self-check failed: the badge was never updated'}
    Write-Output ('GUI OK ('+$badge.Text+')')
    $form.Dispose()
    return
  }

  $form.Add_Shown({
    & $refresh
    if($StartAction){
      switch($StartAction){
        'Verify'    { & $run 'Verify' { Invoke-Verify } }
        'Measure'   { & $run 'Measure' { $b=Get-Benchmark; if($b){$state.Bench=$b; $b.Raw} } }
        'Activate'  { & $run 'Activate' { Invoke-Activate } -NeedsAdmin }
        'Automatic' { & $run 'Activate automatic' { Invoke-Activate -Automatic } -NeedsAdmin }
        'Deactivate'{ & $run 'Deactivate' { Invoke-Deactivate } -NeedsAdmin }
      }
    }
  })
  [void]$form.ShowDialog()
  $form.Dispose()
}

# --- dispatch ---------------------------------------------------------------

if($Gui){
  Show-GpuUnlockWindow
  return
}

if($Status){
  $s=Get-GpuUnlockStatus
  if($Json){$s | ConvertTo-Json -Depth 4; return}
  Write-Output (Format-Status $s)
  return
}

if($Verify){
  $script:LastVerify=$null
  Invoke-Verify
  if(!$script:LastVerify -or !$script:LastVerify.Ok){exit 1}
  return
}

if($Baseline){
  Invoke-Baseline
  return
}

if($Deactivate){
  Invoke-Deactivate
  return
}

Invoke-Activate -Automatic:$Automatic
