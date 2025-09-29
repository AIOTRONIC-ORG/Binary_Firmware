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
	Write-Host "Arrancando... Log: $global:LogPath"
	Start-Sleep -Seconds 2
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

#  Define AppRoot al inicio (justo después del BOOT PROBE)
# Reparar $PSScriptRoot si está vacío (caso EXE compilado con ps2exe)
if (-not $PSScriptRoot -or $PSScriptRoot.Trim() -eq '') {
    if ($PSCommandPath -and $PSCommandPath.Trim() -ne '') {
        $script:PSScriptRoot = Split-Path -Parent $PSCommandPath
    } else {
        $script:PSScriptRoot = [System.AppDomain]::CurrentDomain.BaseDirectory.TrimEnd('\','/')
    }
}
Write-Host "PSScriptRoot reparado: $PSScriptRoot"



# -- al principio de main.ps1 --
$script:SelectedDevice = $null   # guarda el modelo elegido

# bloque de instalacion robusto para PSWriteColor en PS 5.1 sin romper otras pcs

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force } catch {}

# 1) normalizar PSModulePath para priorizar modulos de WindowsPowerShell (evitar rutas de PS 7)
$sysMods   = "$env:WINDIR\System32\WindowsPowerShell\v1.0\Modules"
$userMods  = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "WindowsPowerShell\Modules"
$progMods7 = "C:\Program Files\PowerShell\7\Modules"

$paths = ($env:PSModulePath -split ';') | Where-Object { $_ -and $_.Trim() } | Select-Object -Unique
# quitar ruta de PS 7 (causa el error de fullclr dll) solo en esta sesion
$paths = $paths | Where-Object { $_ -ne $progMods7 }
# asegurar rutas clasicas primero
if ($paths -notcontains $sysMods)  { $paths = @($sysMods) + $paths }
if ($paths -notcontains $userMods) { $paths = @($userMods) + $paths }
$env:PSModulePath = ($paths -join ';')

# 2) helper para agregar rutas al PATH del proceso (para pip/wheel)
function Add-ToPath {
    param([string]$PathToAdd)
    if ([string]::IsNullOrWhiteSpace($PathToAdd)) { return }
    if (-not (Test-Path $PathToAdd)) { return }
    $p = ($env:PATH -split ';') | Where-Object { $_ -and $_.Trim() }
    if ($p -notcontains $PathToAdd) { $env:PATH = ($p + $PathToAdd) -join ';' }
}

# agregar Scripts de python embebido si existe (evita warnings wheel.exe/pip.exe)
# ejemplo: si usas python embebido, agrega su Scripts al PATH de esta sesion
# Add-ToPath "C:\Users\Alberto Maldonado\Desktop\Nueva carpeta\embedded_py\py3.11.4\Scripts"
try {
    $pyScripts = Join-Path $PSScriptRoot "embedded_py\py3.11.4\Scripts"
    Add-ToPath $pyScripts
} catch {}

# 3) intentar usar PackageManagement y PowerShellGet solo si estan realmente disponibles en rutas de WindowsPowerShell
$pmImported = $false
$pmPs1 = Join-Path $sysMods "PackageManagement\PackageManagement.psd1"
if (Test-Path $pmPs1) {
    try { Import-Module $pmPs1 -Force -DisableNameChecking -ErrorAction Stop; $pmImported = $true } catch {}
}

$psgetImported = $false
$psgetPs1 = Join-Path $sysMods "PowerShellGet\PowerShellGet.psd1"
if (Test-Path $psgetPs1) {
    try { Import-Module $psgetPs1 -Force -DisableNameChecking -ErrorAction Stop; $psgetImported = $true } catch {}
} else {
    # algunos equipos tienen PowerShellGet solo en documentos del usuario
    $psgetPs1 = Join-Path $userMods "PowerShellGet\PowerShellGet.psd1"
    if (Test-Path $psgetPs1) {
        try { Import-Module $psgetPs1 -Force -DisableNameChecking -ErrorAction Stop; $psgetImported = $true } catch {}
    }
}




function Write-Color {
	param(
		[Parameter(Mandatory=$true)]
		[object[]]$Text,
		[ConsoleColor[]]$Color,
		[switch]$NoNewLine
	)

	$lenT = if ($Text) { $Text.Count } else { 0 }
	$lenC = if ($Color) { $Color.Count } else { 0 }

	for ($i = 0; $i -lt $lenT; $i++) {
		$seg = [string]$Text[$i]
		if ([string]::IsNullOrEmpty($seg)) { continue }

		if ($lenC -gt 0) {
			$idx = if ($i -lt $lenC) { $i } else { $lenC - 1 }
			Write-Host -NoNewline -ForegroundColor $Color[$idx] $seg
		} else {
			Write-Host -NoNewline $seg
		}
	}

	if (-not $NoNewLine) { Write-Host }
}


# fin de la seccion 6

