# Guía de usuario — NVIDIA Ampere Unlock para Windows

Esta guía es para **una máquina concreta**: ASRock B450M-HDV R4.0, BIOS P10.60,
Ryzen sin iGPU y ASUS RTX 3060 12GB (`10de:2504`, subsistema `1043:8816`).
El binario está atado a esa placa y a esa tarjeta; en cualquier otra cosa el
script se niega antes de tocar nada.

## Qué hace

Desbloquea la tasa de las unidades Tensor para FP16/BF16/TF32 con acumulación
FP32, que en las GeForce viene limitada a la mitad. En esta máquina, medido:

| Camino | Bloqueada | Desbloqueada |
|---|---|---|
| FP16 entrada, acumula FP32 | ~25 TFLOPS | **45–48 TFLOPS** |
| TF32, acumula FP32 | ~13 TFLOPS | **23–25 TFLOPS** |
| FP32 SIMT | ~8 TFLOPS | ~8 TFLOPS (no cambia) |

El desbloqueo ocurre en el firmware, antes de que el driver de NVIDIA tome la
tarjeta, porque después ese registro queda protegido hasta el próximo apagado.

## Qué necesitás

- Windows con la partición EFI de observación ya preparada (la misma que usa
  este proyecto; el script no crea, redimensiona ni formatea particiones).
- **Secure Boot desactivado** (el EFI no está firmado).
- La tarjeta en su slot, sin otra GPU de display.
- Los cinco firmwares de NVIDIA 610.43.03 en `assets/out/` (no se distribuyen).

## Uso

Hay dos formas: la **ventana** (doble clic en `GpuUnlock.cmd`) o la **consola**.
La ventana y la consola hacen exactamente lo mismo: la ventana sólo pide
administrador al activar o desactivar.

### Ventana

Doble clic en `GpuUnlock.cmd`. Muestra el estado leído de esta máquina —placa,
tarjeta, Secure Boot, entrada de arranque, último intento y resultado de la
transacción— y el rendimiento medido. Los botones:

| Botón | Qué hace |
|---|---|
| **VERIFY** | Lee el último log y mide la tarjeta; el cartel pasa a UNLOCKED o LOCKED |
| **MEASURE** | Sólo mide, sin leer el log |
| **ACTIVATE** | Copia las imágenes y agrega la entrada al menú F8 |
| **also automatic** | Además la pone primera y apaga Inicio Rápido |
| **DEACTIVATE** | Borra la entrada y restaura el orden anterior |
| **LOGS** | Abre la carpeta de logs de la partición |
| **HELP** | Abre esta guía |

Si la ventana se abre sin privilegios, dice `Not elevated` arriba; al tocar
ACTIVATE o DEACTIVATE pide UAC y se reabre elevada.

### Consola

En PowerShell **como administrador**, desde la raíz del repositorio:

```powershell
# 0. Estado, sin tocar nada (también anda sin administrador).
.\GpuUnlock.ps1 -Status          # -Status -Json para scripts

# 1. Activar: copia las imágenes y agrega la entrada al menú de arranque (F8).
.\GpuUnlock.ps1 -Activate

# 2. Reiniciar, F8, elegir "NVIDIA Ampere Unlock - RTX 3060".
#    La pantalla se apaga cuando se libera la consola; Windows la recupera.

# 3. Verificar: lee el último log y mide la tasa Tensor.
.\GpuUnlock.ps1 -Verify
```

`-Verify` contesta dos cosas: si la transacción terminó (`FINAL ... attempted=1`)
y si la tarjeta mide como desbloqueada (≥ 35 TFLOPS en FP16→FP32). Si el arranque
fue a Windows sin pasar por la entrada, el log viejo puede estar bien y la
medición no: el script te lo dice explícitamente.

### Modo automático (opcional)

```powershell
.\GpuUnlock.ps1 -Activate -Automatic
```

Pone la entrada primera en el orden de firmware y apaga Inicio Rápido. El
desbloqueo pasa a ocurrir en cada encendido sin abrir el menú.

### Desactivar

```powershell
.\GpuUnlock.ps1 -Deactivate
```

Borra la entrada y restaura el orden de arranque. Las imágenes quedan en la
partición de observación, sin efecto. **Un apagado completo devuelve la tarjeta
al estado de fábrica**: no hay nada escrito en la GPU, su BIOS ni el driver.

## Qué esperar y qué puede salir mal

- Entre el desenganche de la consola y la toma de control de Windows la pantalla
  queda negra. Es lo normal en esta placa: no queda nadie dibujando.
- Si la transacción falla, la imagen **no reintenta ni resetea**: se queda ahí.
  Apagá (corte de energía), arrancá Windows normal y mirá
  `U:\RTX3090-UNLOCK\HLS######.TXT` y `U:\RTX3090-UNLOCK\AUTO######\REPORT.TXT`.
  El `FINAL ... stage=<etapa>` dice dónde se detuvo y `attempted=` si llegó a
  escribir.
- Si Windows no vuelve, un apagado completo restaura todo: no hay estado
  persistente que deshacer.
- Suspensión y reinicio no re-desblocan más que lo que ya está: el desbloqueo
  vive en RAM de la GPU hasta el apagado.

## Medir la línea base (una vez, opcional pero recomendado)

El README dice ~25 TFLOPS porque es la especificación de GeForce. Para tener el
número **real de esta máquina**:

1. Apagá por completo —no reinicies— y arrancá Windows **sin** elegir la entrada
de desbloqueo (con Inicio Rápido apagado, un `shutdown /s /t 0` alcanza).
2. Corré:

   ```powershell
   .\GpuUnlock.ps1 -Baseline
   ```

   Guarda la medición en `%ProgramData%\WindowsGPUUnlock\baseline.json`. Si la
tarjeta mide desbloqueada, **se niega** a guardar: no se puede registrar una
línea base mala por error.
3. Desde ahí, `-Verify` y la ventana muestran el porcentaje real
   (`+82% vs baseline 24.8`).

## Cómo saber que de verdad está desbloqueada

Sin medir no se sabe. El benchmark del proyecto es la referencia:

```powershell
nvcc -O3 -arch=sm_86 research/bench/tensor_rate.cu -lcublas -o research/bench/build/tensor_rate.exe
research\bench\build\tensor_rate.exe 4096 20
```

Corré lo mismo en un arranque limpio (sin la entrada) para tener la línea base:
la diferencia esperada es de aproximadamente 2x en los dos primeros caminos.

## Privacidad y archivos

- Backups de arranque en `%ProgramData%\WindowsGPUUnlock\`.
- Estado de instalación en `%ProgramData%\WindowsGPUUnlock\install.json`.
- Los firmwares de NVIDIA no se distribuyen con el repositorio.

## Licencia

GPL-2.0-only, igual que el proyecto del que deriva. Ver `LICENSE`.
