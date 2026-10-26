# Portar el desbloqueo a otra máquina

Este documento describe cómo llevar el port de Windows a **otra** placa y/o tarjeta
Ampere. No es una promesa de soporte: cada máquina necesita su propia captura y
su propia revisión. La regla del proyecto es simple: **lo que no está medido en
esa máquina no puede escribir nada**.

## Por qué no hay un único binario universal

El algoritmo de desbloqueo (V67/PLM + selectores SM + FLR) es común a GA102/103/104/106.
Lo que **no** es común es todo lo que lo rodea, y todo eso se compila como constantes
inmutables por perfil:

| Pieza | Por qué es por máquina |
|---|---|
| Identidad de la placa y la tarjeta | PCI id, subsistema, revisión, BAR0, chip id, tamaño de VRAM |
| Hash de la PROM viva | Cada vBIOS tiene el suyo; se compara contra la lectura de la tarjeta |
| Cadena de consola | Qué driver de BIOS pone la consola y sobre qué handle (splitter AMI, nvgop, EDID/mouse) |
| Huellas de los drivers de firmware | Tamaño, offset de `Stop`, hash del `.text` del nvgop y del EDID/mouse de ese BIOS |
| Ruta de display | Los 36 bytes del device path del GOP de arranque, que dependen del árbol ACPI |
| Estado frío esperado | Chip, GFW, WPR2, y los selectores SM de ese encendido |

Un binario "universal" tendría que aceptar cualquiera de esos valores leídos en
caliente, y eso es exactamente lo que el diseño evita: un perfil tocado a mano no
puede habilitar escrituras. Por eso la portabilidad se resuelve con **cinco pasos
por máquina**, cada uno con evidencia, y los binarios salen de esos pasos.

## Los cinco pasos

Todos corren desde PowerShell elevado en la raíz del repo. Antes de empezar:
Secure Boot apagado, una partición EFI de observación dedicada (≥1 GiB, FAT32,
con letra), `C:` descifrado y `.\internal-boot\Configure.ps1` ya ejecutado.

### 1. Capturar la máquina (solo lectura)

```powershell
.\research\headless\build-observe.ps1 -Discovery
.\research\headless\register-observe.ps1          # copia OBSERVE.EFI a la ESP
```

Arrancá esa entrada desde F8. Escribe `DIAG00.TXT` en la ESP y **no** toca nada:
ni drivers, ni MMIO de escritura, ni NVRAM. Ese dump es la fuente de verdad de
toda la identidad de la máquina: handles, relaciones, rutas, config PCI, PROM.

### 2. Derivar el perfil

```powershell
python tools/derive_profile.py DIAG00.TXT --name PLACA-BIOS-TARJETA --define GU_PROFILE_X
```

Imprime las constantes que hay que pegar en `internal-boot/unlock/machine-profile.h`:
ids, BAR0, chip, hash de PROM, tamaño de memoria, ruta de display y las huellas de
nvgop/EDID. El script **se niega** ante ambigüedad (dos candidatos, path corto,
PROM ilegible): una negativa es información, no un obstáculo.

Revisá a mano que el `GU_RTX_PATH_BYTES` tenga 36 bytes y que los hashes de `.text`
correspondan a los drivers que la captura muestra como dueños de la consola.

### 3. Verificar la cadena de consola (solo lectura)

```powershell
.\research\headless\build-console-verify.ps1 -HardwareProfile <perfil>
.\research\headless\register-observe.ps1 -ConsoleVerify
```

Esta imagen comprueba ruta de display, dueños de la consola y huellas, y arranca
Windows sin liberar nada. Si falla, el log dice la etapa exacta
(`console-preflight-displays`, `-consumers`, `-alive`).

### 4. Ensayar el desenganche (sin escrituras de GPU)

```powershell
.\research\headless\build-r2.ps1 -HardwareProfile <perfil>     # consumidores de consola
.\research\headless\register-observe.ps1 -ConsoleR2
.\research\headless\build-release-full.ps1 -HardwareProfile <perfil>  # + EDID/nvgop + decode
.\research\headless\register-observe.ps1 -ReleaseFull
```

Dos ensayos, en ese orden. El primero libera los dueños de la consola; el segundo
además libera el driver EDID/mouse y nvgop, restaura la decodificación PCI y
verifica el estado frío. Los dos arrancan Windows al final y ninguno escribe un
registro de la GPU. Si tu placa tiene una segunda GPU que sobrevive, el ensayo
además debe seguir mostrando algo; si la consola está sobre la tarjeta, lo
esperado es que la pantalla se apague en el medio.

Antes de seguir, los dos tienen que pasar **en hardware**, con todas las etapas
en `0x0` y sin `handoff-stopped`.

### 5. Habilitar escritura y medir

Habilitá el perfil en `machine-profile.h` (la lista de perfiles explica qué
evidencia hace falta), armá el par con el script de tu perfil y corré la entrada.
Después:

```powershell
nvcc -O3 -arch=sm_86 research/bench/tensor_rate.cu -lcublas -o research/bench/build/tensor_rate.exe
research\bench\build\tensor_rate.exe 4096 20
```

Compará contra un arranque limpio de la misma máquina. Sin ese antes/después no
está verificado: el log muestra que la transacción corrió, no que la tarjeta
entregue más.

## Qué mirar cuando algo falla

- `CHECK stage=<x> status=0x800000000000000e` en el `REPORT.TXT` del hijo: falta
  un archivo (`0x0e` es `EFI_NOT_FOUND`). Los cinco firmwares van en
  `\RTX3090-UNLOCK\ASSETS\`.
- `console-preflight-consumers status=0x800000000000000f`: hay un dueño que el
  perfil no conoce. Volvé a la captura y revisá las huellas.
- `verify-*` en el wrapper: el estado después de liberar no es el esperado; el
  nombre de la etapa dice qué comparación falló.
- `FINAL ... attempted=0`: no se escribió nada, la tarjeta está limpia.
- Selectores fríos distintos entre arranques (`SS0` cambia): es normal; por eso
  el perfil `entryLatchedSs1Full` engancha el valor del encendido en vez de fijar
  una constante.

## Qué no hacer

- No agregues ids de placa o PCI a mano sin una captura que los respalde.
- No uses un perfil de otra máquina "parecida": la cadena de consola y las
  huellas de drivers cambian entre versiones de BIOS del mismo modelo.
- No distribuyas los firmwares de NVIDIA ni imágenes con tu partición adentro.
- No conviertas un mock en evidencia de hardware.

## Estado actual

| Perfil | Placa / BIOS | Tarjeta | Consola | Estado |
|---|---|---|---|---|
| `B650M_3090FE` | ASUS TUF B650M-PLUS WIFI 3057 | RTX 3090 FE | sobre la tarjeta | verificado en hardware |
| `B660M_3070TI` | ASUS TUF B660M-E D4 4003 | RTX 3070 Ti | splitter AMI | verificado en hardware |
| `ASROCK_B450M_RTX3060` | ASRock B450M-HDV R4.0 P10.60 | RTX 3060 12GB | sobre la tarjeta | verificado en hardware (2026-10-25) |