# fin del bloque


# ejemplo de uso que ya no deberia romper
# Write-Color -Text "PSWriteColor listo (o fallback activo)" -Color Green



function ShowMainMenu {
    do {
        Clear-Host
        Write-Color -Text "==========================================", " " -Color Cyan, White
        Write-Color -Text "       AIOTRONIC Firmware Manager         ", " " -Color Yellow, White
        Write-Color -Text "==========================================", " " -Color Cyan, White
        Write-Color ""

        Write-Color -Text "  [1] ", "Flash Erase " -Color Cyan, Green
        Write-Color -Text "  [2] ", "Actualizar Firmware desde SERVIDOR y Monitor Serial" -Color Cyan, Green
        Write-Color -Text "  [3] ", "Imprimir Codigo QR" -Color Cyan, Green
        Write-Color -Text "  [4] ", "Seleccionar Modelo de Dispositivo" -Color Cyan, Green
        Write-Color -Text "  [5] ", "Cargar Firmware LOCAL (.bin)" -Color Cyan, Green
        Write-Color -Text "  [6] ", "Serial monitor" -Color Cyan, Green
        Write-Color -Text "  [7] ", "Resetear la consola (eliminar Python embebido Offline)" -Color Cyan, Green
        Write-Color -Text "  [8] ", "Obtener archivos de AIOcore" -Color Cyan, Green
        Write-Color -Text "  [9] ", "Salir" -Color Cyan, Green

        Write-Color ""
        Write-Color -Text "==========================================" -Color Cyan
        Write-Color ""

        $choice = Read-Host "Seleccione una opcion"

        switch ($choice) {
            "1" { FlashESP32Erase }
            "2" { SelectDeviceModel; UpdateFirmwareAndMonitor }
            "3" { PrintQRCode }
            "4" { SelectDeviceModel }
            "5" { LoadLocalFirmware }
            "6" { SerialMonitor }
            "7" { ResetEmbeddedPython }
            "8" { $com = SelectCOMPort; Get-ESP32SpiffsFile -Port $com -Trigger -RemotePath "/snap.jpg" }
            "9" { return }
            default {
                Write-Color -Text "Opcion invalida" -Color Red
                Pause
            }
        }
    } while ($true)
}


