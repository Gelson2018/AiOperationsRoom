<#
.SYNOPSIS
    Instala, atualiza ou remove o AI Operations Room neste computador.

.DESCRIPTION
    Executar de novo atualiza a instalação existente. Passos:
      1. Instala Git e Python 3.12+ com winget, se faltarem.
      2. Clona o repositório (ou atualiza o clone existente).
      3. Cria o ambiente .venv e instala as dependências do pyproject.toml.
      4. Faz backup de ~/.claude/settings.json e registra os hooks do Claude Code.
      5. Cria o atalho na pasta Inicializar do Windows (opcional).
      6. Inicia o servidor e abre a sala no navegador.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Port 8898 -NoStartup

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall -RemoveFiles
#>
[CmdletBinding()]
param(
    # Pasta do checkout. Os hooks apontam para ela; não a mova depois de instalar.
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'AiOperationsRoom'),
    [string]$RepoUrl = 'https://github.com/Gelson2018/AiOperationsRoom.git',
    [string]$Branch = 'master',
    [ValidateRange(1, 65535)]
    [int]$Port = 8765,
    # Arquivo de configurações do Claude Code que recebe os hooks.
    [string]$ClaudeSettings = (Join-Path $env:USERPROFILE '.claude\settings.json'),
    # Não cria o atalho que abre a sala ao entrar no Windows.
    [switch]$NoStartup,
    # O atalho de login inicia o servidor sem abrir o navegador.
    [switch]$NoBrowserAtLogin,
    # Não inicia o servidor ao final da instalação.
    [switch]$NoStart,
    # Não abre o navegador ao final da instalação.
    [switch]$NoBrowser,
    # Remove hooks e atalho e para o servidor.
    [switch]$Uninstall,
    # Com -Uninstall: apaga também a pasta da instalação.
    [switch]$RemoveFiles,
    # Com -Uninstall: apaga também o histórico local (~/.ai-operations-room).
    [switch]$RemoveData
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ShortcutName = 'AI Operations Room.lnk'
$MinPython = [version]'3.12'

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Note([string]$Message) { Write-Host "    $Message" }
function Write-Warn([string]$Message) { Write-Host "AVISO: $Message" -ForegroundColor Yellow }

# Native commands do not raise on failure in Windows PowerShell 5.1.
function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments)
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Falhou ($LASTEXITCODE): $Exe $($Arguments -join ' ')"
    }
}

function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

function Install-WithWinget([string]$Id, [string]$Label, [string[]]$Extra = @()) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "$Label não encontrado e o winget não está disponível. Instale $Label manualmente e execute o script de novo."
    }
    Write-Step "Instalando $Label com winget"
    $arguments = @('install', '--id', $Id, '-e', '--silent',
                   '--accept-source-agreements', '--accept-package-agreements') + $Extra
    & winget @arguments
    # winget returns non-zero when the package is already present; verify by lookup instead.
    Update-SessionPath
}

function Test-PythonCandidate([string]$Exe, [string[]]$Prefix) {
    try {
        $output = & $Exe @($Prefix + @('-c', "import sys; print('%d.%d' % sys.version_info[:2])")) 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $output) { return $false }
        return ([version]("$output".Trim()) -ge $MinPython)
    } catch {
        return $false
    }
}

function Find-Python {
    $candidates = New-Object System.Collections.ArrayList
    if (Get-Command py -ErrorAction SilentlyContinue) { [void]$candidates.Add(@('py', '-3')) }
    foreach ($name in 'python', 'python3') {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        # Skip the Microsoft Store alias, which opens the Store instead of running.
        if ($cmd -and $cmd.Source -notlike '*\WindowsApps\*') { [void]$candidates.Add(@($cmd.Source)) }
    }
    $roots = @("$env:LOCALAPPDATA\Programs\Python", $env:ProgramFiles)
    foreach ($root in $roots) {
        if (Test-Path -LiteralPath $root) {
            Get-ChildItem -LiteralPath $root -Directory -Filter 'Python3*' -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending |
                ForEach-Object { $exe = Join-Path $_.FullName 'python.exe'; if (Test-Path $exe) { [void]$candidates.Add(@($exe)) } }
        }
    }
    foreach ($candidate in $candidates) {
        $exe = $candidate[0]
        $prefix = @($candidate | Select-Object -Skip 1)
        if (Test-PythonCandidate $exe $prefix) { return , $candidate }
    }
    return $null
}

