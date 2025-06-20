# main.ps1

function ShowMainMenu {
    do {
        Clear-Host
        Write-Host "================================"
        Write-Host "       Herramientas ESP32"
        Write-Host "================================"
        Write-Host "1. Flash"
        Write-Host "2. Actualizar Firmware y Monitor Serial"
        Write-Host "3. Imprimir Código QR"
        Write-Host "4. Seleccionar Modelo de Dispositivo"
        Write-Host "5. Cargar Firmware LOCAL (.bin)"   # ← nueva opción
		Write-Host "6. Serial monitor "   # ← nueva opción
        Write-Host "7. Salir"
        $choice = Read-Host "Seleccione una opción"

        switch ($choice) {
            "1" { FlashESP32 }
            "2" { UpdateFirmwareAndMonitor }
            "3" { PrintQRCode }
            "4" { SelectDeviceModel }
            "5" { LoadLocalFirmware }          # ← llama a la nueva función
			"6" { SerialMonitor }
            "7" { return }
            default { Write-Host "Opción inválida"; Pause }
        }
    } while ($true)
}

function SerialMonitor {
    $port = SelectCOMPort
    if (-not $port) { return }

    Write-Host "\n▶️  Iniciando monitor serial en $port...\n"
    & $script:venvPython "monitor_serial.py" $port

    Pause
}

function SelectCOMPort {
    try {
        # Enumeración rápida vía Win32_PnPEntity filtrada por “(COM”.
        $ports = Get-WmiObject Win32_PnPEntity -Filter "Caption like '%(COM%'" |
                 Sort-Object Caption
    } catch { $ports = @() }

    # Fallback minimalista si WMI tarda demasiado
    if (-not $ports) {
        $ports = [System.IO.Ports.SerialPort]::GetPortNames() |
                 ForEach-Object { @{ DeviceID = $_ ; Caption = $_ } }
    }

    if (-not $ports) {
        Write-Host "⚠️  No hay puertos COM."; Pause; return $null
    }
	
    Write-Host "`nPuertos COM disponibles:"
    for ($i = 0; $i -lt $ports.Count; $i++) {
        $p   = $ports[$i]
        $m   = [regex]::Match($p.Caption, '\(COM\d+\)')   # → “(COM13)”
        if (-not $m.Success) { continue }                # ignora sin COM
        $com = $m.Value.Trim('()')                       # → “COM13”
        $usb = if ($p.Caption -match '(USB|usb)') { '🔌' } else { '' }
        Write-Host (" {0,2}. {1,-6}  {2} {3}" -f ($i+1), $com, $p.Caption, $usb)
        $ports[$i] | Add-Member -NotePropertyName ComPort -NotePropertyValue $com -Force
    }

    $sel = Read-Host "Seleccione un puerto por índice"
    $idx = 0
    if (-not [int]::TryParse($sel, [ref]$idx) -or $idx -lt 1 -or $idx -gt $ports.Count) {
        Write-Host "❌ Índice inválido."; Pause; return $null
    }
    return $ports[$idx-1].ComPort      # ← ahora devuelve “COM13”

}

