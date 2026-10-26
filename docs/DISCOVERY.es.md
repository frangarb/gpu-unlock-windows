# Máquina sin perfil: captura de descubrimiento de sólo lectura

[English](DISCOVERY.en.md) | [Puertas de portabilidad](PORTABILITY.en.md) | [Internal boot](../internal-boot/README.md)

Este documento es la versión en español de [DISCOVERY.en.md](DISCOVERY.en.md) y
agrega el procedimiento concreto de partición que el documento en inglés deja a
[INTERNAL-BOOT.en.md](INTERNAL-BOOT.en.md). Los números de disco, tamaños y GUIDs
de la sección «Crear la ESP» fueron medidos en una máquina real y sirven como
ejemplo trabajado; verificalos en la tuya antes de ejecutar nada.

## Qué es y qué no es

Una compilación con capacidad de escritura compila exactamente un perfil revisado
([`machine-profile.h`](../internal-boot/unlock/machine-profile.h)). Una tarjeta
sin perfil — por ejemplo una RTX 3060 (GA106, `10de:2503`, `2504`, `2507`) — no
coincide con ningún perfil, así que `GuTargetConfig` y todos los chequeos de
identidad posteriores la rechazan y no hay transacción posible. El camino no es
aflojar esos chequeos sino **registrar** qué es la máquina.

El descubrimiento hace ese registro: compila una única aplicación EFI que lee el
equipo y escribe un archivo de texto, y se detiene. No escribe configuración PCI,
MMIO, NVRAM ni variables de firmware; no habilita bus mastering, no asigna DMA,
no resetea el dispositivo y no separa ningún driver. Tampoco tiene identidad de
tarjeta, placa ni display para comparar, de modo que no puede llegar a una
transacción ni por accidente: seleccionar el perfil en una compilación con
escritura es un `#error` en [`port.h`](../internal-boot/unlock/port.h).

## Antes de empezar

Todo esto es obligatorio:

- una partición EFI FAT32 dedicada de al menos 1 GiB que **no** sea la ESP de
  Windows (cómo crearla, abajo);
- Secure Boot desactivado (la imagen no está firmada);
- Inicio rápido e hibernación apagados (`powercfg /h off`), para que el encendido
  sea realmente frío;
- **BitLocker totalmente descifrado en `C:`**. Suspender la protección no alcanza:
  el paso de staging exige `VolumeStatus = 0` (FullyDecrypted) y
  `ProtectionStatus = 0`, y falla con cualquier volumen cifrado. Los scripts nunca
  cambian la configuración de cifrado.

Antes de tocar particiones, guardá la cadena de arranque:

```powershell
New-Item -ItemType Directory -Force C:\gpu-unlock-backup | Out-Null
bcdedit /export C:\gpu-unlock-backup\BCD-before
bcdedit /enum firmware > C:\gpu-unlock-backup\firmware-before.txt
```

## Crear la ESP de observación

Ejemplo medido (Windows 11 en el disco 2, GPT de 240 GB):

| Disco | Estado | Detalle |
|---|---|---|
| 2 | GPT, disco de Windows | ESP de 308 MB (`IsSystem`), `C:` 169,7 GB, recuperación de 0,92 GB pegada detrás, `I:` 52,6 GB con 0 GB libres |
| 1 | GPT, datos | ESP vieja de 0,29 GB (no sirve: <1 GiB), `E:` 229,7 GB con 77,4 GB libres, `F:`, `G:` |
| 0, 3 | MBR | No pueden alojar una ESP |

La partición de recuperación detrás de `C:` **no** impide encoger `C:`: el espacio
liberado queda en el hueco entre `C:` y la recuperación, que es una ubicación
válida para una partición nueva. Lo que sí impide es volver a extender `C:` después.

### Opción primaria: en el mismo disco que la ESP de Windows

Es la opción recomendada porque el firmware enumera con seguridad la ESP del disco
de arranque, así que la entrada aparece en el menú F8.

Si Disk Management muestra «0 MB disponibles» para encoger `C:`, hay tres causas
independientes y hay que atacar las tres:

1. **`hiberfil.sys`** — con hibernación activa (`HiberbootEnabled = 1`), ese archivo
   grande suele quedar al final del volumen y deja el espacio encogible en cero.
   `powercfg /h off` lo elimina y es un paso obligatorio igual.
