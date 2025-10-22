$global:mcu = "esp32s3"
$global:model = "EA01J"
$script:baseDir = $null  # carpeta base del script o exe (resuelta por Set-BaseDir)
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

function Set-BaseDir {
<#
    .SYNOPSIS
        Resuelve la carpeta base del script o exe y la guarda en $script:baseDir.

    .DESCRIPTION
        Detecta la carpeta segun contexto: $PSScriptRoot, $PSCommandPath, $MyInvocation, o exe (ps2exe).
        Si todo falla usa la ruta del proceso o la ubicacion actual. Evita devolver Windows\System32.
        Asigna el resultado en $script:baseDir y lo retorna.

    .EXAMPLE
        Set-BaseDir
        # Calcula y asigna $script:baseDir, mostrando la ruta resuelta.

    .EXAMPLE
        $null = Set-BaseDir
        # Solo inicializa $script:baseDir en segundo plano sin imprimir.

    .NOTES
        ADVERTENCIA: si el entorno fuerza System32 como ubicacion, se hace fallback a Get-Location.
    .FECHA
        2025-10-22
#>
    [CmdletBinding()]
    param()

    # helper: normaliza y trim de separadores finales
    function _Norm {
        param([string]$p)
        if ([string]::IsNullOrWhiteSpace($p)) { return $null }
        return $p.Trim().TrimEnd('\','/')
    }

    try {
        # resuelve carpeta base del script o exe, evitando System32
        $baseDir = $null

        # 1) contexto de script
        if ($PSScriptRoot -and $PSScriptRoot.Trim()) {
            $baseDir = _Norm $PSScriptRoot
        }
        elseif ($PSCommandPath -and $PSCommandPath.Trim()) {
            $baseDir = _Norm (Split-Path -Parent $PSCommandPath)
        }
        elseif ($MyInvocation -and $MyInvocation.MyCommand -and $MyInvocation.MyCommand.Path) {
            $baseDir = _Norm (Split-Path -Parent $MyInvocation.MyCommand.Path)
        }
        # 2) ejecutable empaquetado (ps2exe)
        elseif ([System.AppDomain]::CurrentDomain -and [System.AppDomain]::CurrentDomain.FriendlyName -like "*.exe") {
            $baseDir = _Norm ([System.AppDomain]::CurrentDomain.BaseDirectory)
        }
        # 3) ultimo recurso: del proceso o ubicacion actual
        else {
            try {
                $procExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
                if ($procExe -and $procExe.Trim()) {
                    $baseDir = _Norm (Split-Path -Parent $procExe)
                }
            } catch {
                # si no se puede leer MainModule, ignorar
            }
            if (-not $baseDir) {
                $baseDir = _Norm ((Get-Location).Path)
            }
        }

        # si por cualquier razon caimos en System32, usar ubicacion actual
        if ($baseDir -match '\\Windows\\System32($|\\)') {
            $fallback = _Norm ((Get-Location).Path)
            if ($fallback -and ($fallback -notmatch '\\Windows\\System32($|\\)')) {
                $baseDir = $fallback
            }
        }

        # si aun no tenemos algo, fuerza Get-Location
        if (-not $baseDir) {
            $baseDir = _Norm ((Get-Location).Path)
        }

        # expone globalmente
        $script:baseDir = $baseDir

        # devuelve tambien por pipeline
        return $script:baseDir
    }
    catch {
        # en error, intenta al menos fijar algo sensato
        try { $script:baseDir = _Norm ((Get-Location).Path) } catch {}
        return $script:baseDir
    }
} # fin de la funcion Set-BaseDir



# Lightweight log helper
function Write-Log([string]$msg) {
    $ts = Get-Date -Format 'dd-MM-yy HH:mm:ss.fff'
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
        Write-Color -Text "  [2] ", "Actualizar Firmware desde SERVIDOR" -Color Cyan, Green
        Write-Color -Text "  [3] ", "Imprimir Codigo QR" -Color Cyan, Green
        Write-Color -Text "  [4] ", "Seleccionar Modelo de Dispositivo" -Color Cyan, Green
        Write-Color -Text "  [5] ", "Cargar Firmware LOCAL (.bin)" -Color Cyan, Green
        Write-Color -Text "  [6] ", "Serial monitor" -Color Cyan, Green
        Write-Color -Text "  [7] ", "Resetear la consola (eliminar Python embebido Offline)" -Color Cyan, Green
        Write-Color -Text "  [8] ", "Obtener archivos de AIOcore" -Color Cyan, Green
        Write-Color -Text "  [9] ", "Ver historial" -Color Cyan, Green
        Write-Color -Text "  [10] ", "Salir" -Color Cyan, Green

        Write-Color ""
        Write-Color -Text "==========================================" -Color Cyan
        Write-Color ""

        $choice = Read-Host "Seleccione una opcion"

        switch ($choice) {
            "1" { FlashESP32Erase }
            "2" { SelectDeviceModel; UpdateFromAioServer }
            "3" { PrintQRCode }
            "4" { SelectDeviceModel }
            "5" { LoadLocalFirmware }
            "6" { SerialMonitor }
            "7" { ResetEmbeddedPython }
            "8" { $com = SelectCOMPort; Get-ESP32SpiffsFile -Port $com -Trigger -RemotePath "/snap.jpg" }
            "9" { Show-HistoryMenu }
            "10" { return }
            default {
                Write-Color -Text "Opcion invalida" -Color Red
                Pause
            }
        }
    } while ($true)
}
function Show-HistoryMenu {
<#
    .SYNOPSIS
        Lista historiales con patron serial_{model}_{mac}_{port}_{timestamp}.txt bajo .\historial.

    .DESCRIPTION
        Pide el modelo y actualiza $script:selectedDevice. Busca en la subcarpeta "historial" de la ubicacion actual (Get-Location).
        Muestra archivos que inician con el modelo indicado. Permite ordenar por fecha (timestamp) o por nombre.
        Despues del primer listado, permite filtrar por MAC (parcial o completa).
        Guarda la ultima lista de archivos en $Global:FilteredArchivos.

    .PARAMETER (sin parametros)
        La funcion no recibe parametros; todo se solicita por consola.
        Use -Verbose para ver depuracion: rutas, conteos, coincidencias, etc.

    .EXAMPLE
        Show-HistoryMenu
        # Flujo: ingresa el modelo (ej. EB01M), elige orden F o A, visualiza lista, luego puedes filtrar por MAC.

    .EXAMPLE
        Show-HistoryMenu -Verbose
        # Muestra detalles de depuracion: ruta base, cantidad de archivos encontrados, patrones, etc.

    .NOTES
        ADVERTENCIA: la funcion asume nombres de archivo con la forma serial_{model}_{mac}_{port}_{timestamp}.txt.
        Si el timestamp tiene un formato no reconocido, se usa LastWriteTime como respaldo.
    .FECHA
        2025-10-22
#>

    [CmdletBinding(SupportsShouldProcess=$false)]
    param()

    # ejemplo de uso rapido:
    # Example: Show-HistoryMenu
    # Example: Show-HistoryMenu -Verbose

    # parser de timestamp tolerante a varios formatos comunes
    $parseTimestamp = {
        param([string]$stamp)

        # Formatos aceptados, del mas comun al menos comun
        $formats = @(
            'yyyyMMddHHmmss',     # 20251022112233
            'yyyyMMddTHHmmss',    # 20251022T112233
            'yyyy-MM-dd_HHmmss',  # 2025-10-22_112233
            'yyyyMMdd-HHmmss'     # 20251022-112233
        )

        foreach ($f in $formats) {
            try {
                return [datetime]::ParseExact($stamp, $f, [Globalization.CultureInfo]::InvariantCulture)
            } catch {
                # ignorar e intentar siguiente
            }
        }
        return $null
    }

    try {
        # mostrar donde estamos y donde buscaremos
        Set-BaseDir
        $histPath = Join-Path -Path $script:baseDir -ChildPath 'historial'
        Write-Verbose ("BasePath: {0}" -f $script:baseDir)
        Write-Verbose ("HistPath: {0}" -f $histPath)

        if (-not (Test-Path -LiteralPath $histPath)) {
            Write-Host ("No existe la carpeta: {0}" -f $histPath)
            return
        }

        # pedir modelo y actualizar $script:selectedDevice
        $model = Read-Host "Modelo (ej. EA01J, EB01M, etc.)"
        if ([string]::IsNullOrWhiteSpace($model)) {
            Write-Host "Modelo vacio. Cancelado."
            Start-Sleep -Seconds 4
            return
        }
        Start-Sleep -Seconds 2
        $script:selectedDevice = $model
        Write-Verbose ("Modelo recibido: {0}" -f $model)
        Start-Sleep -Seconds 2
        # cargar candidatos serial_*.txt
        $all = Get-ChildItem -LiteralPath $histPath -File -Filter 'serial_*.txt' -ErrorAction SilentlyContinue
        if (-not $all) {
            Write-Host ("No hay archivos serial_*.txt en {0}" -f $histPath)
            Start-Sleep -Seconds 4
            return
        }
        Write-Verbose ("Total serial_*.txt: {0}" -f $all.Count)

        # regex para serial_{model}_{mac}_{port}_{timestamp}.txt
        $rx = '^[sS]erial_(?<model>[^_]+)_(?<mac>[^_]+)_(?<port>[^_]+)_(?<ts>[^\.]+)\.txt$'
        Write-Verbose ("Regex: {0}" -f $rx)

        # filtrar por modelo
        $parsed = foreach ($f in $all) {
            if ($f.Name -match $rx) {
                $m = $Matches
                if ($m.model -ieq $model) {
                    $dt = & $parseTimestamp $m.ts
                    [pscustomobject]@{
                        File       = $f
                        Name       = $f.Name
                        Model      = $m.model
                        MAC        = $m.mac
                        Port       = $m.port
                        TSRaw      = $m.ts
                        TS         = $dt
                        FallbackTS = $f.LastWriteTime
                    }
                }
            } else {
                Write-Verbose ("No coincide regex: {0}" -f $f.Name)
            }
        }

        if (-not $parsed) {
            Write-Host ("No se encontraron archivos del modelo '{0}' en {1}" -f $model, $histPath)
            Start-Sleep -Seconds 4
            return
        }

        Write-Verbose ("Coincidencias iniciales (modelo): {0}" -f $parsed.Count)

        # elegir orden
        $orderChoice = Read-Host "Ordenar por Fecha (F) o Alfabetico (A)? [F/A]"
        if ([string]::IsNullOrWhiteSpace($orderChoice)) { $orderChoice = 'F' }
        $orderChoice = $orderChoice.Trim().ToUpperInvariant()
        Write-Verbose ("Orden elegido: {0}" -f $orderChoice)

        switch ($orderChoice) {
            'A' {
                $list = $parsed | Sort-Object -Property Name
            }
            default {
                # ordenar por TS si existe, si no por LastWriteTime
                $list = $parsed | Sort-Object -Property @{
                    Expression = { if ($_.TS) { $_.TS } else { $_.FallbackTS } }
                    Ascending  = $false
                }
            }
        }

        # guardar lista en variable global para pasos posteriores
        $Global:FilteredArchivos = $list.File

        # mostrar listado inicial
        Write-Host ("`nResultados para modelo '{0}' en {1}:`n" -f $model, $histPath)
        $i = 1
        foreach ($it in $list) {
            $when = if ($it.TS) { $it.TS.ToString('yyyy-MM-dd HH:mm:ss') } else { ($it.FallbackTS.ToString('yyyy-MM-dd HH:mm:ss') + ' *') }
            "{0,3}. {1,-22}  MAC={2,-14}  Port={3,-8}  Fecha={4}" -f $i, $it.Model, $it.MAC, $it.Port, $when
            "     {0}" -f $it.Name
            $i++
        }

        # preguntar por filtro de MAC despues del primer listado
        $wantMac = Read-Host "`nDeseas filtrar por MAC? (s/n)"
        if ($wantMac -match '^(s|si)$') {
            $macFilter = Read-Host "Ingresa MAC (parcial o completa, sin espacios)"
            if (-not [string]::IsNullOrWhiteSpace($macFilter)) {
                $preCount = ($list | Measure-Object).Count
                $list = $list | Where-Object { $_.MAC -like ("*{0}*" -f $macFilter) }
                $postCount = ($list | Measure-Object).Count
                Write-Verbose ("Filtrado MAC '{0}': {1} -> {2}" -f $macFilter, $preCount, $postCount)

                if (-not $list) {
                    Write-Host ("No hay resultados con MAC que contenga '{0}'." -f $macFilter)
                    Start-Sleep -Seconds 4
                    return
                }

                # reordenar respetando preferencia
                switch ($orderChoice) {
                    'A' { $list = $list | Sort-Object -Property Name }
                    default {
                        $list = $list | Sort-Object -Property @{
                            Expression = { if ($_.TS) { $_.TS } else { $_.FallbackTS } }
                            Ascending  = $false
                        }
                    }
                }

                $Global:FilteredArchivos = $list.File

                Write-Host ("`nResultados filtrados por MAC (~'{0}'):`n" -f $macFilter)
                $i = 1
                foreach ($it in $list) {
                    $when = if ($it.TS) { $it.TS.ToString('yyyy-MM-dd HH:mm:ss') } else { ($it.FallbackTS.ToString('yyyy-MM-dd HH:mm:ss') + ' *') }
                    "{0,3}. {1,-22}  MAC={2,-14}  Port={3,-8}  Fecha={4}" -f $i, $it.Model, $it.MAC, $it.Port, $when
                    "     {0}" -f $it.Name
                    $i++
                }
            }
        }

        Write-Host "`nListo. Puedes usar `$Global:FilteredArchivos para acciones posteriores."
        Write-Verbose "Fin normal"
    }
    catch {
        Write-Host ("Error: {0}" -f $_.Exception.Message)
        Write-Verbose ("Stack: {0}" -f $_.Exception.ToString())
    }
} # fin de la funcion Show-HistoryMenu


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
            Start-Sleep -Seconds 4
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
    param ( 
        [string]$port,
        [string] $mac )

    $macPattern = '^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$'

    SelectDeviceModel

    Write-Host "Seleccione una opcion:"
    Write-Host "1. Desconectar dispositivo manualmente e iniciar monitoreo serial"
    Write-Host "2. Iniciar monitoreo serial directamente (usualmente no permitido)"
    Write-Host "3. Reiniciar dispositivo (sin desconectarlo) e iniciar monitoreo serial"
    Write-Host "4. Salir"
    $choice = Read-Host "Ingrese 1,2 ,3 o 4"

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
    } elseif ($choice -eq '4') {
        Write-Host "Saliendo..."
        return
    }elseif ($choice -ne '2') {
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
        Set-BaseDir

        Write-Host "BaseDir: $script:baseDir"

        $historyDir = Join-Path $baseDir "historial"
        if (-not (Test-Path -LiteralPath $historyDir)) {
            New-Item -ItemType Directory -Path $historyDir -Force | Out-Null
        }

        $fileSafePort = ($port -replace '[\\/:*?"<>|]', '_')
        $timestamp = Get-Date -Format "dd-MM-yy_HH-mm-ss"
        $macClean = if ([string]::IsNullOrWhiteSpace($mac)) { "Unknown" } else { ($mac -replace ':', '') }

        $logPath = Join-Path $historyDir ("serial_{0}_{1}_{2}_{3}.txt" -f $script:selectedDevice, $macClean, $fileSafePort, $timestamp)
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

# Recibe el puerto elegido por parte del usuario e inicia la comunicacion serial inmediatamente despues
function SerialMonitor {
	
	param(
        [string]$port
    )
	
    $porAndMac = SelectCOMPort
    if (-not $porAndMac) { return }

    Write-Host "\n▶️  Iniciando monitor serial en ${$porAndMac.Port}...\n"
    # Write-Output $porAndMac.Mac
	Monitor-Serial $porAndMac.Port $porAndMac.Mac
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

<#
    .SYNOPSIS
        Selecciona un puerto COM y retorna tambien la MAC si se obtuvo durante el probing.
    .DESCRIPTION
        Agrega retorno como objeto con propiedades Port y Mac.
        En modo 1 se listan las MACs detectadas por ProbarCOMsRapido antes de elegir.
        En modo 2 (manual) se intenta un probing rapido del puerto ingresado para obtener la MAC.
        En modo 3 ahora tambien se intenta obtener la MAC, pero solo del puerto elegido tras seleccionar el indice.
    .PARAMETER Verbose
        Muestra salida detallada del probing de MACs.
    .OUTPUTS
        Retorna un [PSCustomObject] con:
            - Port: cadena con el puerto COM elegido (ej: "COM4")
            - Mac: cadena con la MAC detectada (ej: "AA:BB:CC:DD:EE:FF") o $null si no se obtuvo
    .EXAMPLE
        $sel = SelectCOMPort -Verbose
        "Puerto: {0}  MAC: {1}" -f $sel.Port, $sel.Mac
    .EXAMPLE
        $s = SelectCOMPort
        $s.Port
        $s.Mac
    .NOTES
        ADVERTENCIA: cambiar el tipo de retorno a objeto puede afectar codigo que esperaba solo una cadena.
    .FECHA
        2025-10-13
#>
function SelectCOMPort {

    # Fecha: 2025-09-29
    # Nuevo: se agrega opcion 3 para usar listado existente (WMI/Device Manager) sin probar MACs previas
    # Ajuste: en opcion 3 ahora se intenta leer la MAC del puerto seleccionado (probing puntual)

    param(
        [switch]$Verbose
    )

    function ProbarCOMsRapido {
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

                # TIMEOUT DE 1 SEGUNDO
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

    # cargar listado de puertos desde WMI / sistema
    try {
        $ports = Get-WmiObject Win32_PnPEntity -Filter "Caption like '%(COM%'" |
                 Sort-Object Caption
    } catch { $ports = @() }

    if (-not $ports) {
        $ports = [System.IO.Ports.SerialPort]::GetPortNames() |
                 ForEach-Object { @{ DeviceID = $_ ; Caption = $_ } }
    }
    if (-not $ports) { Write-Host "No se encontraron puertos COM."; Pause; return $null }

    # menu de modos (ahora con opcion 3)
    Write-Host "`nSeleccione modo para elegir puerto COM:"
    Write-Host "1. Elegir por indice (con probing rapido de MAC)"
    Write-Host "2. Ingresar COM manualmente (ej: COM4)"
    Write-Host "3. Usar listado existente (WMI/Device Manager) e intentar MAC solo del elegido"
    Write-Host "4. Salir"
    $modo = Read-Host "Opcion"

    if( $modo -eq "4" ) {
    Write-Host "Saliendo..."
    return $null
    }


    # regex y extraccion de COMN
    $comRegex        = '\(COM\d+\)'
    $comPortsToCheck = @()
    foreach ($p in $ports) {
        if ($p.Caption -match 'Bluetooth') { continue }
        $m = [regex]::Match($p.Caption, $comRegex)
        if ($m.Success) { $comPortsToCheck += $m.Value.Trim('()') }
    }

    # si elige 1, ejecutar probing previo sobre todos; en 3 se hara mas adelante, solo del elegido
    $macs  = @{}
    $fails = @{}

    if ($modo -eq "1") {
        $resultado = ProbarCOMsRapido -lista $comPortsToCheck
        $macs  = $resultado.macs
        $fails = $resultado.fails
    }

    # mostrar lista disponible
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

    # solo mostrar MACs/errores si hubo probing previo (modo 1)
    if ($modo -eq "1") {
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
    }

    # manejo de opcion 2: manual
    if ($modo -eq "2") {
        $manual = Read-Host "Ingrese el nombre del puerto COM (ej: COM4 o com14) (minusculas permitidas)"
        if ($null -ne $manual) { $manual = $manual.ToUpper() }
        if ($manual -match '^COM\d+$') {
            # intento de probing rapido del puerto manual para obtener MAC
            $macManual = $null
            $r = ProbarCOMsRapido -lista @($manual)
            if ($r.macs.ContainsKey($manual)) { $macManual = $r.macs[$manual] }

            return [pscustomobject]@{
                Port = $manual
                Mac  = $macManual
            }
        } else {
            Write-Host "Puerto COM invalido."; Pause; return $null
        }
    }

    # manejo de opcion 1 y 3: seleccionar por indice
    $sel = Read-Host "`nSeleccione un puerto por indice"
    if ([string]::IsNullOrWhiteSpace($sel)) {
    return
    }

    $idx = 0
    if (-not [int]::TryParse($sel, [ref]$idx) -or $idx -lt 1 -or $idx -gt $ports.Count) {
        Write-Host "Indice invalido."; Pause; return $null
    }

    # obtener COM elegido
    $puertoElegido = $ports[$idx-1].ComPort

    # MAC a devolver
    $macElegida = $null

    # si hubo probing previo (modo 1), usarlo
    if ($modo -eq "1" -and $macs.ContainsKey($puertoElegido)) {
        $macElegida = $macs[$puertoElegido]
    }

    # NUEVO: si es modo 3, intentar probing puntual del puerto elegido para obtener MAC
    if ($modo -eq "3") {
        $r3 = ProbarCOMsRapido -lista @($puertoElegido)
        if ($r3.macs.ContainsKey($puertoElegido)) {
            $macElegida = $r3.macs[$puertoElegido]
        }
    }


    # retornar objeto con puerto y mac
    return [pscustomobject]@{
        Port = $puertoElegido
        Mac  = $macElegida
    }
} # fin de la funcion SelectCOMPort con parametros Verbose y retorno Port/Mac



<#
    .SYNOPSIS
        Flashea ESP32S3 con 3 binarios locales o por URL, corrigiendo quoting y usando sintaxis nueva de esptool.
    .DESCRIPTION
        Evita el error Invalid argument removiendo comillas incrustadas y pasando argumentos como arreglo.
        Actualiza comandos/flags deprecados: erase-region, write-flash, --flash-mode, --flash-freq, --flash-size, default-reset, hard-reset.
    .PARAMETER (interactivo)
        No recibe parametros. Pide seleccionar los .bin y el puerto.
    .EXAMPLE
        LoadLocalFirmware
        Ejecuta el asistente, selecciona 3 .bin y flashea al puerto elegido.
    .NOTES
        ADVERTENCIA: erase-region 0xE000 0x2000 solo limpia otadata; no borra particiones. Use con criterio.
    .FECHA
        2025-10-13
#>
function LoadLocalFirmware {

    # UI para seleccionar archivos o ruta base
    Add-Type -AssemblyName System.Windows.Forms

    Write-Host ""
    Write-Host "Seleccione el M00 usado en esta version de proyecto:"
    # importante no revelar informacion de mcu a cliente
    Write-Host " 1) M00A2" #eps32s3
    Write-Host " 2) M00A1" #esp32c3
    Write-Host " 3) Salir"
    $global:mcu = Read-Host "Ingrese 1 o 2"
    if($global:mcu -eq "1") {
    $global:mcu = "esp32s3"
    } elseif($global:mcu -eq "2") {
    $global:mcu = "esp32c3"
    } elseif($global:mcu -eq "3") {
    return
    } else {
    Write-Host "Opcion invalida"; Pause; return
    }


    Write-Host ""
    Write-Host "Seleccione el metodo de carga:"
    Write-Host "  1) Selector de archivos (OpenFileDialog)"
    Write-Host "  2) Ruta base (local o URL) que contenga bootloader.bin, partitions.bin y firmware.bin"
    Write-Host "  3) Salir"

    $mode = Read-Host "Ingrese 1, 2 o 3"

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

        # Detectar cada archivo por nombre ignorando mayusculas
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
                    # Descarga cada binario sin comillas extra
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
        if( $mode -eq "3") {
        Write-Host "Saliendo..."
        return
        }else{
        Write-Host "Opcion invalida."; Pause; return
        }
    }

    # Seleccion de puerto (puede devolver string o un objeto con .Port y .Mac)
    $port = SelectCOMPort

    # CRUCIAL: normalizar a string simple para esptool
    if ($null -eq $port) { Write-Host "No se selecciono puerto."; Pause; return }
    if ($port -is [string]) {
        $portString = $port
        $macString  = $null
    } else {
        $portString = $port.Port
        $macString  = $port.Mac
    }
    if ([string]::IsNullOrWhiteSpace($portString)) { Write-Host "Puerto invalido."; Pause; return }

    # CRUCIAL: validar que los .bin existan y expandir a rutas completas
    foreach ($p in @('boot','part','firm')) {
        $val = Get-Variable -Name $p -ValueOnly
        if (-not (Test-Path -LiteralPath $val)) {
            Write-Host "Archivo no encontrado: $val"; Pause; return
        }
        Set-Variable -Name $p -Value (Resolve-Path -LiteralPath $val).Path
    }

    # CRUCIAL: preparar argumentos como array para evitar comillas incrustadas
    $eraseArgs = @(
        '-m','esptool',
        '--chip', $global:mcu,
        '--port', $portString,
        'erase-region','0xE000','0x2000'
    )

    # Ejecutar erase-region sin comillas extra
    & $venvPython @eraseArgs
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✅ otadata borrado correctamente"
    } else {
        Write-Host "❌ Error al borrar otadata"
    }

    # CRUCIAL: write-flash con flags nuevos y sin comillas en rutas
    $flashArgs = @(
        '-m','esptool',
        '--chip',$global:mcu,
        '--port', $portString,
        '--baud','115200',
        '--before','default-reset',
        '--after','hard-reset',
        'write-flash','-z',
        '--flash-mode','dio',
        '--flash-freq','40m',
        '--flash-size','detect',
        '0x0',     $boot,
        '0x8000',  $part,
        '0x10000', $firm
    )

    & $venvPython @flashArgs

    if ($LASTEXITCODE -eq 0) {
        Write-Host "Firmware local cargado correctamente."
    } else {
        Write-Host "Error al cargar firmware."
    }

    Pause

    if ($macString) {
        Monitor-Serial $portString $macString
    } else {
        Monitor-Serial $portString
    }
} # fin de la funcion LoadLocalFirmware


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
	
    # derivar carpeta base del python embebido y su Scripts
    $pyDir      = Split-Path -Parent $script:venvPython
    $pyScripts  = Join-Path $pyDir 'Scripts'
    if (-not (Test-Path $pyScripts)) { New-Item -ItemType Directory -Force -Path $pyScripts | Out-Null }
    Add-ToPath $pyScripts   # usa tu funcion Add-ToPath

    #$script:venvPython = $venvPython   # ← resto del script lo usará

    #& $venvPython -m pip install --upgrade pip
    #& $venvPip install "esptool" "pyserial" "qrcode[pil]" "Pillow" "pywin32"
	
	# 2) actualizar pip y paquetes reduciendo ruido y quitando el warning de PATH
    #    --no-warn-script-location evita justamente esos avisos
    #    -q baja el nivel de salida
    & $script:venvPython -m pip install --upgrade pip --no-warn-script-location -q
    & $script:venvPython -m pip install --no-warn-script-location -q esptool pyserial "qrcode[pil]" Pillow pywin32


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
            "1" { $script:SelectedDevice = "EA01J"; return }
			"2" { $script:SelectedDevice = "CA01N"; return }
			"3" { $script:SelectedDevice = "EB01M"; return }
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
    Write-Host "Seleccione el M00 usado en esta version de proyecto:"
    # importante no revelar informacion de mcu a cliente
    Write-Host " 1) M00A2" #eps32s3
    Write-Host " 2) M00A1" #esp32c3
    Write-Host " 3) Salir"
    $global:mcu = Read-Host "Ingrese 1 o 2"
    if($global:mcu -eq "1") {
        $global:mcu = "esp32s3"
    } elseif($global:mcu -eq "2") {
        $global:mcu = "esp32c3"
    } elseif($global:mcu -eq "3") {
        Write-Host "Salir"
        return
    }

    $port = SelectCOMPort
    & "$venvPython" -m esptool --chip $global:mcu --port $port.Port erase_flash
    Pause
}

function UpdateFromAioServer 
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
	
	& "$venvPython" -m esptool --chip esp32s3 --port $port.Port --baud 115200 `
	--before default_reset --after hard_reset write_flash -z `
	--flash_mode dio --flash_freq 40m --flash_size detect `
	0x0      $boot `
	0x8000   $part `
	0x10000  $firm


    if ($LASTEXITCODE -eq 0) {
        Write-Host "Firmware actualizado exitosamente. Esperando conexion y MAC..."
        #& "$venvPython" monitor_serial.py $port
		Monitor-Serial $port.Port $port.Mac
    } else {
        Write-Host "Error actualizando firmware."
    }
    Pause
	SerialMonitor($port)
} # end of UpdateFromAioServer()

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