function Get-Python {
    $python = Find-Python
    if (-not $python) {
        Install-WithWinget 'Python.Python.3.13' 'Python 3.13' @('--scope', 'user')
        $python = Find-Python
    }
    if (-not $python) {
        throw "Python $MinPython ou superior não encontrado. Instale em https://www.python.org/downloads/ e execute o script de novo."
    }
    return , $python
}

function Get-Git {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Install-WithWinget 'Git.Git' 'Git'
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
            $default = Join-Path $env:ProgramFiles 'Git\cmd'
            if (Test-Path (Join-Path $default 'git.exe')) { $env:Path = "$default;$env:Path" }
        }
    }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'Git não encontrado. Instale em https://git-scm.com/download/win e execute o script de novo.'
    }
}

function Stop-RoomServer {
    $venv = (Join-Path $InstallDir '.venv') + '\'
    $all = @(Get-CimInstance Win32_Process)
    $ids = @($all | Where-Object {
        $_.ExecutablePath -and $_.ExecutablePath.StartsWith($venv, [StringComparison]::OrdinalIgnoreCase)
    } | ForEach-Object { $_.ProcessId })
    if (-not $ids) { return }
    # The venv launcher runs the real interpreter as a child process.
    $children = @($all | Where-Object { $ids -contains $_.ParentProcessId } | ForEach-Object { $_.ProcessId })
    foreach ($id in ($ids + $children)) {
        Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
    }
    Write-Note "Servidor anterior encerrado (PID $($ids -join ', '))."
    Start-Sleep -Milliseconds 500
}

function Test-Health {
    try {
        $response = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/api/health" -UseBasicParsing -TimeoutSec 2
        return ($response.StatusCode -eq 200)
    } catch {
        return $false
    }
}

function Get-DataDir {
    if ($env:AI_OPERATIONS_ROOM_DATA_DIR) { return $env:AI_OPERATIONS_ROOM_DATA_DIR }
    return Join-Path $env:USERPROFILE '.ai-operations-room'
}

function Get-ShortcutPath {
    return Join-Path ([Environment]::GetFolderPath('Startup')) $ShortcutName
}

function Backup-Settings {
    if (Test-Path -LiteralPath $ClaudeSettings) {
        $backup = "$ClaudeSettings.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item -LiteralPath $ClaudeSettings -Destination $backup
        Write-Note "Backup das configurações: $backup"
    }
}

function Find-ForeignHooks {
    if (-not (Test-Path -LiteralPath $ClaudeSettings)) { return @() }
    $mine = Join-Path $InstallDir 'hooks\capture.py'
    $settings = [IO.File]::ReadAllText($ClaudeSettings) | ConvertFrom-Json
    if (-not ($settings.PSObject.Properties.Name -contains 'hooks')) { return @() }
    $found = foreach ($event in $settings.hooks.PSObject.Properties) {
        foreach ($group in @($event.Value)) {
            if (-not ($group.PSObject.Properties.Name -contains 'hooks')) { continue }
            foreach ($item in @($group.hooks)) {
                if (-not ($item.PSObject.Properties.Name -contains 'command')) { continue }
                $match = [regex]::Match([string]$item.command, '"([^"]*hooks[\\/]capture\.py)"')
                if ($match.Success) { $match.Groups[1].Value }
            }
        }
    }
    return @($found | Sort-Object -Unique | Where-Object {
        -not [string]::Equals([IO.Path]::GetFullPath($_), $mine, [StringComparison]::OrdinalIgnoreCase)
    })
}

