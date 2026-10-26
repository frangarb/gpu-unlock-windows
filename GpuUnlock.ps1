# SPDX-License-Identifier: GPL-2.0-only
#
# NVIDIA Ampere unlock for Windows - end-user tool for one reviewed machine.
#
#   .\GpuUnlock.ps1 -Gui           window: status, verify, baseline, activate,
#                                  deactivate, cold restart
#   .\GpuUnlock.ps1 -Status        one screen of state; no writes, no reboot
#   .\GpuUnlock.ps1 -Status -Json  the same state, machine-readable
#   .\GpuUnlock.ps1 -Verify        check this boot: did the unlock run and is
#                                  the card running at full tensor rate?
#   .\GpuUnlock.ps1 -Baseline      record the locked rate once, on a clean boot
#   .\GpuUnlock.ps1 -Activate      stage the images, add the firmware entry and
#                                  arm it for exactly the next start
#   .\GpuUnlock.ps1 -Activate -Automatic
#                                  also boot it automatically (turns Fast
#                                  Startup off)
#   .\GpuUnlock.ps1 -Restart       arm the next start and restart now
#   .\GpuUnlock.ps1 -Deactivate    remove the entry and restore the boot order
#
# Reading the unlock partition, changing the boot configuration and touching
# firmware NVRAM need an elevated shell; status and the tensor measurement do
# not. Every action that needs it says so instead of failing on a permission.
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
  [switch]$Restart,
  [switch]$SelfCheck,
  [ValidateSet('Verify','Measure','Baseline','Activate','Deactivate','Automatic','Restart')][string]$StartAction
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