function ResetEmbeddedPython {
    # Usa el reparado y, si por algo viene vacío, cae al directorio del EXE
    $root = if ($script:PSScriptRoot -and $script:PSScriptRoot.Trim() -ne '') {
        $script:PSScriptRoot
    } elseif ($PSCommandPath -and $PSCommandPath.Trim() -ne '') {
        Split-Path -Parent $PSCommandPath
    } else {
        [System.AppDomain]::CurrentDomain.BaseDirectory.TrimEnd('\','/')
    }

    $embedDir = Join-Path $root "embedded_py"
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
    Stop-Process -Id $PID
}


function Install-EmbeddedPython {
    param(
        [string]$Version = "3.11.4",
		[string]$BaseDir
    )

    # === Resolver BaseDir aquí, ya con PSScriptRoot reparado ===
    if ([string]::IsNullOrWhiteSpace($BaseDir)) {
        $root = if ($PSScriptRoot -and $PSScriptRoot.Trim() -ne '') {
            $PSScriptRoot
        } elseif ($PSCommandPath -and $PSCommandPath.Trim() -ne '') {
            Split-Path -Parent $PSCommandPath
        } else {
            [System.AppDomain]::CurrentDomain.BaseDirectory.TrimEnd('\','/')
        }
        $BaseDir = Join-Path $root 'embedded_py'
    }

    $zipName   = "python-$Version-embed-amd64.zip"
    $zipUrl    = "https://www.python.org/ftp/python/$Version/$zipName"
    $pythonDir = Join-Path $BaseDir "py$Version"
    $pythonExe = Join-Path $pythonDir "python.exe"


    if (-not (Test-Path $pythonExe)) {
        Write-Host " Descargando Python $Version (embeddable)..."
        New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null
		
		#Esta linea Get-Item obtiene la carpeta creada y luego le agrega el atributo 'Hidden', haciendo que no se muestre por defecto en el 
		#explorador de archivos de Windows.
	
		(Get-Item $BaseDir).Attributes += 'Hidden' ## hacerlo carpeta oculta
	
	
        try{Invoke-WebRequest $zipUrl -OutFile $zipName}
		catch{Write-Error "Embedded py no pudo ser instalado por falta de conexion a internet ! "}
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




function Wait-ForDevice {
    param (
        [string]$port
    )
    Write-Host "Waiting for device to reconnect on $port..."
    while ($true) {
        try {
            $sp = New-Object System.IO.Ports.SerialPort $port,115200,'None',8,'One'
            $sp.Open()
            $sp.Close()
            Write-Host "Device reconnected on $port"
            return
        } catch {
            Start-Sleep -Seconds 1
        }
    }
}

function Monitor-Serial {
    param ( [string]$port )

    $macPattern = '^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$'

    Write-Host "Seleccione una opcion:"
    Write-Host "1. Desconectar dispositivo manualmente e iniciar monitoreo serial"
    Write-Host "2. Iniciar monitoreo serial directamente (usualmente no permitido)"
    Write-Host "3. Reiniciar dispositivo (sin desconectarlo) e iniciar monitoreo serial"
    $choice = Read-Host "Ingrese 1, 2 o 3"

    if ($choice -eq '1') {
        Write-Host "Esperando que el dispositivo se desconecte..."
        while ($true) {
            try {
                $sp = New-Object System.IO.Ports.SerialPort $port,115200,'None',8,'One'
                $sp.Open()
                $sp.Close()
                Start-Sleep -Seconds 1
            } catch {
                Write-Host "Dispositivo desconectado. Esperando reconexion..."
                break
            }
        }
        Wait-ForDevice $port
    } elseif ($choice -eq '3') {
        try {
            $sp = New-Object System.IO.Ports.SerialPort $port,115200,'None',8,'One'
            $sp.ReadTimeout = 500
            $sp.Open()
            Write-Host "Reiniciando dispositivo via DTR/RTS..."

            # intento 1: pulso rapido en DTR (suele resetear ESP32)
            $sp.DtrEnable = $true
            Start-Sleep -Milliseconds 50
            $sp.DtrEnable = $false

            # intento 2: breve pulso combinado DTR/RTS (segun placa)
            Start-Sleep -Milliseconds 50
            $sp.RtsEnable = $true
            $sp.DtrEnable = $true
            Start-Sleep -Milliseconds 50
            $sp.RtsEnable = $false
            $sp.DtrEnable = $false

            # breve espera para que el firmware reinicie
            Start-Sleep -Seconds 2
        } catch {
            Write-Host "Error al intentar reiniciar el dispositivo: $_"
            return
        } finally {
            if ($sp -and $sp.IsOpen) { $sp.Close() }
        }
    } elseif ($choice -ne '2') {
        Write-Host "Opcion no valida. Cancelando operacion."
        return
    }

    try {
        $sp = New-Object System.IO.Ports.SerialPort $port,115200,'None',8,'One'
        $sp.ReadTimeout = 1000

        # PONER ESTO ANTES de $sp.Open() (y elimina tu bloque anterior de historial)
        # $historyDir = Join-Path ".\historial"
        #  Define AppRoot al inicio (justo después del BOOT PROBE)
      
      # REEMPLAZA tu bloque de "Reparar $PSScriptRoot..." por ESTO
        # obtiene de forma robusta la carpeta del EXE (ps2exe) o del .ps1
        # REEMPLAZA tu bloque de deteccion de carpeta por este (poner ANTES de $sp.Open())

        # resuelve carpeta base del script o exe, evitando System32
        $baseDir = $null

        if ($PSScriptRoot -and $PSScriptRoot.Trim()) {
            $baseDir = $PSScriptRoot.TrimEnd('\','/')
        }
        elseif ($PSCommandPath -and $PSCommandPath.Trim()) {
            $baseDir = (Split-Path -Parent $PSCommandPath).TrimEnd('\','/')
        }
        elseif ($MyInvocation -and $MyInvocation.MyCommand -and $MyInvocation.MyCommand.Path) {
            $baseDir = (Split-Path -Parent $MyInvocation.MyCommand.Path).TrimEnd('\','/')
        }
        elseif ([System.AppDomain]::CurrentDomain -and [System.AppDomain]::CurrentDomain.FriendlyName -like "*.exe") {
            # ps2exe: base del exe
            $baseDir = [System.AppDomain]::CurrentDomain.BaseDirectory.TrimEnd('\','/')
        }
        else {
            # ultimo recurso: si se esta dentro de un .exe cualquiera
            try {
                $procExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
                if ($procExe -and $procExe.Trim()) { $baseDir = (Split-Path -Parent $procExe).TrimEnd('\','/') }
            } catch {}
            if (-not $baseDir) { $baseDir = (Get-Location).Path.TrimEnd('\','/') }
        }

        Write-Host "BaseDir: $baseDir"

        $historyDir = Join-Path $baseDir "historial"
        if (-not (Test-Path -LiteralPath $historyDir)) {
            New-Item -ItemType Directory -Path $historyDir -Force | Out-Null
        }

        $fileSafePort = ($port -replace '[\\/:*?"<>|]', '_')
        $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
        $logPath = Join-Path $historyDir ("serial_{0}_{1}.txt" -f $fileSafePort, $timestamp)
        New-Item -ItemType File -Path $logPath -Force | Out-Null
        $sw = New-Object System.IO.StreamWriter($logPath, $true, [System.Text.Encoding]::UTF8)
        $sw.AutoFlush = $true
        Write-Host "Guardando en: $logPath"


        $sp.Open()


        # limpiar buffer por si quedaron bytes del reinicio
        try { $sp.DiscardInBuffer() } catch {}

        Write-Host "Monitoreando por direccion MAC... (presione 'q' o Enter para detener)"
        while ($true) {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq 'Enter' -or $key.KeyChar -eq 'q') {
                    Write-Host "Deteniendo monitoreo..."
                    break
                }
            }
            try {
                if ($sp.BytesToRead -gt 0) {
                    $line = $sp.ReadLine().Trim()
                    if ($line) {
                        Write-Host "Recibido: $line"
                        # dentro del while, justo despues de: Write-Host "Recibido: $line"
                        $sw.WriteLine($line)

                        if ($line -match $macPattern) {
                            $mac = $line.ToUpper()
                            Generate-QRImage $mac
                        }
                    }
                }
            } catch {
                # ignorar timeouts
            }
        }
            # al salir del while, antes de $sp.Close()
        if ($sw) { $sw.Close() }
        $sp.Close()
    } catch {
        Write-Host "Ocurrio un error: $_"
        # opcional: en el catch del bloque de monitoreo, antes del Write-Host de error
        if ($sw) { $sw.Close() }

    }
    finally {
    if ($sp -and $sp.IsOpen) { $sp.Close() }
    if ($sw) { $sw.Close() }
    }
}


# Ejemplo de uso:
# Monitor-Serial "COM4
function Get-ESP32SpiffsFile {
    <#
      Pull a file dumped over serial by your ESP32 (SPIFFS -> PC).
      Expected device protocol:
        1) prints:  __BEGIN__ <remote_path> <size>\n
        2) sends exactly <size> raw bytes (binary)
        3) optionally prints: __END__\n

      Usage examples:
        Get-ESP32SpiffsFile -Port COM7 -Trigger -RemotePath "/snap.jpg"
        Get-ESP32SpiffsFile -Port COM7 -OutputPath "C:\tmp\snap.jpg"
        Get-ESP32SpiffsFile -Port COM7   # passive: waits for __BEGIN__ already sent by device
    #>
    param(
        [Parameter(Mandatory=$false)][string]$Port,
        [Parameter(Mandatory=$false)][int]$Baud = 460800,
        [Parameter(Mandatory=$false)][switch]$Trigger,       # if set, send "DUMP <RemotePath>" to device
        [Parameter(Mandatory=$false)][string]$RemotePath = "/snap.jpg",
        [Parameter(Mandatory=$false)][string]$OutputPath,
        [Parameter(Mandatory=$false)][int]$HeaderTimeoutMs = 60000,
        [Parameter(Mandatory=$false)][int]$ReadChunk = 4096, # bytes per read
        [Parameter(Mandatory=$false)][int]$ReadIdleTimeoutMs = 60000 # abort if no bytes during body
    )

    # resolve base directory (script or exe) for default downloads folder
    $baseDir = $null
    if ($script:PSScriptRoot -and $script:PSScriptRoot.Trim()) { $baseDir = $script:PSScriptRoot.TrimEnd('\','/') }
    elseif ($PSCommandPath -and $PSCommandPath.Trim()) { $baseDir = (Split-Path -Parent $PSCommandPath).TrimEnd('\','/') }
    else { $baseDir = (Get-Location).Path.TrimEnd('\','/') }

    # choose default output path if not provided
    if (-not $OutputPath -or -not $OutputPath.Trim()) {
        $downloads = Join-Path $baseDir "downloads"
        if (-not (Test-Path -LiteralPath $downloads)) { New-Item -ItemType Directory -Path $downloads -Force | Out-Null }
        $name = ([IO.Path]::GetFileName($RemotePath))
        if (-not $name) { $name = "spiffs.bin" }
        $stamp = (Get-Date -Format "yyyyMMdd_HHmmss")
        $OutputPath = Join-Path $downloads ("{0}_{1}" -f $stamp, $name)
    }

    # pick port if not given
    if (-not $Port -or -not $Port.Trim()) {
        $ports = [System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object
        if ($ports.Count -eq 0) { throw "No serial ports found." }
        elseif ($ports.Count -eq 1) { $Port = $ports[0] }
        else {
            Write-Host "Available ports: $($ports -join ', ')"
            $Port = Read-Host "Enter port (e.g., COM7)"
        }
    }

    # helpers
    $headerRegex = '^__BEGIN__\s+(\S+)\s+(\d+)\s*$'

    $sp = $null
    $fs = $null
    $sw = $null
    try {
        $sp = New-Object System.IO.Ports.SerialPort $Port,$Baud,'None',8,'One'
        $sp.NewLine = "`n"
        $sp.ReadTimeout = 1000
        $sp.WriteTimeout = 2000
        $sp.Open()

        # flush any stale input
        try { $sp.DiscardInBuffer() } catch {}

        # optional active trigger
        if ($Trigger) {
            $cmd = "DUMP $RemotePath`n"
            [void]$sp.Write($cmd)
            Start-Sleep -Milliseconds 150
        }

        # wait for header line with overall timeout
        $t0 = [Environment]::TickCount
        $header = $null
        while ($true) {
            try {
                $line = $sp.ReadLine()
                if ($line) {
                    $line = $line.Trim()
                    if ($line -match $headerRegex) {
                        $header = $line
                        break
                    } else {
                        # ignore other text noise
                        Write-Host "[info] $line"
                    }
                }
            } catch {
                # Read timeout. Check global timeout.
                if (([Environment]::TickCount - $t0) -ge $HeaderTimeoutMs) {
                    throw "Timed out waiting for __BEGIN__ header from device."
                }
            }
        }

        # parse header
        $m = [regex]::Match($header, $headerRegex)
        $remote = $m.Groups[1].Value
        [long]$expected = [int64]$m.Groups[2].Value
        if ($expected -lt 0) { throw "Invalid size in header: $expected" }
        Write-Host "[begin] remote=$remote size=$expected -> $OutputPath"

        # prepare output stream
        $fs = [System.IO.File]::Open($OutputPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $buf = New-Object byte[] $ReadChunk
        [long]$remaining = $expected
        $lastDataTick = [Environment]::TickCount

        # read exactly expected bytes (binary safe)
        while ($remaining -gt 0) {
            $want = [int]([Math]::Min($buf.Length, $remaining))
            $read = 0
            # Read may return less than requested; loop until at least 1 byte or small timeout
            while ($read -eq 0) {
                $n = $sp.BaseStream.Read($buf, 0, $want)
                if ($n -gt 0) {
                    $fs.Write($buf, 0, $n)
                    $remaining -= $n
                    $lastDataTick = [Environment]::TickCount
                    break
                } else {
                    if (([Environment]::TickCount - $lastDataTick) -ge $ReadIdleTimeoutMs) {
                        throw "Timed out during body read (no data for $ReadIdleTimeoutMs ms)."
                    }
                    Start-Sleep -Milliseconds 10
                }
            }
        }
        $fs.Flush()

        # optional: read tail markers without blocking long
        $sp.ReadTimeout = 200
        try {
            $tail = $sp.ReadExisting()
            if ($tail) { Write-Host "[tail] $($tail.Trim())" }
        } catch {}

        Write-Host "[done] wrote $expected bytes to $OutputPath"
        return $OutputPath
    }
    catch {
        Write-Host "[error] $($_.Exception.Message)"
        throw
    }
    finally {
        if ($fs) { $fs.Dispose() }
        if ($sp) {
            try { if ($sp.IsOpen) { $sp.Close() } } catch {}
            $sp.Dispose()
        }
    }
}


function SerialMonitor {
	
	param(
        [string]$port
    )
	
    $port = SelectCOMPort
    if (-not $port) { return }

    Write-Host "\n▶️  Iniciando monitor serial en $port...\n"
	Monitor-Serial $port
    #& $script:venvPython "monitor_serial.py" $port

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

# returns a #COM6
function SelectCOMPort {

    param(
        [switch]$Verbose
    )

    function ProbarCOMsRapido 
    {
        param([string[]]$lista)

        $macs  = @{}
        $fails = @{}

        if ($lista) {
            Write-Host "`nLeyendo MACs de puertos: $($lista -join ', ')..."
            foreach ($com in $lista) {
                Write-Host ("Probing {0,-5}…" -f $com) -NoNewline

                $job = Start-Job -ScriptBlock {
                    param($py, $port)
                    & $py -m esptool `
                          --chip auto --port $port --baud 115200 `
                          --before default_reset --after no_reset `
                          --connect-attempts 5 read_mac 2>&1
                } -ArgumentList $script:venvPython, $com
				
				# TIMEOUT DE 1 SEGUNDOS ::::
                if (Wait-Job $job -Timeout 1) {
                    $out = Receive-Job $job
                    Remove-Job $job

                    if ($Verbose) { $out | ForEach-Object { Write-Host "    $_" } }

                    $outStr = $out -join "`n"
                    if ($outStr -match 'MAC:\s*([0-9A-Fa-f:]{2}(?::[0-9A-Fa-f]{2}){5})') {
                        $macs[$com] = $Matches[1]
                        Write-Host "  OK $($macs[$com])"
                    } else {
                        $fails[$com] = "Sin respuesta valida"
                        Write-Host "  error: sin respuesta valida"
                    }
                } else {
                    Stop-Job $job | Out-Null
                    Remove-Job $job
                    $fails[$com] = "timeout"
                    Write-Host "  timeout"
                }
            }
        }

        return @{ macs = $macs ; fails = $fails }
    }

    Write-Host "`nSeleccione modo para elegir puerto COM:"
    Write-Host "1. Elegir por indice"
    Write-Host "2. Ingresar COM manualmente (ej: COM4)"
    $modo = Read-Host "Opcion"

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

    $resultado = ProbarCOMsRapido -lista $comPortsToCheck
    $macs  = $resultado.macs
    $fails = $resultado.fails

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

    if ($modo -eq "2") {
        $manual = Read-Host "Ingrese el nombre del puerto COM (ej: COM4 o com14) (minusculas permitidas)"
        if ($manual -match '^COM\d+$') {
            return $manual
        } else {
            Write-Host "Puerto COM invalido."; Pause; return $null
        }
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
	
	# Tras tu write_flash, añade:
	# CRUCIAL for failings in charge from aio.exe of main.ps1, ota partition content, avoids you to enter the factory partition
	# so it appears the code has not been charged !!! 
	# ( por eso requerias flashear antes de cargar codigo, 
	# solo si en ese dispositivo ya habias hecho una carga ota por lo menos una vez desde la ultima vez q fue flasheado ) 
	
	# SOLO BORRA UNA PARTE DE LA FLASH ( LA OTA DATA ) interfiere con el siguiente inicio q debe ser en factory mode si o si
	# pero relax, si se podra seguir haciendo cargas de ota, solo estas borrando el contenido de la direccion , no el partitions.bin
	& $venvPython -m esptool --chip esp32s3 --port $port erase_region 0xE000 0x2000
	if ($LASTEXITCODE -eq 0) {
		Write-Host "✅ otadata borrado correctamente"
	} else {
		Write-Host "❌ Error al borrar otadata"
	}


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
	
	Monitor-Serial $port
}


function Start-ESP32Tool {
    # $ErrorActionPreference = "Stop"

    # Siempre usa TU copia embebida ↴
    # $embeddedPy = Install-EmbeddedPython "3.11.4"
	
	
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
    #Invoke-WebRequest "https://raw.githubusercontent.com/AIOTRONIC-ORG/Binary_Firmware/main/monitor_serial.py" -OutFile "monitor_serial.py"
    #Invoke-WebRequest "https://raw.githubusercontent.com/AIOTRONIC-ORG/Binary_Firmware/main/print_qr.py"      -OutFile "print_qr.py"

    
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

function FlashESP32Erase 
{
    $port = SelectCOMPort
    & "$venvPython" -m esptool --chip esp32s3 --port $port erase_flash
    Pause
}

function UpdateFirmwareAndMonitor 
{
	
	if (-not $script:SelectedDevice) {
	Write-Host "Primero seleccione un modelo de dispositivo (opción 4 del menu)."
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
        Write-Host "Firmware actualizado exitosamente. Esperando conexion y MAC..."
        #& "$venvPython" monitor_serial.py $port
		Monitor-Serial $port
    } else {
        Write-Host "Error actualizando firmware."
    }
    Pause
	SerialMonitor($port)
}

# =========================
#  Utilidad: cargar QRCoder
# =========================
function Get-QRCoder {
    param(
        [string]$Version = '1.4.3'
    )
    $base = Join-Path (Resolve-Path ".") "qrlib"
    New-Item -ItemType Directory -Force -Path $base | Out-Null
    $pkg  = Join-Path $base "QRCoder.$Version.nupkg"

    if (-not (Test-Path $pkg)) {
        Write-Host "Descargando QRCoder $Version desde NuGet..."
        Invoke-WebRequest -UseBasicParsing -Uri "https://www.nuget.org/api/v2/package/QRCoder/$Version" -OutFile $pkg
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $extDir = Join-Path $base "QRCoder.$Version"
    if (-not (Test-Path $extDir)) {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($pkg, $extDir)
    }

    $dll = Get-ChildItem -Path $extDir -Recurse -Filter QRCoder.dll |
           Where-Object { $_.FullName -match 'netstandard' } |
           Select-Object -First 1
    if (-not $dll) { throw "No se encontró QRCoder.dll dentro del paquete." }

    # Cargar solo si no está cargado
    if (-not ([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.Location -eq $dll.FullName })) {
        Add-Type -Path $dll.FullName
    }
}

# =========================================
#  Selección de COM y lectura de MAC (final)
# =========================================

function Select-COMMac {
    param([switch]$Verbose)

    function ProbarCOMsRapido {
        param([string[]]$lista, [switch]$Verbose)
        $macs  = @{}
        $fails = @{}

        if ($lista) {
            Write-Host "`nLeyendo MACs de puertos: $($lista -join ', ')..."
            foreach ($com in $lista) {
                Write-Host ("Probing {0,-6}…" -f $com) -NoNewline

                $job = Start-Job -ScriptBlock {
                    param($py, $port)
                    & $py -m esptool `
                          --chip auto --port $port --baud 115200 `
                          --before default_reset --after no_reset `
                          --connect-attempts 5 read_mac 2>&1
                } -ArgumentList $script:venvPython, $com

                # Aumenta un poco el timeout para dar tiempo a abrir puerto
                if (Wait-Job $job -Timeout 3) {
                    $out = Receive-Job $job
                    Remove-Job $job
                    if ($Verbose) { $out | ForEach-Object { Write-Host "    $_" } }
                    $outStr = $out -join "`n"

                    if ($outStr -match 'MAC:\s*([0-9A-Fa-f:]{2}(?::[0-9A-Fa-f]{2}){5})') {
                        $macs[$com] = $Matches[1]
                        Write-Host "  OK $($macs[$com])"
                    } else {
                        $fails[$com] = "sin respuesta válida"
                        Write-Host "  error: sin respuesta válida"
                    }
                } else {
                    Stop-Job $job | Out-Null
                    Remove-Job $job
                    $fails[$com] = "timeout"
                    Write-Host "  timeout"
                }
            }
        }
        return @{ macs = $macs ; fails = $fails }
    }

    # 1) Obtener lista cruda
    try {
        $portsRaw = Get-WmiObject Win32_PnPEntity -Filter "Caption like '%(COM%'" | Sort-Object Caption
    } catch { $portsRaw = @() }

    if (-not $portsRaw) {
        $portsRaw = [System.IO.Ports.SerialPort]::GetPortNames() |
                    ForEach-Object { @{ DeviceID = $_ ; Caption = $_ } }
    }
    if (-not $portsRaw) { Write-Host "No se encontraron puertos COM."; return $null }

    # 2) Filtrar solo entradas con (COMx) y sin Bluetooth
    $comRegex = '\(COM\d+\)'
    $items = @()
    foreach ($p in $portsRaw) {
        if ($p.Caption -match 'Bluetooth') { continue }
        $m = [regex]::Match($p.Caption, $comRegex)
        if (-not $m.Success) { continue }
        $com = $m.Value.Trim('()')
        $items += [pscustomobject]@{
            ComPort = $com
            Caption = $p.Caption
        }
    }

    if (-not $items) { Write-Host "No hay dispositivos COM válidos."; return $null }

    # 3) Probar lectura rápida de MACs sobre la lista filtrada
    $resultado = ProbarCOMsRapido -lista ($items.ComPort) -Verbose:$Verbose
    $macs  = $resultado.macs
    $fails = $resultado.fails

    # 4) Mostrar SOLO la lista filtrada y numerada
    Write-Host "`nPuertos COM disponibles:"
    for ($i = 0; $i -lt $items.Count; $i++) {
        $row = $items[$i]
        Write-Host (" {0,2}. {1,-6}  {2}" -f ($i+1), $row.ComPort, $row.Caption)
    }

    Write-Host "`nPuertos con MAC o error:"
    for ($i = 0; $i -lt $items.Count; $i++) {
        $row = $items[$i]
        $info = if ($macs.ContainsKey($row.ComPort)) { "MAC $($macs[$row.ComPort]) OK" }
                elseif ($fails.ContainsKey($row.ComPort)) { "error: $($fails[$row.ComPort])" }
                else { "sin intento" }
        Write-Host (" {0,2}. {1,-6}  {2}" -f ($i+1), $row.ComPort, $info)
    }

    # 5) Selección por índice sobre la lista filtrada
    $sel = Read-Host "`nSeleccione un puerto por indice"
    $idx = 0
    if (-not [int]::TryParse($sel, [ref]$idx) -or $idx -lt 1 -or $idx -gt $items.Count) {
        Write-Host "Indice inválido."; return $null
    }
    $selected = $items[$idx-1]
    $selectedCom = $selected.ComPort

    # 6) Obtener MAC definitiva (si no llegó en el barrido)
    $mac = $macs[$selectedCom]
    if (-not $mac) {
        Write-Host "Leyendo MAC de $selectedCom..."
        $out = & $script:venvPython -m esptool `
              --chip auto --port $selectedCom --baud 115200 `
              --before default_reset --after no_reset `
              --connect-attempts 5 read_mac 2>&1
        $outStr = $out -join "`n"
        if ($outStr -match 'MAC:\s*([0-9A-Fa-f:]{2}(?::[0-9A-Fa-f]{2}){5})') {
            $mac = $Matches[1]
        } else {
            Write-Host "No se pudo obtener la MAC de $selectedCom."; return $null
        }
    }

    # 7) Normalizar a AA:BB:CC:DD:EE:FF
    $mac = ($mac -replace '[^0-9A-Fa-f]', '').ToUpper()
    if ($mac.Length -eq 12) {
        $pairs = for ($i=0; $i -lt 12; $i+=2) { $mac.Substring($i,2) }
        $mac = ($pairs -join ':')
    }
    return $mac
}



# =========================================
#  Generar QR con el texto "OK <MAC>"
# =========================================
function Generate-QRImage {
    param (
        [string]$Mac
    )
    if (-not $Mac) 
    {
        $Mac = Select-COMMac
        if (-not $Mac) { Write-Host "Operacion cancelada."; return }
    }

    # Cargar QRCoder
    Get-QRCoder -Version '1.4.3'

    # Construir texto final
    $texto  = "$Mac"

    # $salida = "mac_qr.png"  # o si prefieres: "qr_$($Mac.Replace(':','')) .png"
    # $basePath = Split-Path -Parent $MyInvocation.MyCommand.Path
    # $basePath = $PSScriptRoot
    # $basePath = if ($PSScriptRoot) { $PSScriptRoot } else { "$env:USERPROFILE\Documents" }
# resuelve carpeta base del script o exe, evitando System32
    $baseDir = $null

    if ($PSScriptRoot -and $PSScriptRoot.Trim()) {
        $baseDir = $PSScriptRoot.TrimEnd('\','/')
    }
    elseif ($PSCommandPath -and $PSCommandPath.Trim()) {
        $baseDir = (Split-Path -Parent $PSCommandPath).TrimEnd('\','/')
    }
    elseif ($MyInvocation -and $MyInvocation.MyCommand -and $MyInvocation.MyCommand.Path) {
        $baseDir = (Split-Path -Parent $MyInvocation.MyCommand.Path).TrimEnd('\','/')
    }
    elseif ([System.AppDomain]::CurrentDomain -and [System.AppDomain]::CurrentDomain.FriendlyName -like "*.exe") {
        # ps2exe: base del exe
        $baseDir = [System.AppDomain]::CurrentDomain.BaseDirectory.TrimEnd('\','/')
    }
    else {
        # ultimo recurso: si se esta dentro de un .exe cualquiera
        try {
            $procExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            if ($procExe -and $procExe.Trim()) { $baseDir = (Split-Path -Parent $procExe).TrimEnd('\','/') }
        } catch {}
        if (-not $baseDir) { $baseDir = (Get-Location).Path.TrimEnd('\','/') }
    }


    $salida = Join-Path $baseDir "mac_qr.png"
    $macFile = Join-Path $baseDir "mac_address.txt"


    # Generar PNG en memoria y grabar a archivo
    $gen   = [QRCoder.QRCodeGenerator]::new()
    $qr    = $gen.CreateQrCode($texto, [QRCoder.QRCodeGenerator+ECCLevel]::Q)
    $pngQR = [QRCoder.PngByteQRCode]::new($qr)
    # $bytes = $pngQR.GetGraphic(10, "#000000", "#FFFFFF", $true)  # 10 px por módulo
   $dark = [byte[]](0, 0, 0, 255)
    $light = [byte[]](255, 255, 255, 255)
    $bytes = $pngQR.GetGraphic(10, $dark, $light, $true)


    # [System.IO.File]::WriteAllBytes($salida, $bytes)
    # $Mac | Out-File -Encoding ascii "mac_address.txt"
    [System.IO.File]::WriteAllBytes($salida, $bytes)
    $Mac | Out-File -Encoding ascii $macFile


    Write-Host "QR guardado en $salida con contenido: $texto"
    Write-Host "MAC address saved: $Mac"
    try { & open $salida } catch {}
}

# =====================
#  Acción "imprimir QR"
# =====================
function PrintQRCode {
    # Flujo directo: selecciona COM, lee MAC, genera QR
    Generate-QRImage
    Pause
}

# ===================== MAIN WRAPPER (PEGAR AL FINAL) =====================
# Hacemos el log y la pausa SIEMPRE, pase lo que pase

# Si tu probe no creó $global:LogPath, crea uno en %TEMP%
if (-not $global:LogPath) {
    $global:LogDir  = Join-Path $env:TEMP 'aio-exe-log'
    $null = New-Item -ItemType Directory -Force -Path $global:LogDir -ErrorAction SilentlyContinue
    $global:LogPath = Join-Path $global:LogDir ("boot_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
}

function Write-LogHard([string]$msg) {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    try { Add-Content -Path $global:LogPath -Value "[$ts] $msg" -Encoding UTF8 } catch {}
    try { Write-Host $msg } catch {}
}

try {
    Write-LogHard "== ENTER Start-ESP32Tool =="
    # *** MUY IMPORTANTE ***: NO sobrescribas $script:venvPython con $venvPython
    # Debe quedar así dentro de Start-ESP32Tool:
    #   $script:venvPython = Install-EmbeddedPython "3.11.4"

    Start-ESP32Tool
    Write-LogHard "== Start-ESP32Tool returned =="
}
catch {
    Write-LogHard ("ERROR: " + ($_ | Out-String))
}
finally {
    Write-LogHard "== FINALLY: pausing =="
    Write-Host "`nLog: $global:LogPath"
    Write-Host "Presiona ENTER para salir..."
    try { [void][System.Console]::ReadLine() } catch { Read-Host | Out-Null }
}
# ========================================================================
