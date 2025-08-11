# main.ps1
#no tildes en este codigo para maxima compatiblidad con all powershell versions

# ==== BOOT PROBE (debe ser lo PRIMERO) ======================
$global:LogDir  = Join-Path $env:TEMP 'aio-exe-log'
$null = New-Item -ItemType Directory -Force -Path $global:LogDir -ErrorAction SilentlyContinue
$global:LogPath = Join-Path $global:LogDir ("boot_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

# log mínimo, sin Transcript (por si falla)
try { "BOOT START PS=$($PSVersionTable.PSVersion)" | Out-File -FilePath $global:LogPath -Append -Encoding UTF8 } catch {}

# Señal visual inmediata para confirmar entrada al script
try {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show("AIO EXE started.`nLog: $global:LogPath","AIO") | Out-Null
} catch {
    # si falla WinForms, igual deja marca
    try { "MessageBox failed: $($_.Exception.Message)" | Out-File -FilePath $global:LogPath -Append } catch {}
}
# ============================================================


# Lightweight log helper
function Write-Log([string]$msg) {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    try { [Console]::Out.WriteLine("[$ts] $msg") } catch {}
}
Write-Log "==== BOOT STARTED (PID=$PID, PS=$($PSVersionTable.PSVersion)) ===="

# Make Write-Host also land in the log (it uses Console.Out under the hood)


# -- al principio de main.ps1 --
$script:SelectedDevice = $null   # guarda el modelo elegido


function ShowMainMenu {
    do {
        Clear-Host
        Write-Host "================================"
        Write-Host "       Herramientas ESP32"
        Write-Host "================================"
        Write-Host "1. Flash"
        Write-Host "2. Actualizar Firmware desde SERVIDOR y Monitor Serial"
        Write-Host "3. Imprimir Codigo QR"
        Write-Host "4. Seleccionar Modelo de Dispositivo"
        Write-Host "5. Cargar Firmware LOCAL (.bin)"   # nueva opcion
		Write-Host "6. Serial monitor "   #  nueva opcion
        Write-Host "7. Salir"
	    Write-Host "8. Resetear a modo fabrica (eliminar Python embebido)"

        $choice = Read-Host "Seleccione una opcion"

        switch ($choice) {
            "1" { FlashESP32 }
            "2" { SelectDeviceModel; UpdateFirmwareAndMonitor }
            "3" { PrintQRCode }
            "4" { SelectDeviceModel }
            "5" { LoadLocalFirmware }          # llama a la nueva funcion
			"6" { SerialMonitor }
            "7" { return }
	    "8" { ResetEmbeddedPython }
            default { Write-Host "Opcion invalida"; Pause }
        }
    } while ($true)
}

function ResetEmbeddedPython {
    $embedDir = Join-Path $PSScriptRoot "embedded_py"
    if (Test-Path $embedDir) {
        try {
            Remove-Item -Path $embedDir -Recurse -Force
            Write-Host "Python embebido eliminado correctamente."
        } catch {
            Write-Host "Error eliminando la carpeta embebida: $($_.Exception.Message)"
            Pause
            return
        }
    } else {
        Write-Host "No hay instalacion embebida para eliminar."
    }
    Write-Host "La terminal se cerrara ahora para completar el reseteo..."
    # Start-Sleep -Seconds 2
    Stop-Process -Id $PID
}


function Install-EmbeddedPython {
    param(
        [string]$Version = "3.11.4",
        [string]$BaseDir = (Join-Path $PSScriptRoot "embedded_py")
    )

    $zipName   = "python-$Version-embed-amd64.zip"
    $zipUrl    = "https://www.python.org/ftp/python/$Version/$zipName"
    $pythonDir = Join-Path $BaseDir "py$Version"
    $pythonExe = Join-Path $pythonDir "python.exe"

    if (-not (Test-Path $pythonExe)) {
        Write-Host " Descargando Python $Version (embeddable)..."
        New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null
        Invoke-WebRequest $zipUrl -OutFile $zipName
        Expand-Archive $zipName -DestinationPath $pythonDir
        Remove-Item $zipName

        # 1) Activa ‘import site’
        (Get-Content "$pythonDir\python311._pth") |
			ForEach-Object { $_ -replace '^#\s*import\s+site', 'import site' } |
			Set-Content "$pythonDir\python311._pth"

        # 2) Añade pip
        #& $pythonExe -m ensurepip -U
        #& $pythonExe -m pip install --upgrade pip
		# 2) Añade pip (el embeddable no incluye ensurepip)
		$gp = Join-Path $pythonDir 'get-pip.py'
		Invoke-WebRequest 'https://bootstrap.pypa.io/get-pip.py' -OutFile $gp
		& $pythonExe $gp -q        # instala pip en el propio Python embebido
		Remove-Item $gp

    }
    return $pythonExe         # ruta absoluta al intérprete portable
}


function SerialMonitor {
	
	param(
        [string]$port
    )
	
    $port = SelectCOMPort
    if (-not $port) { return }

    Write-Host "\n▶️  Iniciando monitor serial en $port...\n"
    & $script:venvPython "monitor_serial.py" $port

    Pause
}

function Get-Esp32Mac {
    param(
        [string]$Com,
        [string]$Py = $script:venvPython
    )
    try {
        $out = & $Py -m esptool --chip auto --port $Com --baud 115200 `
                read_mac 2>$null | Select-String -Pattern 'MAC:\s*([0-9A-F:]{17})'
        if ($out) { return $out.Matches[0].Groups[1].Value }
    } catch { }
    return ''
}


function SelectCOMPort {

    param(
        [switch]$Verbose
    )

    Write-Host "`nSeleccione modo para elegir puerto COM:"
    Write-Host "1. Elegir por indice"
    Write-Host "2. Ingresar COM manualmente (ej: COM4)"
    $modo = Read-Host "Opcion"
    if ($modo -eq "2") {
        $manual = Read-Host "Ingrese el nombre del puerto COM (ej: COM4)"
        if ($manual -match '^COM\d+$') {
            return $manual
        } else {
            Write-Host "Puerto COM invalido."; Pause; return $null
        }
    }

    try {
        $ports = Get-WmiObject Win32_PnPEntity -Filter "Caption like '%(COM%'" |
                 Sort-Object Caption
    } catch { $ports = @() }

    if (-not $ports) {
        $ports = [System.IO.Ports.SerialPort]::GetPortNames() |
                 ForEach-Object { @{ DeviceID = $_ ; Caption = $_ } }
    }
    if (-not $ports) { Write-Host "No se encontraron puertos COM."; Pause; return $null }

    $comRegex        = '\(COM\d+\)'
    $comPortsToCheck = @()
    foreach ($p in $ports) {
        if ($p.Caption -match 'Bluetooth') { continue }
        $m = [regex]::Match($p.Caption, $comRegex)
        if ($m.Success) { $comPortsToCheck += $m.Value.Trim('()') }
    }

    $macs  = @{}
    $fails = @{}

    if ($comPortsToCheck) {
        Write-Host "`nLeyendo MACs de puertos: $($comPortsToCheck -join ', ')..."
        foreach ($com in $comPortsToCheck) {
            Write-Host ("Probing {0,-5}…" -f $com) -NoNewline
            try {
                $out = & $script:venvPython -m esptool `
                         --chip auto --port $com --baud 115200 `
                         --before default_reset --after no_reset `
                         --connect-attempts 5 read_mac 2>&1
            } catch {
                $fails[$com] = $_.Exception.Message
                Write-Host "  error: $($_.Exception.Message)"
                continue
            }

            if ($Verbose) { $out | ForEach-Object { Write-Host "    $_" } }

            $outStr = $out -join "`n"
            if ($outStr -match 'MAC:\s*([0-9A-Fa-f:]{2}(?::[0-9A-Fa-f]{2}){5})') {
                $macs[$com] = $Matches[1]
                Write-Host "  OK $($macs[$com])"
            } else {
                $last = ($out | Select-Object -Last 1).Trim()
                $fails[$com] = if ($last) { $last } else { "Sin respuesta" }
                Write-Host "  error: $last"
            }
        }
    }

    Write-Host "`nPuertos COM disponibles:"
    for ($i = 0; $i -lt $ports.Count; $i++) {
        $p   = $ports[$i]
        $m   = [regex]::Match($p.Caption, $comRegex)
        if (-not $m.Success) { continue }
        $com = $m.Value.Trim('()')
        $usb = if ($p.Caption -match '(USB|usb)') { 'USB' } else { '' }
        Write-Host (" {0,2}. {1,-6}  {2} {3}" -f ($i+1), $com, $p.Caption, $usb)
        $ports[$i] | Add-Member -NotePropertyName ComPort -NotePropertyValue $com -Force
    }

    Write-Host "`nPuertos con MAC o error:"
    for ($i = 0; $i -lt $ports.Count; $i++) {
        $p   = $ports[$i]
        $m   = [regex]::Match($p.Caption, $comRegex)
        if (-not $m.Success) { continue }
        $com = $m.Value.Trim('()')
        $usb = if ($p.Caption -match '(USB|usb)') { 'USB' } else { '' }

        if ($macs.ContainsKey($com)) {
            $info = "MAC $($macs[$com]) OK"
        } elseif ($fails.ContainsKey($com)) {
            $info = "error: $($fails[$com])"
        } else {
            $info = "sin intento"
        }
        Write-Host (" {0,2}. {1,-6}  {2} {3}" -f ($i+1), $com, $info, $usb)
    }

    $sel = Read-Host "`nSeleccione un puerto por indice"
    $idx = 0
    if (-not [int]::TryParse($sel, [ref]$idx) -or $idx -lt 1 -or $idx -gt $ports.Count) {
        Write-Host "Indice invalido."; Pause; return $null
    }
    return $ports[$idx-1].ComPort
}

function LoadLocalFirmware {
    # Cargar tres binarios locales o desde una ruta base (local o URL) y flashear el ESP32
    Add-Type -AssemblyName System.Windows.Forms

    Write-Host ""
    Write-Host "Seleccione el metodo de carga:"
    Write-Host "  1) Selector de archivos (OpenFileDialog)"
    Write-Host "  2) Ruta base (local o URL) que contenga bootloader.bin, partitions.bin y firmware.bin"
    $mode = Read-Host "Ingrese 1 o 2"

    $boot = $null
    $part = $null
    $firm = $null

    if ($mode -eq "1") {
        $ofd             = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Title       = "Seleccione bootloader.bin, partitions.bin y firmware.bin"
        $ofd.Filter      = "Archivos binarios (*.bin)|*.bin"
        $ofd.Multiselect = $true

        if ($ofd.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
            Write-Host "Operacion cancelada."; Pause; return
        }

        if ($ofd.FileNames.Count -ne 3) {
            Write-Host "Debe seleccionar exactamente tres archivos .bin."; Pause; return
        }

        # Identificar cada archivo por su nombre (indiferente a mayusculas/minusculas)
        $boot = $ofd.FileNames | Where-Object { $_ -match '(?i)bootloader\.bin$' }
        $part = $ofd.FileNames | Where-Object { $_ -match '(?i)partitions\.bin$' }
        $firm = $ofd.FileNames | Where-Object { $_ -match '(?i)firmware\.bin$'  }

        if (-not ($boot -and $part -and $firm)) {
            Write-Host "Los archivos deben llamarse bootloader.bin, partitions.bin y firmware.bin."
            Pause; return
        }
    }
    elseif ($mode -eq "2") {
        Write-Host ""
        Write-Host "Modelos de ruta base sugeridos:"
        Write-Host "  Local (carpeta):    C:\proyectos\esp32\build"
        Write-Host "  Git local (carpeta): C:\repo\mi_firmware\out"
        Write-Host "  GitHub raw (URL):   https://raw.githubusercontent.com/usuario/repositorio/rama/build"
        Write-Host "  GitLab raw (URL):   https://gitlab.com/usuario/proyecto/-/raw/rama/build"
        Write-Host "  Gitea raw (URL):    https://gitea.dominio.tld/usuario/repo/raw/branch/build"
        $base = Read-Host "Ingrese la ruta base (local o URL)"

        if ([string]::IsNullOrWhiteSpace($base)) {
            Write-Host "Ruta base vacia."; Pause; return
        }

        $isUrl = $base -match '^https?://'
        if ($isUrl) {
            if ($base[-1] -ne '/') { $base = $base + '/' }

            $tmp = Join-Path $env:TEMP ("esp32_flash_" + (Get-Date -Format yyyyMMddHHmmss))
            New-Item -ItemType Directory -Path $tmp -Force | Out-Null

            $targets = @(
                @{ Name = "bootloader.bin"; Out = (Join-Path $tmp "bootloader.bin") },
                @{ Name = "partitions.bin"; Out = (Join-Path $tmp "partitions.bin") },
                @{ Name = "firmware.bin";   Out = (Join-Path $tmp "firmware.bin") }
            )

            foreach ($t in $targets) {
                $url = $base + $t.Name
                try {
                    Invoke-WebRequest -Uri $url -OutFile $t.Out -UseBasicParsing -ErrorAction Stop
                } catch {
                    Write-Host "Error descargando $($t.Name) desde $url"
                    Pause; return
                }
            }

            $boot = Join-Path $tmp "bootloader.bin"
            $part = Join-Path $tmp "partitions.bin"
            $firm = Join-Path $tmp "firmware.bin"
        }
        else {
            # Ruta base local: combinar y validar
            if (-not (Test-Path -LiteralPath $base)) {
                Write-Host "La ruta base local no existe: $base"
                Pause; return
            }
            $boot = Join-Path $base "bootloader.bin"
            $part = Join-Path $base "partitions.bin"
            $firm = Join-Path $base "firmware.bin"

            if (-not (Test-Path -LiteralPath $boot) -or -not (Test-Path -LiteralPath $part) -or -not (Test-Path -LiteralPath $firm)) {
                Write-Host "No se encontraron los tres archivos requeridos en la ruta base:"
                Write-Host "  $boot"
                Write-Host "  $part"
                Write-Host "  $firm"
                Pause; return
            }
        }
    }
    else {
        Write-Host "Opcion invalida."; Pause; return
    }

    $port = SelectCOMPort

    & $venvPython -m esptool --chip esp32s3 --port $port --baud 115200 `
        --before default_reset --after hard_reset write_flash -z `
        --flash_mode dio --flash_freq 40m --flash_size detect `
        0x0      "`"$boot`"" `
        0x8000   "`"$part`"" `
        0x10000  "`"$firm`""

    if ($LASTEXITCODE -eq 0) {
        Write-Host "Firmware local cargado correctamente."
    } else {
        Write-Host "Error al cargar firmware."
    }
    Pause
}


function Start-ESP32Tool {
    $ErrorActionPreference = "Stop"

    # Siempre usa TU copia embebida ↴
    $embeddedPy = Install-EmbeddedPython "3.11.4"
	
	
    #$venvPath   = Join-Path $PSScriptRoot "aiotronic_env"

    #if (-not (Test-Path $venvPath)) {
     #   Write-Host "🛠️  Creando entorno virtual aislado..."
      #  & $embeddedPy -m venv $venvPath
       # attrib +h $venvPath     # ocúltalo para no ensuciar la carpeta
    #}

    #$venvPython  = Join-Path $venvPath "Scripts\python.exe"
    #$venvPip     = Join-Path $venvPath "Scripts\pip.exe"
	
	$script:venvPython = Install-EmbeddedPython "3.11.4"   # usamos el Python embebido tal cual

	
	
    #$script:venvPython = $venvPython   # ← resto del script lo usará

    #& $venvPython -m pip install --upgrade pip
    #& $venvPip install "esptool" "pyserial" "qrcode[pil]" "Pillow" "pywin32"
	
	& $script:venvPython -m pip install --upgrade pip
	& $script:venvPython -m pip install esptool pyserial "qrcode[pil]" Pillow pywin32



    # Descarga/actualiza utilidades auxiliares
    Invoke-WebRequest "https://raw.githubusercontent.com/AIOTRONIC-ORG/Binary_Firmware/main/monitor_serial.py" -OutFile "monitor_serial.py"
    Invoke-WebRequest "https://raw.githubusercontent.com/AIOTRONIC-ORG/Binary_Firmware/main/print_qr.py"      -OutFile "print_qr.py"

    
    ShowMainMenu
}


function SelectDeviceModel {
    while ($true) {
        Clear-Host
        Write-Host "=============================="
        Write-Host "   Seleccionar Modelo de Equipo"
        Write-Host "=============================="
        Write-Host "1. Energy 23 (EA01J)"
        Write-Host "2. Social Voz (CA01N)"
        Write-Host "3. Toro Shock (EB01M)"
        Write-Host "4. Salir"
        $choice = Read-Host "Seleccione una opción"

        switch ($choice) {
            "1" { $script:SelectedDevice = "EA01J"; DownloadFirmware $script:SelectedDevice; return }
			"2" { $script:SelectedDevice = "CA01N"; DownloadFirmware $script:SelectedDevice; return }
			"3" { $script:SelectedDevice = "EB01M"; DownloadFirmware $script:SelectedDevice; return }

            "4" { return }                     # salir sin menú principal
            default { Write-Host "Opcion invalida"; Pause }
        }
    }

    ShowMainMenu                              # ← ahora sí se ejecuta
}

function DownloadFirmware($device) 
{
    Write-Host " Descargando firmware más reciente para $device..."
    $base = "https://github.com/AIOTRONIC-ORG/Binary_Firmware/raw/main/$device"
	
	$dest = Join-Path "./binariesServidor" $device
	New-Item -ItemType Directory -Force -Path $dest | Out-Null

    Invoke-WebRequest "$base/bootloader.bin" -OutFile "$dest/bootloader.bin"
    Invoke-WebRequest "$base/partitions.bin" -OutFile "$dest/partitions.bin"
    Invoke-WebRequest "$base/firmware.bin" -OutFile "$dest/firmware.bin"
	 Write-Host " Descargado en $dest"
}

function FlashESP32 
{
    $port = SelectCOMPort
    & "$venvPython" -m esptool --chip esp32s3 --port $port erase_flash
    Pause
}

function UpdateFirmwareAndMonitor 
{
	
	if (-not $script:SelectedDevice) {
	Write-Host "Primero seleccione un modelo de dispositivo (opción 4 del menú)."
	Pause; return
    }

    $baseDir = Join-Path "./binariesServidor" $script:SelectedDevice
    $boot = Join-Path $baseDir "bootloader.bin"
    $part = Join-Path $baseDir "partitions.bin"
    $firm = Join-Path $baseDir "firmware.bin"
	
    $port = SelectCOMPort
    
	#& "$venvPython" -m esptool --chip esp32s3 --port $port --baud 115200 --before default_reset --after hard_reset write_flash -z --flash_mode dio --flash_freq 40m --flash_size detect 0x0 bootloader.bin 0x8000 partitions.bin 0x10000 firmware.bin
	
	& "$venvPython" -m esptool --chip esp32s3 --port $port --baud 115200 `
	--before default_reset --after hard_reset write_flash -z `
	--flash_mode dio --flash_freq 40m --flash_size detect `
	0x0      $boot `
	0x8000   $part `
	0x10000  $firm


    if ($LASTEXITCODE -eq 0) {
        Write-Host "Firmware actualizado exitosamente. Esperando conexión y MAC..."
        & "$venvPython" monitor_serial.py $port
    } else {
        Write-Host "Error actualizando firmware."
    }
    Pause
	SerialMonitor($port)
}

function PrintQRCode 
{
    if (-not (Test-Path "mac_qr.png")) {
        Write-Host "No se encontro mac_qr.png. Ejecute el monitor serial primero."
    } else {
        & "$venvPython" print_qr.py
    }
    Pause
}

# ============================================================
# BOOTSTRAP: ejecución con log y pausa garantizada
# ============================================================
$ErrorActionPreference = 'Stop'
$logPath = Join-Path $PSScriptRoot 'last_run.log'

# Intenta abrir transcripción (si falla, seguimos igual)
try { Start-Transcript -Path $logPath -Append -ErrorAction Stop | Out-Null } catch {}

function Pause-And-Exit {
    Write-Host ""
    Write-Host "Presiona ENTER para salir..."
    try { [void][System.Console]::ReadLine() } catch { Read-Host | Out-Null }
    try { Stop-Transcript | Out-Null } catch {}
}

# ===== MAIN ENTRY + ALWAYS-PAUSE =====
try {
    # IMPORTANT: fix your bug before running (do NOT overwrite venv path):
    # $script:venvPython = Install-EmbeddedPython "3.11.4"
    Start-ESP32Tool
}
catch {
    Write-Log "ERROR: $($_ | Out-String)"
    Write-Host "`nERROR:`n$($_ | Out-String)"
}
finally {
    Write-Log "==== BOOT FINISHED ===="
    Write-Host "`nPresiona ENTER para salir..."
    try { [void][System.Console]::ReadLine() } catch { Read-Host | Out-Null }
    try { $sw.Flush(); $sw.Dispose(); $fs.Dispose() } catch {}
}