function LoadLocalFirmware {
    # Cargar tres binarios locales y flashear el ESP32
    Add-Type -AssemblyName System.Windows.Forms

    $ofd             = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Title       = "Seleccione bootloader.bin, partitions.bin y firmware.bin"
    $ofd.Filter      = "Archivos binarios (*.bin)|*.bin"
    $ofd.Multiselect = $true

    if ($ofd.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        Write-Host "⚠️  Operación cancelada."; Pause; return
    }

    if ($ofd.FileNames.Count -ne 3) {
        Write-Host "❌ Debe seleccionar exactamente tres archivos .bin."; Pause; return
    }

    # Identificar cada archivo por su nombre (indiferente a mayúsculas/minúsculas)
    $boot = $ofd.FileNames | Where-Object { $_ -match '(?i)bootloader\.bin$' }
    $part = $ofd.FileNames | Where-Object { $_ -match '(?i)partitions\.bin$' }
    $firm = $ofd.FileNames | Where-Object { $_ -match '(?i)firmware\.bin$'  }

    if (-not ($boot -and $part -and $firm)) {
        Write-Host "❌ Los archivos deben llamarse bootloader.bin, partitions.bin y firmware.bin."
        Pause; return
    }

    $port = Read-Host "Ingrese el puerto COM (ej. COM3)"

    & $venvPython -m esptool --chip esp32s3 --port $port --baud 115200 `
        --before default_reset --after hard_reset write_flash -z `
        --flash_mode dio --flash_freq 40m --flash_size detect `
        0x0      "`"$boot`"" `
        0x8000   "`"$part`"" `
        0x10000  "`"$firm`""

    if ($LASTEXITCODE -eq 0) {
        Write-Host "✅ Firmware local cargado correctamente."
    } else {
        Write-Host "❌ Error al cargar firmware local."
    }
    Pause
}


function Start-ESP32Tool {
    $ErrorActionPreference = "Stop"

    $pythonVersion = "3.11.4"
    $pythonInstaller = "python-$pythonVersion-amd64.exe"
    $venvName = "aiotronic_env"
    $venvPath = Join-Path $PSScriptRoot $venvName
    $venvScripts = Join-Path $venvPath "Scripts"
    $venvPython = Join-Path $venvScripts "python.exe"
    $venvPip = Join-Path $venvScripts "pip.exe"
	$script:venvPython = $venvPython 

    $tools = @("esptool", "pyserial", "qrcode[pil]", "Pillow", "pywin32")

    if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
        Write-Host "🔧 Python no está instalado. Instalando Python $pythonVersion..."
        Invoke-WebRequest -Uri "https://www.python.org/ftp/python/$pythonVersion/$pythonInstaller" -OutFile $pythonInstaller
        Start-Process -Wait -FilePath ".\$pythonInstaller" -ArgumentList "/quiet InstallAllUsers=1 PrependPath=1 Include_test=0"
        Remove-Item $pythonInstaller
    } else {
        Write-Host "✅ Python ya está instalado."
    }

    if (-not (Test-Path $venvPath)) {
        Write-Host "🛠️  Creando entorno virtual..."
        python -m venv $venvPath
        if (-not $?) {
            Write-Error "❌ Error creando el entorno virtual."
            return
        }
        attrib +h $venvPath
    }

    & "$venvScripts\activate.ps1"

    & $venvPython -m pip install --upgrade pip
    & $venvPip install $tools

    Invoke-WebRequest "https://raw.githubusercontent.com/AIOTRONIC-ORG/Binary_Firmware/main/monitor_serial.py" -OutFile "monitor_serial.py"
    Invoke-WebRequest "https://raw.githubusercontent.com/AIOTRONIC-ORG/Binary_Firmware/main/print_qr.py" -OutFile "print_qr.py"

    SelectDeviceModel
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
            "1" { DownloadFirmware "EA01J"; return }
            "2" { DownloadFirmware "CA01N"; return }
            "3" { DownloadFirmware "EB01M"; return }
            "4" { return }                     # salir sin menú principal
            default { Write-Host "Opción inválida"; Pause }
        }
    }

    ShowMainMenu                              # ← ahora sí se ejecuta
}

function DownloadFirmware($device) 
{
    Write-Host "⬇️  Descargando firmware más reciente para $device..."
    $base = "https://github.com/AIOTRONIC-ORG/Binary_Firmware/raw/main/$device"
    Invoke-WebRequest "$base/bootloader.bin" -OutFile "bootloader.bin"
    Invoke-WebRequest "$base/partitions.bin" -OutFile "partitions.bin"
    Invoke-WebRequest "$base/firmware.bin" -OutFile "firmware.bin"
}

function FlashESP32 
{
    $port = Read-Host "Ingrese el puerto COM (ej. COM3)"
    & "$venvPython" -m esptool --chip esp32s3 --port $port erase_flash
    Pause
}

function UpdateFirmwareAndMonitor 
{
    $port = Read-Host "Ingrese el puerto COM (ej. COM3)"
    & "$venvPython" -m esptool --chip esp32s3 --port $port --baud 115200 --before default_reset --after hard_reset write_flash -z --flash_mode dio --flash_freq 40m --flash_size detect 0x0 bootloader.bin 0x8000 partitions.bin 0x10000 firmware.bin
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✅ Firmware actualizado exitosamente. Esperando conexión y MAC..."
        & "$venvPython" monitor_serial.py $port
    } else {
        Write-Host "❌ Error actualizando firmware."
    }
    Pause
}

function PrintQRCode 
{
    if (-not (Test-Path "mac_qr.png")) {
        Write-Host "⚠️  No se encontró mac_qr.png. Ejecute el monitor serial primero."
    } else {
        & "$venvPython" print_qr.py
    }
    Pause
}

# Ejecutar herramienta
Start-ESP32Tool
