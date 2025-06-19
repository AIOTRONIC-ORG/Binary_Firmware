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
        Write-Host "5. Salir"
        $choice = Read-Host "Seleccione una opción"

        switch ($choice) {
            "1" { FlashESP32 }
            "2" { UpdateFirmwareAndMonitor }
            "3" { PrintQRCode }
            "4" { SelectDeviceModel }
            "5" { return }
            default { Write-Host "Opción inválida"; Pause }
        }
    } while ($true)
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
