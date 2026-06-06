param(
    [ValidateSet("auto", "stable", "ptb", "canary")]
    [string]$Branch = "auto",

    [switch]$Install,
    [switch]$Uninstall,
    [switch]$PatchNow,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Name = "SafeVencordAutoPatch"
$AppDir = Join-Path $env:LOCALAPPDATA $Name
$InstalledScript = Join-Path $AppDir "safe-vencord-autopatch.ps1"
$InstallerPath = Join-Path $AppDir "VencordInstallerCli.exe"
$ChecksumPath = Join-Path $AppDir "checksums.sha256"
$StatePath = Join-Path $AppDir "state.json"
$LogPath = Join-Path $AppDir "patch.log"
$CliUrl = "https://github.com/Vencord/Installer/releases/latest/download/VencordInstallerCli.exe"
$ChecksumsUrl = "https://github.com/Vencord/Installer/releases/latest/download/checksums.sha256"

function Write-Log {
    param([string]$Message)

    New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Write-Host $line
    Add-Content -LiteralPath $LogPath -Value $line
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Administrator {
    if (-not (Test-IsAdministrator)) {
        throw "Run PowerShell as Administrator."
    }
}

function Assert-OfficialAssetUrl {
    param([string]$Url)

    $uri = [Uri]$Url
    $isOfficialRelease = $uri.AbsolutePath.StartsWith("/Vencord/Installer/releases/download/") -or
        $uri.AbsolutePath.StartsWith("/Vencord/Installer/releases/latest/download/")

    if ($uri.Scheme -ne "https" -or $uri.Host -ne "github.com" -or -not $isOfficialRelease) {
        throw "Refusing untrusted URL: $Url"
    }
}

function Get-ExpectedHash {
    param([string]$AssetName)

    $line = Get-Content -LiteralPath $ChecksumPath |
        Where-Object { $_ -match [regex]::Escape($AssetName) + "\s*$" } |
        Select-Object -First 1

    if (-not $line -or $line -notmatch "^([a-fA-F0-9]{64})\s+\*?\.?/?$([regex]::Escape($AssetName))\s*$") {
        throw "Could not find $AssetName in checksums.sha256"
    }

    return $Matches[1].ToLowerInvariant()
}

function Get-OfficialCli {
    New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
    $headers = @{ "User-Agent" = $Name }

    Assert-OfficialAssetUrl $CliUrl
    Assert-OfficialAssetUrl $ChecksumsUrl

    Invoke-WebRequest -Uri $ChecksumsUrl -OutFile $ChecksumPath -Headers $headers
    $expectedHash = Get-ExpectedHash -AssetName "VencordInstallerCli.exe"

    $needsDownload = -not (Test-Path -LiteralPath $InstallerPath)
    if (-not $needsDownload) {
        $currentHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $InstallerPath).Hash.ToLowerInvariant()
        $needsDownload = $currentHash -ne $expectedHash
    }

    if ($needsDownload) {
        $tempPath = "$InstallerPath.download"
        Write-Log "Downloading official VencordInstallerCli.exe"
        Invoke-WebRequest -Uri $CliUrl -OutFile $tempPath -Headers $headers

        $downloadedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $tempPath).Hash.ToLowerInvariant()
        if ($downloadedHash -ne $expectedHash) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
            throw "Installer hash mismatch"
        }

        Move-Item -LiteralPath $tempPath -Destination $InstallerPath -Force
    }
}

function Get-DiscordFingerprint {
    $branches = @{
        stable = "Discord"
        ptb = "DiscordPTB"
        canary = "DiscordCanary"
    }

    $selected = if ($Branch -eq "auto") { @("stable", "ptb", "canary") } else { @($Branch) }
    $parts = @()

    foreach ($item in $selected) {
        $base = Join-Path $env:LOCALAPPDATA $branches[$item]
        if (-not (Test-Path -LiteralPath $base)) {
            continue
        }

        $appDir = Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "app-*" } |
            Sort-Object Name -Descending |
            Select-Object -First 1

        if (-not $appDir) {
            continue
        }

        $asar = Join-Path $appDir.FullName "resources\app.asar"
        if (Test-Path -LiteralPath $asar) {
            $file = Get-Item -LiteralPath $asar -ErrorAction SilentlyContinue
            if (-not $file -or $file.PSIsContainer) {
                continue
            }
            $parts += "{0}|{1}|{2}|{3}" -f $item, $file.FullName, $file.Length, $file.LastWriteTimeUtc.Ticks
        }
    }

    return ($parts | Sort-Object) -join "`n"
}