2. **BitLocker** — sobre un volumen protegido el encogido falla o aparece bloqueado.
   Hay que descifrar (`Disable-BitLocker -MountPoint C:` y esperar
   `FullyDecrypted`), que además es requisito del staging.
3. **Archivos no movibles** — `pagefile.sys`, la MFT, instantáneas VSS. Si después
   de los dos pasos anteriores sigue faltando, mové el archivo de paginación a otro
   volumen y reiniciá.

Medido en esa máquina: no hay `hiberfil.sys` en `C:` y el archivo de paginación
(11,5 GB) vive en `E:`. De las tres causas, la que queda en pie es BitLocker.

```powershell
# Todo en una consola elevada: estos cmdlets devuelven «acceso denegado» sin elevación.
Confirm-SecureBootUEFI                                    # debe dar False
Get-BitLockerVolume -MountPoint C: | Select MountPoint,VolumeStatus,ProtectionStatus
powercfg /h off
# Espacio realmente encogible (lo que Disk Management muestra como «0 MB»):
$c = Get-Partition -DriveLetter C
[math]::Round(($c.Size - (Get-PartitionSupportedSize -DriveLetter C).SizeMin)/1MB)  # en MB
```

Si ese número es menor a ~2000 MB, resolvé pagefile/VSS antes de seguir: pedir un
`Resize-Partition` por debajo de `SizeMin` falla con «The parameter is incorrect» y
no cambia nada. Cuando haya lugar:

```powershell
$c = Get-Partition -DriveLetter C
Resize-Partition -DriveLetter C -Size ($c.Size - 1600MB)

$c = Get-Partition -DriveLetter C
$p = New-Partition -DiskNumber $c.DiskNumber -Offset ($c.Offset + $c.Size) -Size 1536MB
Set-Partition -DiskNumber $c.DiskNumber -PartitionNumber $p.PartitionNumber -NewDriveLetter U
Set-Partition -DriveLetter U -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
Format-Volume -DriveLetter U -FileSystem FAT32 -NewFileSystemLabel GPUUNLOCK -Confirm:$false
```

`-Offset` explícito evita que `New-Partition` elija otro hueco del disco. El
`GptType` se aplica **sólo** al volumen `U:` recién creado, nunca a la ESP de Windows.

### Alternativa: en otro disco GPT con espacio

Si `C:` no cede, encogé una partición de datos del disco 1 y creá ahí la ESP con
los mismos comandos cambiando `-DiskNumber`. En este ejemplo `E:` aloja el archivo
de paginación, así que su cola puede ser inamovible: elegí otra partición de datos
o mové el pagefile antes. Aviso: algunas placas sólo enumeran
la ESP del disco de arranque; si la entrada no aparece en F8, probá
`bcdedit /set {fwbootmgr} bootsequence <id>` (ver más abajo) o mové la partición a
un pendrive cuya partición sea una **ESP FAT32** (tipo GPT
`{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}`): un pendrive FAT32 común no cuenta.

En todos los casos, verificá antes de compilar:

```powershell
Get-Partition -DriveLetter U | Select DiskNumber,PartitionNumber,GptType,IsSystem,Size
Get-Volume -DriveLetter U | Select FileSystem,DriveType
```

Esperado: tipo `{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}`, `IsSystem False`,
`Size 1610612736`, `FAT32`. Ponerle letra a una ESP no cambia el arranque.

## Configurar y compilar

Desde la raíz del repositorio, con `clang` y `lld-link` en `PATH` (o pasando rutas
completas; algunas copias de trabajo los tienen en `.tools\llvm\bin`):

```powershell
$win = '<guid-de-la-esp-de-windows>'
Get-Partition | Where-Object IsSystem | Select DiskNumber,PartitionNumber,Guid,Size   # para obtenerlo

.\internal-boot\Configure.ps1 -UnlockDriveLetter U -WindowsEspGuid $win -HardwareProfile discovery
.\research\headless\build-observe.ps1 -UnlockDriveLetter U -WindowsEspGuid $win `
  -Clang <clang> -LldLink <lld-link> -HardwareProfile discovery
