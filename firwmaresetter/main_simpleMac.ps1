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
function Invoke-PythonCleanProgress {
    param(
        [Parameter(Mandatory = $true)][string]$PythonExe,
        [Parameter(Mandatory = $true)][string[]]$Args,
        [string]$Title = "Procesando"
    )

    $tempOut = Join-Path $env:TEMP ("py_out_{0}.log" -f ([guid]::NewGuid().ToString("N")))
    $tempErr = Join-Path $env:TEMP ("py_err_{0}.log" -f ([guid]::NewGuid().ToString("N")))

    try {
        Write-Host $Title -ForegroundColor Yellow

        $proc = Start-Process `
            -FilePath $PythonExe `
            -ArgumentList $Args `
            -RedirectStandardOutput $tempOut `
            -RedirectStandardError $tempErr `
            -PassThru `
            -WindowStyle Hidden

        $lastShown = $null
        $printedAnything = $false

        while (-not $proc.HasExited) {
            $merged = @()
            if (Test-Path $tempOut) { $merged += Get-Content $tempOut -ErrorAction SilentlyContinue }
            if (Test-Path $tempErr) { $merged += Get-Content $tempErr -ErrorAction SilentlyContinue }

            $filtered = $merged | Where-Object {
                $_ -match '\b\d+%' -or
                $_ -match 'Downloading' -or
                $_ -match 'Installing collected packages' -or
                $_ -match 'Collecting' -or
                $_ -match 'Using cached'
            } | Select-Object -Last 1

            if ($filtered) {
                $current = $filtered.Trim()
                if ($current -ne $lastShown) {
                    Write-Host $current
                    $lastShown = $current
                    $printedAnything = $true
                }
            }
            elseif (-not $printedAnything) {
                Write-Host "Procesando..."
                $printedAnything = $true
                $lastShown = "Procesando..."
            }

            Start-Sleep -Milliseconds 300
        }

        $allLines = @()
        if (Test-Path $tempOut) { $allLines += Get-Content $tempOut -ErrorAction SilentlyContinue }
        if (Test-Path $tempErr) { $allLines += Get-Content $tempErr -ErrorAction SilentlyContinue }

        $cleanLines = $allLines | Where-Object {
            $_.Trim() -and
            $_ -notmatch 'WARNING: The scripts' -and
            $_ -notmatch 'Consider adding this directory to PATH' -and
            $_ -notmatch 'not on PATH'
        }

        $fullText = ($cleanLines -join "`n")

        if (
            $proc.ExitCode -eq 0 -or
            $fullText -match 'Successfully installed' -or
            $fullText -match 'Requirement already satisfied'
        ) {
            Write-Host "Completado correctamente." -ForegroundColor Green
            return
        }

        $realError = $cleanLines | Where-Object {
            $_ -notmatch '^Collecting ' -and
            $_ -notmatch '^Using cached ' -and
            $_ -notmatch '^Installing collected packages:' -and
            $_ -notmatch '^Successfully installed ' -and
            $_ -notmatch '^Requirement already satisfied:'
        } | Select-Object -Last 10

        if ($realError) {
            throw ($realError -join "`n")
        } else {
            throw "El comando fallo sin detalle visible."
        }
    }
    finally {
        Remove-Item $tempOut -Force -ErrorAction SilentlyContinue
        Remove-Item $tempErr -Force -ErrorAction SilentlyContinue
    }
}
function Download-FileWithProgress {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [string]$Activity = "Descargando archivo"
    )

    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Method = "GET"
    $request.Timeout = 15000
    $request.ReadWriteTimeout = 15000
    $request.UserAgent = "Mozilla/5.0"

    Write-Host "$Activity"
    Write-Host "Conectando al servidor..." -ForegroundColor Yellow

    $response = $null
    $inStream = $null
    $outStream = $null

    try {
        $response   = $request.GetResponse()
        $totalBytes = $response.ContentLength
        $inStream   = $response.GetResponseStream()
        $outStream  = [System.IO.File]::Create($OutFile)

        $buffer = New-Object byte[] 65536
        $read = 0
        $totalRead = 0
        $lastPercent = -1
        $lastUpdate = Get-Date

        while (($read = $inStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $outStream.Write($buffer, 0, $read)
            $totalRead += $read

            if ($totalBytes -gt 0) {
                $percent = [int](($totalRead * 100) / $totalBytes)

                if ($percent -ne $lastPercent -or ((Get-Date) - $lastUpdate).TotalMilliseconds -gt 400) {
                    $mbRead  = [math]::Round($totalRead / 1MB, 2)
                    $mbTotal = [math]::Round($totalBytes / 1MB, 2)

                    $bars = [int]($percent / 5)
                    $bar  = ("#" * $bars).PadRight(20, ".")

                    Write-Host ("`r[{0}] {1,3}%  {2} MB / {3} MB" -f $bar, $percent, $mbRead, $mbTotal) -NoNewline

                    $lastPercent = $percent
                    $lastUpdate = Get-Date
                }
            }
            else {
                $mbRead = [math]::Round($totalRead / 1MB, 2)
                Write-Host ("`rDescargado: {0} MB" -f $mbRead) -NoNewline
            }
        }

        Write-Host ""
        Write-Host "Descarga completada." -ForegroundColor Green
    }
    finally {
        if ($outStream) { $outStream.Dispose() }
        if ($inStream)  { $inStream.Dispose() }
        if ($response)  { $response.Dispose() }
    }
}

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

        Write-Color -Text "  [1] ", "Ver-Mac" -Color Cyan, Green
        Write-Color -Text "  [2] ", "Salir" -Color Cyan, Green

        Write-Color ""
        Write-Color -Text "==========================================" -Color Cyan
        Write-Color ""

        $choice = Read-Host "Seleccione una opcion"

        switch ($choice) {
            "1" { VerMac}
            "2" { return }
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

    $zipFileName = "python-$Version-embed-amd64.zip"
    $zipName     = Join-Path $BaseDir $zipFileName
    $zipUrl      = "https://www.python.org/ftp/python/$Version/$zipFileName"
    $pythonDir   = Join-Path $BaseDir "py$Version"
    $pythonExe   = Join-Path $pythonDir "python.exe"

    if (-not (Test-Path $pythonExe)) {
        Write-Host "Descargando Python $Version (embeddable)..."
        New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null
        (Get-Item $BaseDir).Attributes += 'Hidden'

        try {
            Download-FileWithProgress `
                -Url $zipUrl `
                -OutFile $zipName `
                -Activity "Descargando Python $Version (embeddable)"
        }
        catch {
            Write-Error "Embedded py no pudo ser instalado por falta de conexion a internet o timeout."
            return $null
        }

        Write-Host "Extrayendo Python..." -ForegroundColor Yellow
        Expand-Archive $zipName -DestinationPath $pythonDir -Force
        Remove-Item $zipName -Force -ErrorAction SilentlyContinue

        Write-Host "Configurando python311._pth..." -ForegroundColor Yellow
        (Get-Content "$pythonDir\python311._pth") |
            ForEach-Object { $_ -replace '^#\s*import\s+site', 'import site' } |
            Set-Content "$pythonDir\python311._pth"

        $pyScripts = Join-Path $pythonDir 'Scripts'
        if (-not (Test-Path $pyScripts)) {
            New-Item -ItemType Directory -Force -Path $pyScripts | Out-Null
        }
        Add-ToPath $pyScripts

        $gp = Join-Path $pythonDir 'get-pip.py'
        Download-FileWithProgress `
            -Url 'https://bootstrap.pypa.io/get-pip.py' `
            -OutFile $gp `
            -Activity "Descargando instalador de pip"

        Invoke-PythonCleanProgress `
            -PythonExe $pythonExe `
            -Args @($gp, "--no-warn-script-location", "--disable-pip-version-check") `
            -Title "Instalando pip..."

        Remove-Item $gp -Force -ErrorAction SilentlyContinue
    }

    return $pythonExe
}

function VerMac {
    param(
        [string]$Port
    )

    function _PickPortAuto {
        $coms = @()

        try {
            $ports = @(Get-CimInstance Win32_SerialPort -ErrorAction Stop)

            $preferred = @(
                $ports | Where-Object {
                    $_.DeviceID -match '^COM\d+$' -and
                    $_.DeviceID -notin @('COM1','COM2') -and (
                        $_.PNPDeviceID -match '^USB' -or
                        $_.Name -match 'CP210|CH340|CH910|USB Serial|USB-Serial|CDC|Espressif|JTAG|ESP32'
                    )
                } | ForEach-Object {
                    $_.DeviceID.ToString().Trim().ToUpper()
                }
            )

            if ($preferred.Count -ge 1) {
                return $preferred[0]
            }

            $fallback = @(
                $ports | Where-Object {
                    $_.DeviceID -match '^COM\d+$' -and
                    $_.DeviceID -notin @('COM1','COM2')
                } | ForEach-Object {
                    $_.DeviceID.ToString().Trim().ToUpper()
                }
            )

            if ($fallback.Count -ge 1) {
                return $fallback[0]
            }
        }
        catch {}

        try {
            $serials = @([System.IO.Ports.SerialPort]::GetPortNames() | ForEach-Object {
                $_.ToString().Trim().ToUpper()
            } | Where-Object {
                $_ -match '^COM\d+$' -and $_ -notin @('COM1','COM2')
            })

            if ($serials.Count -ge 1) {
                return $serials[0]
            }
        }
        catch {}

        return $null
    }

    function _ParseMac([string]$text) {
        foreach($line in ($text -split "`r?`n")) {
            if($line -match 'MAC:\s*([0-9A-Fa-f:]{17})') {
                return $Matches[1].ToLower()
            }
        }
        return $null
    }

    try {
        if ([string]::IsNullOrWhiteSpace($Port)) {
            $Port = _PickPortAuto

            if (-not $Port) {
                Write-Host "No pude autodetectar el puerto COM." -ForegroundColor Red
                Read-Host "Presiona ENTER para volver al menu"
                return
            }
        } else {
            $Port = ([string]$Port).Trim().ToUpper()
        }

        if ($Port -match '(COM\d+)') {
            $Port = $Matches[1].ToUpper()
        }

        if ($Port -notmatch '^COM\d+$') {
            Write-Host "Puerto invalido detectado: '$Port'" -ForegroundColor Red
            Read-Host "Presiona ENTER para volver al menu"
            return
        }

        Write-Host "Usando puerto: $Port"

        $pythonExe = $script:venvPython

        if ([string]::IsNullOrWhiteSpace($pythonExe) -or -not (Test-Path $pythonExe)) {
            Write-Host "Python embebido no inicializado correctamente." -ForegroundColor Red
            Read-Host "Presiona ENTER para volver al menu"
            return
        }

        $checkEsptool = & $pythonExe -m esptool version 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-Host "No se pudo ejecutar esptool con el Python embebido." -ForegroundColor Red
            Write-Host $checkEsptool
            Read-Host "Presiona ENTER para volver al menu"
            return
        }

        $args = @("-m", "esptool", "--chip", "esp32s3", "--port", $Port, "read-mac")
        $macOut = & $pythonExe @args 2>&1 | Out-String
        $mac = _ParseMac $macOut

        if ($mac) {
            Write-Host "MAC: $mac" -ForegroundColor Green
        } else {
            Write-Host "No se pudo leer la MAC. Verifica que el puerto sea correcto y que el ESP32-S3 responda." -ForegroundColor Red
            Write-Host $macOut
        }

        Read-Host "Presiona ENTER para volver al menu"
        return
    }
    catch {
        Write-Host "Error en VerMac: $($_.Exception.Message)" -ForegroundColor Red
        Read-Host "Presiona ENTER para volver al menu"
        return
    }
}

function Start-ESP32Tool {
    $script:venvPython = Install-EmbeddedPython "3.11.4"

    if ([string]::IsNullOrWhiteSpace($script:venvPython) -or -not (Test-Path $script:venvPython)) {
        throw "No se pudo inicializar Python embebido."
    }

    $pyDir     = Split-Path -Parent $script:venvPython
    $pyScripts = Join-Path $pyDir 'Scripts'
    if (-not (Test-Path $pyScripts)) {
        New-Item -ItemType Directory -Force -Path $pyScripts | Out-Null
    }
    Add-ToPath $pyScripts

    # Opcional: puedes comentar este bloque si no quieres actualizar pip cada vez
    Invoke-PythonCleanProgress `
        -PythonExe $script:venvPython `
        -Args @("-m","pip","install","--upgrade","pip","--no-warn-script-location","--disable-pip-version-check") `
        -Title "Actualizando pip..."

    Invoke-PythonCleanProgress `
        -PythonExe $script:venvPython `
        -Args @("-m","pip","install","--no-warn-script-location","--disable-pip-version-check","esptool","pyserial","qrcode[pil]","Pillow","pywin32") `
        -Title "Instalando dependencias..."

    ShowMainMenu
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
    #Esto siempre se ejecuta despues de elegir aLGUNA OPCION
    # al terminar esa funcionalidad elegida ( cuidado , no es solo cuando le pones "Salir")
    Write-LogHard "== FINALLY: pausing =="
    Write-Host "`nLog: $global:LogPath"
    # exit
    Write-Host "Presiona ENTER para salir..."
    # try { [void][System.Console]::ReadLine() } catch { Read-Host | Out-Null }
}
# ========================================================================