function Get-DiscordBranchesToPatch {
    $branches = @{
        stable = "Discord"
        ptb = "DiscordPTB"
        canary = "DiscordCanary"
    }

    if ($Branch -ne "auto") {
        return @($Branch)
    }

    $found = @()
    foreach ($item in @("stable", "ptb", "canary")) {
        $base = Join-Path $env:LOCALAPPDATA $branches[$item]
        if (-not (Test-Path -LiteralPath $base)) {
            continue
        }

        $appDir = Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "app-*" } |
            Sort-Object Name -Descending |
            Select-Object -First 1

        if (-not $appDir) {
            continue
        }

        $asar = Join-Path $appDir.FullName "resources\app.asar"
        $file = Get-Item -LiteralPath $asar -ErrorAction SilentlyContinue
        if ($file -and -not $file.PSIsContainer) {
            $found += $item
        }
    }

    return $found
}

function Get-SavedFingerprint {
    if (-not (Test-Path -LiteralPath $StatePath)) {
        return ""
    }

    $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    if ($null -eq $state.fingerprint) {
        return ""
    }

    return [string]$state.fingerprint
}

function Save-Fingerprint {
    param([string]$Fingerprint)

    @{ fingerprint = $Fingerprint; patchedAt = (Get-Date).ToUniversalTime().ToString("o") } |
        ConvertTo-Json |
        Set-Content -LiteralPath $StatePath
}

function Invoke-VencordCli {
    param([string]$BranchToPatch)

    $stdoutPath = Join-Path $AppDir "vencord-cli.stdout.log"
    $stderrPath = Join-Path $AppDir "vencord-cli.stderr.log"
    Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue

    $process = Start-Process -FilePath $InstallerPath -ArgumentList @("-install", "-branch", $BranchToPatch) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

    foreach ($path in @($stdoutPath, $stderrPath)) {
        if (Test-Path -LiteralPath $path) {
            Get-Content -LiteralPath $path | ForEach-Object {
                Write-Host $_
                Add-Content -LiteralPath $LogPath -Value $_
            }
        }
    }

    return $process.ExitCode
}

function Invoke-PatchIfNeeded {
    $fingerprint = Get-DiscordFingerprint
    if ([string]::IsNullOrWhiteSpace($fingerprint)) {
        Write-Log "No Discord install found"
        return
    }

    $saved = Get-SavedFingerprint
    if (-not $Force -and $saved -eq $fingerprint) {
        Write-Log "Discord unchanged; nothing to patch"
        return
    }

    Get-OfficialCli
    foreach ($branchToPatch in (Get-DiscordBranchesToPatch)) {
        Write-Log "Discord changed; running official Vencord CLI for $branchToPatch"
        $exitCode = Invoke-VencordCli -BranchToPatch $branchToPatch
        if ($exitCode -ne 0) {
            throw "Vencord installer exited with code $exitCode for $branchToPatch"
        }
    }

    $patchedFingerprint = Get-DiscordFingerprint
    if (-not [string]::IsNullOrWhiteSpace($patchedFingerprint)) {
        Save-Fingerprint -Fingerprint $patchedFingerprint
    }
    Write-Log "Patch complete"
}

function Install-Task {
    Assert-Administrator

    New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
    Copy-Item -LiteralPath $PSCommandPath -Destination $InstalledScript -Force

    $taskArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$InstalledScript`" -PatchNow -Branch $Branch"
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $taskArgs
    $logonTrigger = New-ScheduledTaskTrigger -AtLogOn
    $dailyTrigger = New-ScheduledTaskTrigger -Daily -At 12:00
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

    Register-ScheduledTask -TaskName $Name -Action $action -Trigger @($logonTrigger, $dailyTrigger) -Settings $settings -Principal $principal -Description "Checks Discord changes at logon and once daily, then re-runs the official Vencord CLI only when needed." -Force | Out-Null
    Write-Log "Installed scheduled task: $Name"
    Start-ScheduledTask -TaskName $Name
    Write-Log "Started scheduled task: $Name"
}

function Uninstall-Task {
    Assert-Administrator

    $task = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -TaskName $Name -Confirm:$false
    }

    Write-Log "Removed scheduled task: $Name"
}

try {
    if ($Uninstall) {
        Uninstall-Task
        exit 0
    }

    if ($Install) {
        Install-Task
        exit 0
    }

    if ($PatchNow -or (-not $Install -and -not $Uninstall)) {
        Invoke-PatchIfNeeded
    }
} catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    exit 1
}