# Usage errors exit 2 and print one line, like the runtime errors below.
function Fail([string]$Message){[Console]::Error.WriteLine('ERROR: '+$Message);exit 2}
if($Json -and !$Status){Fail '-Json only applies to -Status'}
if($SelfCheck -and !$Gui){Fail '-SelfCheck only applies to -Gui'}
if($StartAction -and !$Gui){Fail '-StartAction only applies to -Gui'}
$chosen=@($Activate,$Deactivate,$Verify,$Status,$Baseline | Where-Object {$_}).Count
if(!$Gui -and $chosen -ne 1 -and !($Restart -and $chosen -eq 0)){
  Fail 'Choose one action: -Gui, -Status, -Verify, -Baseline, -Activate, -Restart or -Deactivate'
}
if($Gui -and @($Activate,$Deactivate,$Verify,$Baseline | Where-Object {$_}).Count -gt 1){Fail 'Choose one action'}
if(!$Gui -and $Restart -and @($Status,$Verify,$Baseline,$Deactivate | Where-Object {$_}).Count){Fail '-Restart goes with -Activate or alone'}
if($Automatic -and !$Activate){Fail '-Automatic only applies to -Activate'}

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
# The ESP is hidden from normal users: without elevation Get-Volume returns an
# empty Path and the volume looks like the wrong partition. Say which it is.
function Test-AdminNeeded{
  if(!(Test-Admin)){throw 'Administrator rights are required to read the unlock partition: Windows hides it from normal users. Reopen as administrator (the window asks for it).'}
}
function Target{
  $cfg=Get-Content -LiteralPath (Join-Path $repo 'internal-boot/local-config.json') -Raw | ConvertFrom-Json
  $part=Get-Partition -DriveLetter $cfg.UnlockDriveLetter -ErrorAction SilentlyContinue
  $vol=$(if($part){$part | Get-Volume -ErrorAction SilentlyContinue})
  if(!$part -or !$vol -or $part.Guid -ne $cfg.UnlockPartitionGuid -or $part.IsSystem -or $part.GptType -ne '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -or $vol.FileSystem -ne 'FAT32' -or !$vol.Path){
    Test-AdminNeeded
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

# --- one-time boot (UEFI BootNext) ------------------------------------------
#
# BootNext is the firmware's own one-time slot: the next start runs that entry
# and the firmware deletes the variable, so the normal order and the F8 menu
# are untouched. It is read back after writing, which is what turns "the next
# start will unlock" into a fact instead of a hope.
if(-not ('GuUefi.Nvram' -as [type])){
  Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace GuUefi {
  public static class Nvram {
    const string Global = "{8be4df61-93ca-11d2-aa0d-00e098032b8c}";
    const uint SePrivilegeEnabled = 0x2;

    [StructLayout(LayoutKind.Sequential)]
    struct Luid { public uint Low; public int High; }

    [StructLayout(LayoutKind.Sequential)]
    struct TokenPrivileges { public uint Count; public Luid Privilege; public uint Attributes; }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern uint GetFirmwareEnvironmentVariableEx(string name, string guid, byte[] buffer, uint size, out uint attributes);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool SetFirmwareEnvironmentVariableEx(string name, string guid, byte[] data, uint size, uint attributes);

    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentProcess();

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool LookupPrivilegeValue(string system, string name, out Luid luid);

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TokenPrivileges state, uint length, IntPtr previous, IntPtr returnLength);

    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr handle);

    static void EnableFirmwarePrivilege() {
      IntPtr token;
      if (!OpenProcessToken(GetCurrentProcess(), 0x28, out token)) throw new Win32Exception(Marshal.GetLastWin32Error());
      try {
        Luid luid;
        if (!LookupPrivilegeValue(null, "SeSystemEnvironmentPrivilege", out luid)) throw new Win32Exception(Marshal.GetLastWin32Error());
        var state = new TokenPrivileges();
        state.Count = 1;
        state.Privilege = luid;
        state.Attributes = SePrivilegeEnabled;
        if (!AdjustTokenPrivileges(token, false, ref state, 0, IntPtr.Zero, IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());
        int error = Marshal.GetLastWin32Error();
        if (error != 0) throw new Win32Exception(error);
      } finally { CloseHandle(token); }
    }

    public static byte[] Read(string name) {
      EnableFirmwarePrivilege();
      var buffer = new byte[8192];
      uint attributes;
      uint size = GetFirmwareEnvironmentVariableEx(name, Global, buffer, (uint)buffer.Length, out attributes);
      if (size == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
      var data = new byte[size];
      Array.Copy(buffer, data, (int)size);
      return data;
    }

    public static void Write(string name, byte[] data) {
      EnableFirmwarePrivilege();
      uint size = data == null ? 0u : (uint)data.Length;
      if (!SetFirmwareEnvironmentVariableEx(name, Global, data, size, 0x7)) throw new Win32Exception(Marshal.GetLastWin32Error());
    }
  }
}
'@
}

# EFI_LOAD_OPTION: attributes (4), file path length (2), then the UTF-16
# description up to its NUL.
function Get-LoadOptionDescription([byte[]]$Data){
  if(!$Data -or $Data.Length -le 6){return ''}
  $text=[Text.Encoding]::Unicode.GetString($Data,6,$Data.Length-6)
  $nul=$text.IndexOf([char]0)
  if($nul -ge 0){return $text.Substring(0,$nul)}
  return $text
}
# Boot#### slots whose EFI load option carries exactly this description.
function Find-BootNumber([string]$Description){
  $order=[GuUefi.Nvram]::Read('BootOrder')
  $hits=@()
  for($i=0;$i+1 -lt $order.Length;$i+=2){
    $number=[BitConverter]::ToUInt16($order,$i)
    try{$data=[GuUefi.Nvram]::Read(('Boot{0:x4}' -f $number))}catch{continue}
    $text=Get-LoadOptionDescription $data
    if($text -ceq $Description -and $hits -notcontains $number){$hits+=$number}
  }
  return $hits
}
function Get-OneShot{
  try{$data=[GuUefi.Nvram]::Read('BootNext')}catch{return $null}
  if($data.Length -lt 2){return $null}
  return [int][BitConverter]::ToUInt16($data,0)
}
# A duplicate name makes the slot ambiguous; refuse instead of guessing.
# Firmware NVRAM can lag the BCD write by a moment, so the lookup is retried.
function Set-OneShot([string]$Id){
  if(!$Id){throw 'There is no unlock entry to boot'}
  $numbers=@()
  for($attempt=0;$attempt -lt 5 -and $numbers.Count -ne 1;$attempt++){
    if($attempt){Start-Sleep -Milliseconds 300}
    try{$numbers=@(Find-BootNumber $entryName)}
    catch{throw ('Cannot read the firmware boot entries ('+$_.Exception.GetBaseException().Message+'); use the F8 menu once.')}
  }
  if($numbers.Count -ne 1){throw ('Expected exactly one firmware entry named "{0}" and found {1}; use the F8 menu once.' -f $entryName,$numbers.Count)}
  try{[GuUefi.Nvram]::Write('BootNext',[BitConverter]::GetBytes([uint16]$numbers[0]))}
  catch{throw ('The firmware refused the one-time boot slot ('+$_.Exception.GetBaseException().Message+'); use the F8 menu once.')}
  $armed=Get-OneShot
  if($armed -ne $numbers[0]){throw ('The firmware did not keep the one-time boot slot (it reads back {0}); use the F8 menu once.' -f $armed)}
  return $numbers[0]
}
function Clear-OneShot{
  try{if($null -ne (Get-OneShot)){[GuUefi.Nvram]::Write('BootNext',$null)}}catch{}
}
function Test-OneShotPending{
  try{
    $numbers=@(Find-BootNumber $entryName)
    if($numbers.Count -ne 1){return $null}
    return ((Get-OneShot) -eq $numbers[0])
  }catch{return $null}
}

# --- read-only state, measurement and baseline -----------------------------

function Test-Admin{
  $id=[Security.Principal.WindowsIdentity]::GetCurrent()
  return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function AssertAdmin([string]$What){
  if(!(Test-Admin)){throw ('Administrator rights are required to '+$What+'. Run this in an elevated PowerShell, or let the window ask for it.')}
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
  $admin=Test-Admin
  $board=(Get-CimInstance Win32_BaseBoard).Product
  $bios=(Get-CimInstance Win32_BIOS).SMBIOSBIOSVersion
  $gpu=@(Get-CimInstance Win32_PnPEntity | Where-Object {$_.DeviceID -match '^PCI\\VEN_10DE&DEV_2504'})
  try{$secureBoot=Confirm-SecureBootUEFI}catch{$secureBoot=$null}
  $id=$null
  $order=@()
  $entryLast=$false
  $entryKnown=$false
  try{
    $id=EntryId
    $order=Order (Bcd @('/enum','{fwbootmgr}'))
    $entryLast=($id -and $order.Count -gt 0 -and $order[-1] -eq $id)
    $entryKnown=$true
  }catch{$id=$null}
  $last=$null
  $final=''
  $logs=0
  $partitionError=''
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
  }catch{$partitionError=$_.Exception.Message}
  $oneShot=$(if($admin){Test-OneShotPending}else{$null})
  $runOk=[bool]($last -and (Get-Content -LiteralPath $last.FullName -Raw) -match 'original-unlock-return status=0x0000000000000000' -and $final -match 'stage=transaction' -and $final -match 'attempted=1')
  $baseline=Read-Baseline
  return [pscustomobject]@{
    Machine=$board
    Bios=$bios
    MachineOk=($board -eq 'B450M-HDV R4.0' -and $bios -eq 'P10.60')
    Gpu=$(if($gpu.Count){$gpu[0].Name}else{''})
    GpuOk=($gpu.Count -eq 1)
    SecureBoot=$secureBoot
    Admin=$admin
    EntryRegistered=[bool]$id
    EntryId=$id
    EntryKnown=$entryKnown
    EntryLast=$entryLast
    Automatic=[bool]($id -and $order.Count -gt 0 -and $order[0] -eq $id)
    OneShot=$oneShot
    PartitionError=$partitionError
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
  $sb=$(if($S.SecureBoot -eq $true){'ON (the unsigned EFI cannot run)'}elseif($S.SecureBoot -eq $false){'off'}else{'unknown (needs administrator)'})
  $entry=$(if($S.EntryRegistered){$S.EntryId+' last in the F8 menu'}else{'not registered'})
  if($S.EntryRegistered -and !$S.EntryLast){$entry=$S.EntryId+' registered, not last in the F8 menu'}
  if($S.Automatic){$entry=$S.EntryId+' automatic (first, Windows second)'}
  if(!$S.EntryKnown){$entry='unknown (needs administrator)'}
  $run=$(if($S.LastLog){$S.LastLog+' at '+$S.LastLogTime}else{'never ran here'})
  if($S.Stage){$run=$run+' - stage='+$S.Stage+' attempted='+([int]$S.Attempted)}
  $base=$(if($S.BaselineFp16){(('{0:N1} TFLOPS recorded at {1}' -f $S.BaselineFp16,$S.BaselineUtc))}else{'not recorded (run -Baseline on a clean boot)'})
  $next=$(if($S.OneShot -eq $true){'armed: the next start unlocks once, then Windows'}elseif($S.OneShot -eq $false){'Windows as usual (activate to arm it)'}else{'unknown (needs administrator)'})
  $logs=$(if(!$S.PartitionError){$S.Logs+' on the unlock partition'}elseif(!$S.Admin){'needs administrator'}else{'not read: '+$S.PartitionError})
  $lines=@(
    ('machine:     {0} BIOS {1} {2}' -f $S.Machine,$S.Bios,$(if($S.MachineOk){'(supported)'}else{'(NOT the reviewed machine)'})),
    ('gpu:         {0} {1}' -f $(if($S.Gpu){$S.Gpu}else{'10de:2504 not found'}),$(if($S.GpuOk){'(supported)'}else{'(check the card)'})),
    ('secure boot: '+$sb),
    ('admin:       '+$(if($S.Admin){'yes'}else{'no - reading the partition and changing boot need it'})),
    ('entry:       '+$entry),
    ('next start:  '+$next),
    ('last run:    '+$run),
    ('logs:        '+$logs),
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
    if((Test-OneShotPending) -eq $true){Write-Output 'The next start is already armed: restart this PC to run the unlock.'}
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
  AssertAdmin ('save the baseline in '+$stateDir)
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
    Source='measured'
    MeasuredUtc=$now.ToString('o')
    BootUtc=((Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o'))
  } | ConvertTo-Json | Set-Content -LiteralPath $baselineFile -Encoding utf8
  Write-Output ('baseline recorded: {0:N2} TFLOPS FP16, {1:N2} TF32 ({2})' -f $bench.Fp16,$bench.Tf32,$baselineFile)
  Write-Output 'Boot the unlock entry and run -Verify to see the measured gain.'
}

# A hand-entered reference: the same shape, marked so it is never mistaken for
# a measurement of this machine.
function Save-BaselineValue([double]$Fp16){
  AssertAdmin ('save the baseline in '+$stateDir)
  if($Fp16 -le 0){throw 'The baseline must be a positive number of TFLOPS'}
  [void][IO.Directory]::CreateDirectory($stateDir)
  [ordered]@{
    Gpu='NVIDIA GeForce RTX 3060 12GB (10de:2504)'
    Fp16=[math]::Round($Fp16,2)
    Tf32=$null
    Fp32=$null
    N=$benchN
    Reps=$benchReps
    Source='manual'
    MeasuredUtc=((Get-Date).ToUniversalTime().ToString('o'))
    BootUtc=''
  } | ConvertTo-Json | Set-Content -LiteralPath $baselineFile -Encoding utf8
  Write-Output ('baseline set by hand: {0:N2} TFLOPS FP16 ({1})' -f $Fp16,$baselineFile)
}
function Remove-Baseline{
  AssertAdmin 'remove the baseline'
  if(!(Test-Path -LiteralPath $baselineFile)){Write-Output 'No baseline is recorded.';return}
  Remove-Item -LiteralPath $baselineFile -Force
  Write-Output 'Baseline removed; -Verify and the window report the measured rate without a reference.'
}

# --- mutations -------------------------------------------------------------

# Arms the firmware's one-time slot and turns Fast Startup off: a hybrid
# shutdown resumes the old session with the card already initialised, so the
# start that runs the unlock has to be a full one.
function Invoke-ArmNextBoot{
  AssertAdmin 'arm the next start'
  $id=EntryId
  if(!$id){throw 'No unlock entry is registered: run -Activate first'}
  $number=Set-OneShot $id
  $state=LoadState
  if(!$state){
    $state=[ordered]@{EntryId=$id;Path=$entryPath;BootOrderBefore=(Order (Bcd @('/enum','{fwbootmgr}')));HiberbootBefore=(ReadHiber);Mode='one-shot';HardwareTested=$true}
  } else {
    if(!($state.PSObject.Properties.Name -contains 'HiberbootBefore')){$state|Add-Member -NotePropertyName HiberbootBefore -NotePropertyValue (ReadHiber)}
    $state.Mode='one-shot'
  }
  SetHiber @{Exists=$true;Value=0}
  SaveState $state
  return $number
}
function Invoke-RestartNow([int]$Seconds=20){
  Write-Output ('Restarting in {0} seconds: the next start runs the unlock before Windows.' -f $Seconds)
  Write-Output 'Save your work now. To cancel: shutdown /a'
  & shutdown.exe /r /t $Seconds /c 'Cold start for the NVIDIA Ampere unlock'
  if($LASTEXITCODE -ne 0){throw ('The restart request failed (exit {0}); restart the PC yourself when you are ready.' -f $LASTEXITCODE)}
}

function Invoke-Deactivate{
  AssertAdmin 'remove the unlock entry'
  AssertMachine
  $root=Target
  $id=EntryId
  if(!$id){Write-Output 'No unlock entry is registered; nothing to remove.';return}
  $before=Bcd @('/enum','{fwbootmgr}')
  $order=Order $before
  $state=LoadState
  Clear-OneShot
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
  $script:LastActivate=$false
  AssertAdmin 'register the unlock entry'
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

  $script:LastActivate=$true
  Write-Output ''
  if(!$Automatic){
    # Registered at the end of the F8 menu above; the one-time slot is what
    # makes the next start run it without touching any menu.
    try{
      $script:OneShotNumber=Invoke-ArmNextBoot
      $script:OneShotArmed=$true
      Write-Output ('Next start is armed: the firmware runs "{0}" once, then Windows as usual.' -f $entryName)
      Write-Output 'Fast Startup is off so that start is a full boot; the entry is still in F8.'
    } catch {
      $script:OneShotArmed=$false
      Write-Output ('Could not arm the next start: '+$_.Exception.Message)
      Write-Output 'Use the F8 menu once: restart, press F8 and pick the entry above.'
    }
  } else {
    Write-Output 'Next: restart. Every start runs the unlock before Windows, with no menu.'
  }
  Write-Output 'The screen goes dark after the release; Windows brings the card back.'
  Write-Output 'Then run: .\GpuUnlock.ps1 -Verify'
  Write-Output 'To undo everything: .\GpuUnlock.ps1 -Deactivate  (and a full power-off)'
}

# --- window ----------------------------------------------------------------

# UAC's "no" is an answer, not a failure: ERROR_CANCELLED is 1223 and its
# HRESULT is 0x800704C7, both independent of the display language.
function Test-ElevationCancelled([Exception]$Exception){
  foreach($e in @($Exception,$Exception.InnerException)){
    if(!$e){continue}
    if(($e -is [System.ComponentModel.Win32Exception]) -and ([int]$e.NativeErrorCode -eq 1223)){return $true}
    if([int]$e.HResult -eq -2147023673){return $true}
  }
  return ($Exception.Message -match '(?i)cancel|anul')
}
# Returns $false when the user refuses elevation and never throws for it.
function Restart-Elevated([string]$Action){
  $file=Join-Path $PSHOME 'powershell.exe'
  if(!(Test-Path -LiteralPath $file)){$file='powershell.exe'}
  $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-Gui')
  if($Action){$arguments+=@('-StartAction',$Action)}
  try{Start-Process -FilePath $file -Verb RunAs -ArgumentList $arguments; return $true}
  catch{if(Test-ElevationCancelled $_.Exception){return $false};throw}
}

function Show-GpuUnlockWindow{
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  [void][System.Windows.Forms.Application]::EnableVisualStyles()

  # The frame below is written in 96-DPI pixels. The desktop DPI is read once
  # and every control is scaled from it after the layout is built, so 125 % and
  # 150 % keep the proportions instead of clipping the text.
  $screen=[System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
  $uiScale=[double]$screen.DpiX/96.0
  $screen.Dispose()
  function Resize-Tree($Parent,[double]$Scale){
    foreach($child in $Parent.Controls){
      $child.Location=[System.Drawing.Point]::new([int][math]::Round($child.Left*$Scale),[int][math]::Round($child.Top*$Scale))
      $child.Size=[System.Drawing.Size]::new([int][math]::Round($child.Width*$Scale),[int][math]::Round($child.Height*$Scale))
      if($child.Controls.Count){Resize-Tree $child $Scale}
    }
  }

  $admin=Test-Admin
  $state=@{Bench=$null;SelfCheck=$SelfCheck}

  $form=New-Object System.Windows.Forms.Form
  $form.Text='NVIDIA Ampere Unlock - RTX 3060'
  $form.ClientSize=New-Object System.Drawing.Size(760,640)
  $form.AutoScaleMode='None'
  $form.StartPosition='CenterScreen'
  $form.FormBorderStyle='FixedSingle'
  $form.MaximizeBox=$false
  $form.Font=New-Object System.Drawing.Font('Segoe UI',9)
  $form.BackColor=[System.Drawing.Color]::FromArgb(35,39,46)
  $form.ForeColor=[System.Drawing.Color]::FromArgb(238,241,245)

  $badge=New-Object System.Windows.Forms.Label
  $badge.Location=New-Object System.Drawing.Point(20,14)
  $badge.Size=New-Object System.Drawing.Size(720,46)
  $badge.TextAlign='MiddleCenter'
  $badge.Font=New-Object System.Drawing.Font('Segoe UI',16,[System.Drawing.FontStyle]::Bold)
  $badge.Text='CHECKING'
  $form.Controls.Add($badge)

  # Dark grey canvas with bright text: every colour below clears 4.9:1 on the
  # surface and the hues stay saturated instead of muddy.
  $plain=[System.Drawing.Color]::FromArgb(238,241,245)   # 13.2:1
  $caption=[System.Drawing.Color]::FromArgb(174,185,198) # 7.5:1
  $good=[System.Drawing.Color]::FromArgb(91,224,143)     # 8.9:1
  $bad=[System.Drawing.Color]::FromArgb(255,138,138)     # 6.4:1
  $warn=[System.Drawing.Color]::FromArgb(255,196,107)    # 9.5:1
  $quiet=[System.Drawing.Color]::FromArgb(152,162,176)   # 5.8:1
  $buttonFace=[System.Drawing.Color]::FromArgb(51,58,68)
  $buttonEdge=[System.Drawing.Color]::FromArgb(107,118,134)
  $badgeGood=[System.Drawing.Color]::FromArgb(30,122,70)
  $badgeBad=[System.Drawing.Color]::FromArgb(179,32,32)
  $badgeSlate=[System.Drawing.Color]::FromArgb(57,65,76)
  $badgeIdle=[System.Drawing.Color]::FromArgb(57,65,76)
  $badgeIdleText=[System.Drawing.Color]::FromArgb(238,241,245)
  $badge.BackColor=$badgeIdle
  $badge.ForeColor=$badgeIdleText

  $captions=@('Machine','GPU','Secure Boot','Administrator','Boot entry','Next start','Last attempt','Transaction','Tensor rate')
  $values=@()
  for($i=0;$i -lt $captions.Count;$i++){
    $key=New-Object System.Windows.Forms.Label
    $key.Text=$captions[$i]
    $key.Location=New-Object System.Drawing.Point(20,(72+($i*24)))
    $key.Size=New-Object System.Drawing.Size(120,20)
    $key.Font=New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Bold)
    $key.ForeColor=$caption
    $form.Controls.Add($key)
    $v=New-Object System.Windows.Forms.Label
    $v.Location=New-Object System.Drawing.Point(145,(72+($i*24)))
    $v.Size=New-Object System.Drawing.Size(600,20)
    $v.ForeColor=$plain
    $v.Font=New-Object System.Drawing.Font('Segoe UI',9.75)
    $v.BackColor=[System.Drawing.Color]::Transparent
    $form.Controls.Add($v)
    $values+=$v
  }

  $banner=New-Object System.Windows.Forms.Label
  $banner.Location=New-Object System.Drawing.Point(20,368)
  $banner.Size=New-Object System.Drawing.Size(720,22)
  $banner.ForeColor=$warn
  $banner.Font=New-Object System.Drawing.Font('Segoe UI',9.75)
  $banner.Text=$(if($admin){''}else{'Not elevated: everything except MEASURE asks for administrator.'})
  $form.Controls.Add($banner)

  $out=New-Object System.Windows.Forms.TextBox
  $out.Location=New-Object System.Drawing.Point(20,394)
  $out.Size=New-Object System.Drawing.Size(720,196)
  $out.Multiline=$true
  $out.ReadOnly=$true
  $out.ScrollBars='Vertical'
  $out.WordWrap=$false
  $out.Font=New-Object System.Drawing.Font('Consolas',9)
  $out.BackColor=[System.Drawing.Color]::FromArgb(27,31,37)
  $out.ForeColor=[System.Drawing.Color]::FromArgb(232,236,242)
  $out.Text='Press VERIFY to read the last run and measure the card.'
  $form.Controls.Add($out)

  $refresh={
    if($script:LastVerify -and $script:LastVerify.Bench -and $script:LastVerify.Bench.Fp16 -gt 0){$state.Bench=$script:LastVerify.Bench}
    $s=Get-GpuUnlockStatus
    $values[0].Text=('{0} - BIOS {1}{2}' -f $s.Machine,$s.Bios,$(if($s.MachineOk){''}else{'  (NOT the reviewed machine)'}))
    $values[0].ForeColor=$(if($s.MachineOk){$plain}else{$bad})
    $values[1].Text=('{0}{1}' -f $(if($s.Gpu){$s.Gpu}else{'10de:2504 not found'}),$(if($s.GpuOk){'  (10de:2504)'}else{'  (check the card)'}))
    $values[1].ForeColor=$(if($s.GpuOk){$plain}else{$bad})
    # Off is what this EFI needs; on is the one thing that stops it.
    $values[2].Text=$(if($s.SecureBoot -eq $true){'ON - blocks this unsigned EFI; turn it off in firmware'}elseif($s.SecureBoot -eq $false){'off - this EFI can run'}else{'unknown - needs administrator'})
    $values[2].ForeColor=$(if($s.SecureBoot -eq $true){$bad}elseif($s.SecureBoot -eq $false){$good}else{$warn})
    $values[3].Text=$(if($s.Admin){'yes'}else{'no - reading the partition and changing boot need it'})
    $values[3].ForeColor=$(if($s.Admin){$plain}else{$warn})
    if(!$s.EntryKnown){$values[4].Text='unknown - needs administrator';$values[4].ForeColor=$warn}
    elseif($s.Automatic){$values[4].Text=('{0}  automatic: first, Windows second' -f $s.EntryId);$values[4].ForeColor=$good}
    elseif($s.EntryRegistered){$values[4].Text=('{0}{1}' -f $s.EntryId,$(if($s.EntryLast){'  last in the F8 menu (manual)'}else{'  registered, not last in the F8 menu'}));$values[4].ForeColor=$plain}
    else{$values[4].Text='not registered';$values[4].ForeColor=$quiet}
    $values[5].Text=$(if($s.OneShot -eq $true){'armed: the unlock runs once, then Windows'}elseif($s.OneShot -eq $false){'Windows as usual - ACTIVATE arms it'}else{'unknown - needs administrator'})
    $values[5].ForeColor=$(if($s.OneShot -eq $true){$good}elseif($s.OneShot -eq $false){$quiet}else{$warn})
    $values[6].Text=$(if($s.LastLog){'{0} at {1}' -f $s.LastLog,$s.LastLogTime}else{'never ran on this machine'})
    $values[6].ForeColor=$(if($s.LastLog){$plain}else{$quiet})
    $values[7].Text=$(if($s.Stage){'stage={0}  attempted={1}' -f $s.Stage,[int]$s.Attempted}else{'no report yet'})
    $values[7].ForeColor=$(if(!$s.Stage){$quiet}elseif($s.RunOk){$good}else{$bad})
    if($state.Bench -and $state.Bench.Fp16 -gt 0){
      $text=('{0:N1} TFLOPS FP16 / {1:N1} TF32' -f $state.Bench.Fp16,$state.Bench.Tf32)
      if($s.BaselineFp16 -gt 0){$text+=(('   ({0:+0;-0}% vs baseline {1:N1})' -f ((($state.Bench.Fp16/$s.BaselineFp16)-1)*100),$s.BaselineFp16))}
      elseif(!$s.RunOk){}else{$text+='   (no baseline yet: press BASELINE on a clean boot)'}
      $values[8].Text=$text
    } elseif($s.BaselineFp16){
      $values[8].Text=('not measured this window   (baseline {0:N1} TFLOPS)' -f $s.BaselineFp16)
    } else {
      $values[8].Text='not measured yet'
    }
    $verdict=$(if($state.Bench){Get-UnlockVerdict $state.Bench.Fp16}else{'unknown'})
    if($verdict -eq 'unlocked'){
      $badge.Text='UNLOCKED - full tensor rate'
      $badge.BackColor=$badgeGood
      $badge.ForeColor=[System.Drawing.Color]::White
    } elseif($verdict -eq 'locked'){
      $badge.Text='LOCKED - GeForce tensor rate'
      $badge.BackColor=$badgeBad
      $badge.ForeColor=[System.Drawing.Color]::White
    } elseif($s.RunOk){
      $badge.Text='NOT MEASURED - the transaction completed on the last run'
      $badge.BackColor=$badgeSlate
      $badge.ForeColor=[System.Drawing.Color]::White
    } else {
      $badge.Text='UNKNOWN - verify to measure'
      $badge.BackColor=$badgeIdle
      $badge.ForeColor=$badgeIdleText
    }
    $values[8].ForeColor=$(if($verdict -eq 'unlocked'){$good}elseif($verdict -eq 'locked'){$bad}else{$quiet})
    $restartHint.Text=$(if($s.OneShot -eq $true){'Armed: restart now and the unlock runs before Windows.'}elseif($s.EntryRegistered){'Arms the next start and restarts it, so no F8 and no firmware menu.'}else{'Activate first: there is no entry to boot.'})
    $restartHint.ForeColor=$(if($s.OneShot -eq $true){$good}elseif($s.EntryRegistered){$plain}else{$quiet})
  }

  # Every message the window shows goes through here, so no code path can fall
  # through to the .NET crash dialog for a normal outcome.
  $note={
    param([string]$Text,[switch]$IsError)
    if($out.Text -eq 'Press VERIFY to read the last run and measure the card.'){$out.Text=''}
    if($out.Text.Length -and !$out.Text.EndsWith("`n")){$out.AppendText("`r`n")}
    $out.AppendText($Text+"`r`n")
    $out.SelectionStart=$out.Text.Length
    $out.ScrollToCaret()
    if($IsError){[Console]::Error.WriteLine($Text)}
  }
  $script:UiNote=$note
  # A refused UAC prompt keeps the window open with a one-line note; the
  # handler is the backstop for anything a click handler did not catch.
  [System.Windows.Forms.Application]::add_ThreadException({
    param($sender,$eventArgs)
    $message='ERROR: '+$eventArgs.Exception.Message
    if($script:UiNote){& $script:UiNote $message -IsError}else{[Console]::Error.WriteLine($message)}
  })

  $run={
    param([string]$Label,[scriptblock]$Action,[switch]$NeedsAdmin,[string]$ElevateAs)
    if($NeedsAdmin -and !$admin){
      try{
        if(Restart-Elevated $(if($ElevateAs){$ElevateAs}else{$Label})){$form.Close()}
        else{& $note ('Cancelled: administrator rights were refused, so nothing was changed. '+$Label+' needs them.')}
      } catch {& $note ('ERROR: '+$_.Exception.Message) -IsError}
      return
    }
    & $note ('== {0} ==' -f $Label)
    try{
      $text=(& $Action *>&1 | Out-String)
      if($text.Trim()){& $note $text.TrimEnd()}
    } catch {
      & $note ('ERROR: '+$_.Exception.Message) -IsError
    }
    & $refresh
  }

  # Flat buttons with a real border: the themed default is a pale grey shape on
  # a white form, which reads as disabled.
  function Set-FlatButton($Button){
    $Button.FlatStyle='Flat'
    $Button.BackColor=$buttonFace
    $Button.ForeColor=[System.Drawing.Color]::FromArgb(242,245,249)
    $Button.FlatAppearance.BorderColor=$buttonEdge
    $Button.FlatAppearance.BorderSize=1
    $Button.FlatAppearance.MouseOverBackColor=[System.Drawing.Color]::FromArgb(61,70,82)
    $Button.FlatAppearance.MouseDownBackColor=[System.Drawing.Color]::FromArgb(72,83,95)
  }
  function New-ActionButton([string]$Text,[int]$X,[int]$Width,[scriptblock]$OnClick){
    $b=New-Object System.Windows.Forms.Button
    $b.Text=$Text
    $b.Location=New-Object System.Drawing.Point($X,296)
    $b.Size=New-Object System.Drawing.Size($Width,28)
    $b.Add_Click($OnClick)
    Set-FlatButton $b
    $form.Controls.Add($b)
    return $b
  }

  # The baseline is configurable three ways: measure it here, keep a value
  # measured elsewhere, or forget it and go back to the measured rate alone.
  function New-BaselineDialog{
    $current=Read-Baseline
    $d=New-Object System.Windows.Forms.Form
    $d.Text='Baseline - locked reference rate'
    $d.ClientSize=New-Object System.Drawing.Size(470,196)
    $d.AutoScaleMode='None'
    $d.StartPosition='CenterParent'
    $d.FormBorderStyle='FixedDialog'
    $d.MaximizeBox=$false
    $d.MinimizeBox=$false
    $d.Font=$form.Font
    $d.BackColor=[System.Drawing.Color]::FromArgb(35,39,46)
    $d.ForeColor=$plain
    $info=New-Object System.Windows.Forms.Label
    $info.ForeColor=$plain
    $info.Location=New-Object System.Drawing.Point(14,12)
    $info.Size=New-Object System.Drawing.Size(440,66)
    $info.Text=$(if($current){('Recorded: {0:N2} TFLOPS FP16 ({1})' -f [double]$current.Fp16,(''+$current.MeasuredUtc).Substring(0,[Math]::Min(16,(''+$current.MeasuredUtc).Length)))}else{'No baseline yet. It is the locked rate of this card, measured once on a clean boot with the unlock entry not used.'})
    $d.Controls.Add($info)
    $label=New-Object System.Windows.Forms.Label
    $label.Location=New-Object System.Drawing.Point(14,78)
    $label.Size=New-Object System.Drawing.Size(200,18)
    $label.Text='Value by hand (TFLOPS FP16):'
    $label.Font=New-Object System.Drawing.Font('Segoe UI',8)
    $label.ForeColor=$caption
    $d.Controls.Add($label)
    $box=New-Object System.Windows.Forms.TextBox
    $box.Location=New-Object System.Drawing.Point(14,98)
    $box.Size=New-Object System.Drawing.Size(120,22)
    $box.BackColor=[System.Drawing.Color]::FromArgb(27,31,37)
    $box.ForeColor=[System.Drawing.Color]::FromArgb(232,236,242)
    $box.BorderStyle='FixedSingle'
    if($current){$box.Text=('{0}' -f [double]$current.Fp16)}
    $d.Controls.Add($box)
    $d.Tag=@{Action=$null;Value=0.0}
    function New-DialogButton([string]$Text,[int]$X,[int]$Width,[scriptblock]$OnClick){
      $b=New-Object System.Windows.Forms.Button
      $b.Text=$Text
      $b.Location=New-Object System.Drawing.Point($X,142)
      $b.Size=New-Object System.Drawing.Size($Width,30)
      $b.Add_Click($OnClick)
      Set-FlatButton $b
      $d.Controls.Add($b)
    }
    New-DialogButton 'MEASURE NOW' 14 132 {$d.Tag=@{Action='measure'};$d.Close()}
    New-DialogButton 'SAVE VALUE' 152 116 {
      $text=$box.Text.Trim().Replace(',','.')
      [double]$value=0
      if(![double]::TryParse($text,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$value) -or $value -le 0){
        [void][System.Windows.Forms.MessageBox]::Show('Enter the locked rate in TFLOPS, for example 24.8.','Baseline','OK','Warning')
        return
      }
      $d.Tag=@{Action='save';Value=$value};$d.Close()
    }
    New-DialogButton 'FORGET' 274 88 {$d.Tag=@{Action='forget'};$d.Close()}
    New-DialogButton 'CLOSE' 368 88 {$d.Close()}
    if([math]::Abs($uiScale-1) -gt 0.01){
      Resize-Tree $d $uiScale
      $d.ClientSize=[System.Drawing.Size]::new(
        [int][math]::Round($d.ClientSize.Width*$uiScale),
        [int][math]::Round($d.ClientSize.Height*$uiScale))
    }
    return $d
  }
  function Show-BaselineDialog{
    $d=New-BaselineDialog
    [void]$d.ShowDialog($form)
    $tag=$d.Tag
    $d.Dispose()
    return $tag
  }

  $baselineClick={
    try{
      if($admin){$pick=Show-BaselineDialog}else{$pick=@{Action='measure'}}
      if(!$pick -or !$pick.Action){return}
      switch($pick.Action){
        'measure'{ & $run 'Baseline' { Invoke-Baseline } -NeedsAdmin }
        'save'   { & $run 'Baseline (by hand)' { Save-BaselineValue $pick.Value } -NeedsAdmin -ElevateAs 'Baseline' }
        'forget' { & $run 'Baseline (forget)' { Remove-Baseline } -NeedsAdmin -ElevateAs 'Baseline' }
      }
    } catch {& $note ('ERROR: '+$_.Exception.Message) -IsError}
  }

  # After activation the next start runs the unlock once; the restart is the
  # only step a person still has to take, so it is offered right here.
  $restartFlow={
    $answer=[System.Windows.Forms.MessageBox]::Show(
      "Restart now?`r`n`r`nThe next start runs the unlock once, then Windows. Save your work: the restart is in 20 seconds (shutdown /a cancels).",
      'Restart now','YesNo','Question')
    if($answer -eq 'Yes'){ & $run 'Restart' { [void](Invoke-ArmNextBoot); Invoke-RestartNow } -NeedsAdmin }
  }

$verifyButton=New-ActionButton 'VERIFY' 20 96 { & $run 'Verify' { Invoke-Verify } -NeedsAdmin }
  $rule=New-Object System.Windows.Forms.Panel
  $rule.Location=New-Object System.Drawing.Point(20,288)
  $rule.Size=New-Object System.Drawing.Size(720,1)
  $rule.BackColor=[System.Drawing.Color]::FromArgb(74,84,97)
  $form.Controls.Add($rule)
  [void](New-ActionButton 'MEASURE' 122 80 { & $run 'Measure' { $b=Get-Benchmark; if(!$b){'Tensor benchmark not built; see docs/BENCHMARK.en.md'}else{$state.Bench=$b; $b.Raw; ('verdict: '+ (Get-UnlockVerdict $b.Fp16))} } })
  [void](New-ActionButton 'BASELINE' 208 96 { & $baselineClick })
  [void](New-ActionButton 'ACTIVATE' 310 88 {
    & $run 'Activate' { Invoke-Activate } -NeedsAdmin
    if($script:LastActivate){ & $restartFlow }
  })
  $auto=New-Object System.Windows.Forms.CheckBox
  $auto.Text='also automatic'
  $auto.Location=New-Object System.Drawing.Point(404,300)
  $auto.Size=New-Object System.Drawing.Size(110,22)
  $auto.ForeColor=$plain
  $auto.BackColor=$form.BackColor
  $form.Controls.Add($auto)
  $auto.Add_Click({
    if(!$auto.Checked){return}
    $answer=[System.Windows.Forms.MessageBox]::Show(
      "Automatic mode puts the unlock first and Windows second, and turns Fast Startup off.`r`n`r`nContinue?",
      'Automatic boot','YesNo','Question')
    if($answer -ne 'Yes'){$auto.Checked=$false;return}
    & $run 'Activate automatic' { Invoke-Activate -Automatic } -NeedsAdmin -ElevateAs 'Automatic'
  })
  [void](New-ActionButton 'DEACTIVATE' 520 92 {
    $answer=[System.Windows.Forms.MessageBox]::Show(
      "Remove the boot entry and restore the previous order?`r`n`r`nImages stay on the unlock partition and a full power-off returns the card to factory state.",
      'Deactivate','YesNo','Question')
    if($answer -eq 'Yes'){ & $run 'Deactivate' { Invoke-Deactivate } -NeedsAdmin }
  })
  [void](New-ActionButton 'LOGS' 618 60 {
    $dir=(DriveLetter)+':\'+$logDir
    try{
      if($admin){Start-Process explorer.exe $dir}
      else{Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile','-Command',("Start-Process explorer.exe '"+$dir+"'"))}
    } catch {
      if(Test-ElevationCancelled $_.Exception){& $note 'Cancelled: administrator rights were refused, the log folder stays closed.'}
      else{& $note ('ERROR: '+$_.Exception.Message) -IsError}
    }
  })
  [void](New-ActionButton 'HELP' 684 52 {
    try{Start-Process (Join-Path $repo 'docs/USER-GUIDE.es.md')}catch{$out.AppendText(('ERROR: '+$_.Exception.Message)+"`r`n")}
  })

  $restart=New-Object System.Windows.Forms.Button
  $restart.Text='RESTART FOR UNLOCK'
  $restart.Location=New-Object System.Drawing.Point(20,330)
  $restart.Size=New-Object System.Drawing.Size(160,30)
  $restart.Font=New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Bold)
  Set-FlatButton $restart
  # Left enabled on purpose: a disabled flat button draws its label in dark
  # grey, unreadable here, so the click itself says why it cannot run.
  $restart.Add_Click({
    try{if(!(EntryId)){& $note 'Nothing to restart for yet: press ACTIVATE first.';return}}catch{& $note ('ERROR: '+$_.Exception.Message) -IsError;return}
    $answer=[System.Windows.Forms.MessageBox]::Show(
      "Restart in 20 seconds with the unlock armed for this start?`r`n`r`nSave your work first: shutdown /a cancels.",
      'Restart for unlock','YesNo','Question')
    if($answer -eq 'Yes'){ & $run 'Restart' { [void](Invoke-ArmNextBoot); Invoke-RestartNow } -NeedsAdmin }
  })
  $form.Controls.Add($restart)

  $restartHint=New-Object System.Windows.Forms.Label
  $restartHint.Location=New-Object System.Drawing.Point(190,336)
  $restartHint.Size=New-Object System.Drawing.Size(550,20)
  $restartHint.ForeColor=$quiet
  $restartHint.Text='Activate first: there is no entry to boot.'
  $form.Controls.Add($restartHint)

  $foot=New-Object System.Windows.Forms.Label
  $foot.Location=New-Object System.Drawing.Point(20,600)
  $foot.Size=New-Object System.Drawing.Size(720,18)
  $foot.ForeColor=$quiet
  $foot.Text='The unlock lives in the GPU firmware RAM only: a full power-off returns the card to factory state.'
  $form.Controls.Add($foot)

  # Fonts are in points and grow with the DPI on their own; only the geometry
  # is scaled, once, after every control exists and before the window does.
  if([math]::Abs($uiScale-1) -gt 0.01){
    Resize-Tree $form $uiScale
    $form.ClientSize=[System.Drawing.Size]::new(
      [int][math]::Round($form.ClientSize.Width*$uiScale),
      [int][math]::Round($form.ClientSize.Height*$uiScale))
  }
  # A scaled-up fixed layout can still be taller than a small screen. The log
  # pane is the only flexible part, so take the height from it and keep the
  # footer under it; if the minimum log still does not fit, the window scrolls.
  $frame=[int][math]::Round(40*$uiScale)
  $work=[System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  if(($form.ClientSize.Height+$frame) -gt $work.Height){
    $over=($form.ClientSize.Height+$frame)-$work.Height
    $shrink=[math]::Min($over,[math]::Max(0,$out.Height-60))
    if($shrink -gt 0){
      $out.Height=$out.Height-$shrink
      $foot.Top=$out.Bottom+10
      $form.ClientSize=[System.Drawing.Size]::new($form.ClientSize.Width,$foot.Bottom+12)
    }
  }
  if((($form.ClientSize.Height+$frame) -gt $work.Height) -or ($form.ClientSize.Width -gt $work.Width)){
    $form.AutoScroll=$true
    $form.ClientSize=[System.Drawing.Size]::new(
      [math]::Min($form.ClientSize.Width,$work.Width-40),
      [math]::Min($form.ClientSize.Height,$work.Height-$frame-8))
  }

  if($SelfCheck){
    $buttons=@($form.Controls | Where-Object {$_ -is [System.Windows.Forms.Button]})
    $names=@($buttons | ForEach-Object {$_.Text})
    foreach($needed in @('VERIFY','MEASURE','BASELINE','ACTIVATE','DEACTIVATE','RESTART FOR UNLOCK','LOGS','HELP')){
      if($names -notcontains $needed){throw ('GUI self-check failed: missing '+$needed+' in '+($names -join ','))}
    }
    if($values.Count -ne 9){throw 'GUI self-check failed: status rows'}
    if(!$out.Multiline -or !$out.ReadOnly){throw 'GUI self-check failed: output box'}
    $dialog=New-BaselineDialog
    if($dialog.Controls.Count -lt 7){throw 'GUI self-check failed: baseline dialog'}
    $dialog.Dispose()
    # Offline check of the firmware load-option parse that finds the boot slot.
    $probe=[byte[]](0,0,0,0,0,0)+[Text.Encoding]::Unicode.GetBytes($entryName+[char]0)
    if((Get-LoadOptionDescription $probe) -cne $entryName){throw 'GUI self-check failed: firmware load-option parsing'}
    # A refused UAC prompt must read as a refusal, and nothing else must.
    if(!(Test-ElevationCancelled ([System.ComponentModel.Win32Exception]::new(1223)))){throw 'GUI self-check failed: refused elevation not recognised'}
    if(Test-ElevationCancelled ([System.Exception]::new('boom'))){throw 'GUI self-check failed: unrelated error read as refused elevation'}
    & $refresh
    if($values[0].Text -notmatch 'BIOS'){throw 'GUI self-check failed: status rows were not filled'}
    if($values[2].Text -notmatch 'off|ON|unknown'){throw 'GUI self-check failed: secure boot row'}
    if($badge.Text -eq 'CHECKING'){throw 'GUI self-check failed: the badge was never updated'}
    Write-Output ('GUI OK ('+$badge.Text+')')
    $form.Dispose()
    return
  }

  $form.Add_Shown({
    & $refresh
    $verifyButton.Focus()
    if($form.AutoScroll){$form.AutoScrollPosition=New-Object System.Drawing.Point(0,0)}
    if($StartAction){
      switch($StartAction){
        'Verify'    { & $run 'Verify' { Invoke-Verify } -NeedsAdmin }
        'Measure'   { & $run 'Measure' { $b=Get-Benchmark; if($b){$state.Bench=$b; $b.Raw} } }
        'Baseline'  { & $baselineClick }
        'Activate'  { & $run 'Activate' { Invoke-Activate } -NeedsAdmin; if($script:LastActivate){ & $restartFlow } }
        'Automatic' { & $run 'Activate automatic' { Invoke-Activate -Automatic } -NeedsAdmin }
        'Deactivate'{ & $run 'Deactivate' { Invoke-Deactivate } -NeedsAdmin }
        'Restart'   { & $run 'Restart' { [void](Invoke-ArmNextBoot); Invoke-RestartNow } -NeedsAdmin }
      }
    }
  })
  [void]$form.ShowDialog()
  $form.Dispose()
}

# --- dispatch ---------------------------------------------------------------

try{
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

if($Restart -and !$Activate){
  [void](Invoke-ArmNextBoot)
  Invoke-RestartNow
  return
}

Invoke-Activate -Automatic:$Automatic
if($Restart){Invoke-RestartNow}
elseif(![Console]::IsInputRedirected){
  $answer=Read-Host 'Restart now so the next start runs the unlock? [y/N]'
  if($answer -match '^(?i)(y|yes|s|si|sí)$'){Invoke-RestartNow}
}
} catch {
  # One clean line for the user, not a PowerShell stack trace.
  [Console]::Error.WriteLine('ERROR: '+$_.Exception.Message)
  exit 1
}