```

`Configure` sólo escribe `internal-boot\boot\platform-config.h` y
`local-config.json` (ambos ignorados por git). El segundo comando vuelve a correr
Configure, compila, verifica el PE y copia `OBSERVE.EFI`. Comprobá:

```powershell
Get-Content .\research\headless\build\manifest.json | Select-String 'CanUnlock|HardwareProfile|EfiSha256'
Get-Content .\internal-boot\local-config.json
```

Esperado: `CanUnlock: false`, `HardwareProfile: discovery`,
`ProfileName: DISCOVERY-READ-ONLY`. No copies a mano un `DIAGNOSTIC.EFI` compilado
antes de `Configure`: contendría GUIDs de partición de relleno.

## Staging y registro

```powershell
.\research\headless\register-observe.ps1            # sólo copia OBSERVE.EFI
.\research\headless\register-observe.ps1 -Register  # agrega la entrada de firmware
```

Sin switches se elige el modo observación; `-HeadlessUnlock` y `-ConsoleR2` son
otros modos y no corresponden acá. El staging imprime
`Observation EFI staged only; no boot entry/order changes.` y deja
`U:\EFI\WindowsGPUUnlock\OBSERVE.EFI`. También crea `U:\RTX3090-UNLOCK`, donde el
EFI escribe su log: FAT32 no puede crear un archivo dentro de un directorio que
no existe, así que sin ese directorio el EFI sale sin escribir nada.

El registro exporta el BCD a `C:\ProgramData\WindowsGPUUnlock\ResearchBackups\<fecha>\`,
copia `{bootmgr}` en una entrada nueva «GPU Discovery Observe - NO UNLOCK», la
agrega al **final** de `{fwbootmgr} displayorder`, verifica que cada entrada previa
quede byte-idéntica y escribe `research\headless\registration.local.json`. No pone
`BootNext`, no reordena el arranque y no reinicia. Se niega si ya existe un estado
de registro: no lo corras dos veces sin borrar el anterior.

```powershell
bcdedit /enum firmware
Get-Content .\research\headless\registration.local.json
```

La primera entrada debe seguir siendo Windows Boot Manager y la nueva estar última.

## Capturar

```powershell
shutdown /s /t 0
```

Apagado real, no reinicio. Encendé, apretá **F8** (ASUS) y elegí la última entrada,
«GPU Discovery Observe - NO UNLOCK». Captura y **arranca Windows solo**
(`graph-capture-then-normal-windows` encadena `bootmgfw.efi` de la ESP de Windows).
No cortes la energía durante unos 15 segundos.

## Traer y validar el archivo

```powershell
Get-ChildItem U:\RTX3090-UNLOCK
Select-String -Path U:\RTX3090-UNLOCK\DIAG00.TXT -Pattern 'capture-complete=','probe targets=','probe-target seg=','prom sha256='
```

Tiene que haber exactamente un `capture-complete=1`, un `probe targets=0001` y un
`probe-target seg=0x...`. Si ves `probe targets=0000`, el sondeo no encontró ninguna
función NVIDIA de display (CSM activo o BAR0 deshabilitada en el firmware): no sigas
hasta arreglar eso. El directorio se llama `RTX3090-UNLOCK` por historia del
proyecto; no implica que la captura sea de un 3090.

## Convertirlo en borrador de perfil

```powershell
# El nombre sale de `Board` y `Bios` en internal-boot/local-config.json (SMBIOS),
# nunca de memoria: un perfil es el contrato de UNA máquina y el nombre lo declara.
python .\tools\derive_profile.py --capture U:\RTX3090-UNLOCK\DIAG00.TXT `
  --name ASROCK-B450M-HDV-R4.0-P10.60-RTX3060 `
  --define GU_PROFILE_ASROCK_B450M_HDV_R4_0_RTX3060 `
  --output .\evidence\discovery-rtx3060\draft.json
```

El borrador no se sobrescribe (`--output` crea el archivo): borralo antes de
volver a derivar.

Devuelve los valores que la captura puede probar (`GU_BOARD_ID`,
`GU_BOARD_SUBSYSTEM`, `GU_BAR0_BASE/END`, `GU_CHIP_ID`, `GU_DEVICE_MEMORY_SIZE`,
`GU_PROM_SHA256`, `GU_ROOT_PORT_*`, `GU_RTX_PATH_BYTES`) y sale con
`"authorizes_unlock": false`. Rechaza capturas incompletas o múltiples, cero o
varias GPUs candidatas, BAR0 de 64 bits o sin dirección, PROM ilegible y registros
faltantes. Las huellas de display salen de la captura y de los volcados, con
`tools/derive_display.py` (abajo); las de un agente que esta máquina no carga
siguen siendo trabajo manual antes de que el borrador pueda pasar a perfil con
escritura (etapa 4 de [PORTABILITY.en.md](PORTABILITY.en.md)).

## Huellas de display

