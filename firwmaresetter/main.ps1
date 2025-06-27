# main.ps1
#no tildes en este codigo para maxima compatiblidad con all powershell versions

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
        $choice = Read-Host "Seleccione una opcion"

        switch ($choice) {
            "1" { FlashESP32 }
            "2" { SelectDeviceModel; UpdateFirmwareAndMonitor }
            "3" { PrintQRCode }
            "4" { SelectDeviceModel }
            "5" { LoadLocalFirmware }          # llama a la nueva funcion
			"6" { SerialMonitor }
            "7" { return }
            default { Write-Host "Opcion invalida"; Pause }
        }
    } while ($true)
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
    try {
        # Enumeración rapida via Win32_PnPEntity filtrada por “(COM”.
        $ports = Get-WmiObject Win32_PnPEntity -Filter "Caption like '%(COM%'" |
                 Sort-Object Caption
    } catch { $ports = @() }
	
	if (-not $ports) {
	$ports = [System.IO.Ports.SerialPort]::GetPortNames() |
			 ForEach-Object { @{ DeviceID = $_ ; Caption = $_ } }
	}

	
	$jobs = @()
	foreach ($p in $ports) {
	$m = [regex]::Match($p.Caption,'\(COM\d+\)')
	if (-not $m.Success) { continue }
	$com = $m.Value.Trim('()')
	$jobs += Start-Job -Name $com -ArgumentList $com -ScriptBlock {
		param($c)
		& $using:script:venvPython -m esptool --chip auto --port $c --baud 115200 `
			read_mac 2>$null |
		Select-String 'MAC:' |
		ForEach-Object { $_.Line -replace '.*MAC:\s*','' }
	}
	}
	
    # Fallback minimalista si WMI tarda demasiado

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
	
	if ($jobs) { Wait-Job $jobs | Out-Null }
	
	#Wait-Job $jobs | Out-Null
	$macs = @{}
	foreach ($j in $jobs) {
	$macs[$j.Name] = (Receive-Job $j | Select-Object -First 1)
	Remove-Job $j
	}

	Write-Host "`nPuertos con MAC:"
	for ($i = 0; $i -lt $ports.Count; $i++) {
	$p   = $ports[$i]
	$m   = [regex]::Match($p.Caption,'\(COM\d+\)')
	if (-not $m.Success) { continue }
	$com = $m.Value.Trim('()')
	$usb = if ($p.Caption -match '(USB|usb)') { '🔌' } else { '' }
	$mac = $macs[$com]
	$macText = if ($mac) { "MAC $mac" } else { "sin MAC" }
	Write-Host (" {0,2}. {1,-6}  {2} {3}" -f ($i+1), $com, $macText, $usb)
	}


    $sel = Read-Host "Seleccione un puerto por índice"
    $idx = 0
    if (-not [int]::TryParse($sel, [ref]$idx) -or $idx -lt 1 -or $idx -gt $ports.Count) {
        Write-Host " xxx Indice invalido."; Pause; return $null
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
        Write-Host "⚠️  Operacion cancelada."; Pause; return
    }

    if ($ofd.FileNames.Count -ne 3) {
        Write-Host " xxx Debe seleccionar exactamente tres archivos .bin."; Pause; return
    }

    # Identificar cada archivo por su nombre (indiferente a mayúsculas/minúsculas)
    $boot = $ofd.FileNames | Where-Object { $_ -match '(?i)bootloader\.bin$' }
    $part = $ofd.FileNames | Where-Object { $_ -match '(?i)partitions\.bin$' }
    $firm = $ofd.FileNames | Where-Object { $_ -match '(?i)firmware\.bin$'  }

    if (-not ($boot -and $part -and $firm)) {
        Write-Host "❌ Los archivos deben llamarse bootloader.bin, partitions.bin y firmware.bin."
        Pause; return
    }

    $port = SelectCOMPort

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

	
	
    $script:venvPython = $venvPython   # ← resto del script lo usará

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
	Write-Host "⚠️  Primero seleccione un modelo de dispositivo (opción 4 del menú)."
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
        Write-Host "✅ Firmware actualizado exitosamente. Esperando conexión y MAC..."
        & "$venvPython" monitor_serial.py $port
    } else {
        Write-Host "❌ Error actualizando firmware."
    }
    Pause
	SerialMonitor($port)
}

function PrintQRCode 
{
    if (-not (Test-Path "mac_qr.png")) {
        Write-Host "⚠️  No se encontro mac_qr.png. Ejecute el monitor serial primero."
    } else {
        & "$venvPython" print_qr.py
    }
    Pause
}

# Ejecutar herramienta
Start-ESP32Tool