function Invoke-Cli([string]$Python, [string[]]$Arguments) {
    Push-Location $InstallDir
    try {
        Invoke-Native $Python (@('-m', 'backend.cli') + $Arguments)
    } finally {
        Pop-Location
    }
}

function Uninstall-Room {
    Write-Step 'Encerrando o servidor'
    Stop-RoomServer

    Write-Step 'Removendo hooks do Claude Code'
    if (Test-Path -LiteralPath (Join-Path $InstallDir 'backend\cli.py')) {
        $venvPython = Join-Path $InstallDir '.venv\Scripts\python.exe'
        if (Test-PythonCandidate $venvPython @()) {
            $python = @($venvPython)
        } else {
            # hooks-remove only needs the standard library.
            $python = Find-Python
        }
        if ($python) {
            Backup-Settings
            Invoke-Cli $python[0] (@($python | Select-Object -Skip 1) + @('hooks-remove', '--settings', $ClaudeSettings))
        } else {
            Write-Warn 'Python não encontrado; remova manualmente os hooks que apontam para hooks\capture.py.'
        }
    } else {
        Write-Warn "Nenhuma instalação em $InstallDir; nada a remover dos hooks."
    }

    $shortcut = Get-ShortcutPath
    if (Test-Path -LiteralPath $shortcut) {
        Remove-Item -LiteralPath $shortcut -Force
        Write-Note 'Atalho de inicialização removido.'
    }
    if ($RemoveFiles -and (Test-Path -LiteralPath $InstallDir)) {
        Set-Location $env:TEMP
        Remove-Item -LiteralPath $InstallDir -Recurse -Force
        Write-Note "Pasta removida: $InstallDir"
    }
    if ($RemoveData) {
        foreach ($dir in (Get-DataDir), (Join-Path $env:USERPROFILE '.ai-operations-room-demo')) {
            if (Test-Path -LiteralPath $dir) {
                Remove-Item -LiteralPath $dir -Recurse -Force
                Write-Note "Dados removidos: $dir"
            }
        }
    }
    Write-Host ''
    Write-Host 'AI Operations Room desinstalado.' -ForegroundColor Green
}