```powershell
python .\tools\derive_display.py --capture U:\RTX3090-UNLOCK\DIAG00.TXT `
  --images U:\RTX3090-UNLOCK `
  --agent GU_NVGOP=name:nvgop-ga1xx `
  --agent GU_EDID=guid:c7a7030c-c3d8-45ee-bed9-5d9e76762953
```

Cada binding de driver registra su versión, tamaño de imagen, dirección de stop
y device path (un nombre de archivo o el GUID de archivo de un volumen de
firmware); el sondeo deja la imagen cargada junto a la captura. La herramienta
cruza ambos y devuelve la sección `.text` que declara el propio header PE de la
imagen — el mismo rango que hashea el gate de liberación en `0x280` (nvgop) y
`0x1000` (driver EDID). Rechaza un selector que no case con ningún agente o con
varios, una captura que se saltó el volcado, un volcado cuyo tamaño no coincide
y un rango de código fuera de la imagen; está cubierto en
[`tools/test_derive_display.py`](../tools/test_derive_display.py).

## Deshacer

```powershell
$s = Get-Content .\research\headless\registration.local.json | ConvertFrom-Json
bcdedit /delete $s.EntryId                          # la entrada nueva; el orden previo queda igual
Remove-Partition -DiskNumber <N> -PartitionNumber <M> -Confirm:$false   # opcional
Resize-Partition -DriveLetter C -Size ((Get-Partition -DriveLetter C).Size + 1572864000)  # opcional
powercfg /h on                                      # si querés el Inicio rápido de vuelta
```

El backup con el BCD exportado y `firmware-before.txt` queda en
`C:\ProgramData\WindowsGPUUnlock\ResearchBackups\`.

## Si la entrada no aparece en F8

```powershell
bcdedit /enum firmware                              # ¿existe?
bcdedit /set {fwbootmgr} bootsequence $s.EntryId    # arranque único de esa entrada
```

El `bootsequence` se consume en un solo arranque y vuelve a Windows; el orden normal
no cambia. Si aun así no arranca, la placa no enumera esa ESP: mové la partición a
un pendrive con una ESP FAT32 o al disco de arranque.

## Errores esperables

| Mensaje | Causa |
|---|---|
| `Use a separate existing FAT32 EFI partition, at least 1 GiB; never the Windows ESP` | tipo ESP o FAT32 incorrectos, tamaño <1 GiB, o es la ESP de Windows |
| `Encryption state changed; observation installer does not change encryption settings` | BitLocker no está totalmente descifrado (`VolumeStatus`/`ProtectionStatus` distintos de 0) |
| `Unsigned observation EFI requires Secure Boot disabled` | Secure Boot activo |
| `This registration requires the reviewed local observation image` | hash del EFI distinto: se compiló sin `Configure` o se mezclaron archivos |
| `Acceso denegado` en `Confirm-SecureBootUEFI` o `Get-BitLockerVolume` | consola no elevada |

## Qué está verificado y qué no

Verificado sin GPU: compilación de los perfiles preflight, experimental interno,
handoff y diagnóstico (perfil por perfil, con verificación de PE), 23 casos de
selección en tiempo de compilación más 15 rechazos de parámetros, los grupos de host
`port`, `preflight-lock`, `master-attributes`, `profile-lock`, `runtime`, los tests
`test_diagnostic`/`test_handoff` y los 8 tests de `tools/test_derive_profile.py`,
además de los 5 assets de firmware contra `internal-boot/unlock/assets.json`.

No verificado: nada de esto corrió sobre hardware. Los grupos `checks`, `preflight`,
`sha` y las transacciones experimentales de `test-all.ps1` necesitan el `PROM.BIN` y
la captura de preflight del RTX 3090 original, que no están en este árbol.

La captura de descubrimiento sí se tomó una vez en hardware real (2026-10-25,
ASRock B450M-HDV R4.0 P10.60 con RTX 3060 12GB; ver
[`evidence/discovery-rtx3060`](../evidence/discovery-rtx3060/README.md)). De esa
máquina queda probado el estado en frío; no se corrió ninguna transacción ni
ningún desbloqueo.

Esa máquina ya tiene perfil propio (`asrock-b450m-rtx3060`), pero sólo de
preflight: su cadena de consola no es la del splitter AMI y todavía no tiene
plan de desenganche revisado, así que `machine-profile.h` se niega a compilar
todo build con escritura para ella. El build y el registro del preflight están
en el README de la evidencia.