function Install-Room {
    Write-Step 'Verificando Git e Python'
    Get-Git
    $python = Get-Python
    $pyExe = $python[0]
    $pyPrefix = @($python | Select-Object -Skip 1)
    Write-Note "Python: $(& $pyExe @($pyPrefix + @('-c', 'import sys; print(sys.executable)')))"

    Stop-RoomServer

    if (Test-Path -LiteralPath (Join-Path $InstallDir '.git')) {
        Write-Step "Atualizando $InstallDir"
        $dirty = & git -C $InstallDir status --porcelain --untracked-files=no
        if ($dirty) {
            throw "Há alterações locais em $InstallDir. Salve-as ou descarte-as antes de atualizar."
        }
        Invoke-Native git @('-C', $InstallDir, 'remote', 'set-url', 'origin', $RepoUrl)
        Invoke-Native git @('-C', $InstallDir, 'fetch', '--quiet', 'origin', $Branch)
        Invoke-Native git @('-C', $InstallDir, 'checkout', '--quiet', '-B', $Branch, "origin/$Branch")
    } elseif ((Test-Path -LiteralPath $InstallDir) -and (Get-ChildItem -LiteralPath $InstallDir -Force | Select-Object -First 1)) {
        throw "$InstallDir existe, não está vazia e não é um clone do Git. Escolha outra pasta com -InstallDir."
    } else {
        Write-Step "Clonando $RepoUrl ($Branch) em $InstallDir"
        Invoke-Native git @('clone', '--quiet', '--branch', $Branch, $RepoUrl, $InstallDir)
    }
    Write-Note "Versão: $(& git -C $InstallDir log -1 --format='%h %s')"

    Write-Step 'Preparando o ambiente Python (.venv)'
    $venvPython = Join-Path $InstallDir '.venv\Scripts\python.exe'
    if ((Test-Path -LiteralPath $venvPython) -and -not (Test-PythonCandidate $venvPython @())) {
        Write-Note 'Ambiente existente inválido; recriando.'
        Remove-Item -LiteralPath (Join-Path $InstallDir '.venv') -Recurse -Force
    }
    if (-not (Test-Path -LiteralPath $venvPython)) {
        Invoke-Native $pyExe ($pyPrefix + @('-m', 'venv', (Join-Path $InstallDir '.venv')))
    }
    Push-Location $InstallDir
    try {
        # No double quotes in Python code: PowerShell 5.1 and 7 escape them differently.
        $code = "import tomllib; print(chr(10).join(tomllib.load(open('pyproject.toml', 'rb'))['project']['dependencies']))"
        $deps = @(& $venvPython -c $code | Where-Object { $_ })
    } finally {
        Pop-Location
    }
    if (-not $deps) { throw 'Não foi possível ler as dependências de pyproject.toml.' }
    Invoke-Native $venvPython (@('-m', 'pip', 'install', '--quiet', '--disable-pip-version-check', '--upgrade') + $deps)
    Write-Note "Dependências: $($deps -join ', ')"

    Write-Step 'Registrando hooks do Claude Code'
    Backup-Settings
    Invoke-Cli $venvPython @('hooks-install', '--settings', $ClaudeSettings)
    foreach ($other in (Find-ForeignHooks)) {
        Write-Warn "Há outro hook do AI Operations Room em $other. Eventos serão gravados em dobro; remova-o com hooks-remove naquele checkout."
    }

    $shortcut = Get-ShortcutPath
    if ($NoStartup) {
        if (Test-Path -LiteralPath $shortcut) {
            Remove-Item -LiteralPath $shortcut -Force
            Write-Note 'Atalho de inicialização removido (-NoStartup).'
        }
    } else {
        Write-Step 'Criando atalho na pasta Inicializar'
        $startRoom = Join-Path $InstallDir 'scripts\start-room.ps1'
        $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$startRoom`" -Port $Port"
        if ($NoBrowserAtLogin) { $arguments += ' -NoBrowser' }
        $shell = New-Object -ComObject WScript.Shell
        $link = $shell.CreateShortcut($shortcut)
        $link.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $link.Arguments = $arguments
        $link.WorkingDirectory = $InstallDir
        $link.WindowStyle = 7
        $link.Description = 'Inicia o AI Operations Room'
        $link.Save()
        Write-Note $shortcut
    }

    if (-not $NoStart) {
        Write-Step 'Iniciando o servidor'
        if (Test-Health) {
            throw "A porta $Port já responde a outro servidor. Feche-o ou use -Port."
        }
        $startArgs = @{ Port = $Port }
        if ($NoBrowser) { $startArgs['NoBrowser'] = $true }
        & (Join-Path $InstallDir 'scripts\start-room.ps1') @startArgs
    }

    Write-Host ''
    Write-Host 'AI Operations Room instalado.' -ForegroundColor Green
    Write-Note "Sala:        http://127.0.0.1:$Port/"
    Write-Note "Instalação:  $InstallDir"
    Write-Note "Dados:       $(Get-DataDir)"
    Write-Note 'Sessões do Claude Code abertas antes da instalação só são capturadas depois de reiniciadas.'
    Write-Note 'Para atualizar, execute este script de novo. Para remover, use -Uninstall.'
}

if ($RemoveFiles -or $RemoveData) {
    if (-not $Uninstall) { throw '-RemoveFiles e -RemoveData só valem junto com -Uninstall.' }
}
$InstallDir = [IO.Path]::GetFullPath($InstallDir)
if ($Uninstall) { Uninstall-Room } else { Install-Room }
