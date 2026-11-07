# vibebuddy-bridge: the small host program that feeds the box while VibeBuddy's
# real daemon has no Windows build yet.
#
#   powershell -ExecutionPolicy Bypass -File tools\bridge.ps1
#
# It listens on 127.0.0.1:7331 for the OpenCode plugin (tools\opencode-plugin.js),
# keeps one card per live agent session, and writes VibeBuddy Protocol v1 lines
# to the box over the USB cable. No dependencies beyond Windows PowerShell.

param(
  [string]$Port = "COM5",
  [int]$HttpPort = 7331,
  [int]$Baud = 115200,
  [int]$StaleSeconds = 90,
  [switch]$Verbose
)

$ErrorActionPreference = "Continue"

$stateDir = Join-Path $env:LOCALAPPDATA "vibe-buddy-bridge"
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
$statsFile = Join-Path $stateDir "stats.json"

# --- state -------------------------------------------------------------------

$sessions = @{}   # session id -> hashtable
$stats = @{ day = (Get-Date -Format "yyyyMMdd"); done = 0; asks = 0; busy = 0 }
$usage = @{ hour = $null; week = $null; month = $null; at = [datetime]::MinValue }
$lastSignature = ""
$lastHeartbeat = [datetime]::MinValue
$lastPersist = [datetime]::MinValue
$lastBusyTick = Get-Date
$lastStaleCheck = [datetime]::MinValue
$deviceReady = $false
$lastStateKind = ""   # done | error | idle, so a quiet screen keeps its word

function Load-Stats {
  if (Test-Path $statsFile) {
    try {
      $saved = Get-Content $statsFile -Raw | ConvertFrom-Json
      $script:stats.day = $saved.day
      $script:stats.done = [int]$saved.done
      $script:stats.asks = [int]$saved.asks
      $script:stats.busy = [int]$saved.busy
    } catch { }
  }
}

function Save-Stats {
  try { $script:stats | ConvertTo-Json -Compress | Set-Content $statsFile -Encoding utf8 } catch { }
}

function Roll-Day {
  $today = Get-Date -Format "yyyyMMdd"
  if ($script:stats.day -ne $today) {
    $script:stats.day = $today
    $script:stats.done = 0
    $script:stats.asks = 0
    $script:stats.busy = 0
    $script:lastSignature = ""
    Save-Stats
  }
}

Load-Stats

# --- the box link ------------------------------------------------------------

$serial = $null

function Open-Serial {
  try {
    $port = New-Object System.IO.Ports.SerialPort $Port, $Baud, None, 8, one
    $port.ReadTimeout = 20
    $port.WriteTimeout = 500
    $port.DtrEnable = $true
    $port.Open()
    $script:serial = $port
    Start-Sleep -Milliseconds 300
    Send-Line @{ version = 1; event = "device.hello" }
    $script:lastSignature = ""
    Write-Host "[bridge] serial $Port open" -ForegroundColor Green
    return $true
  } catch {
    $script:serial = $null
    return $false
  }
}

function Send-Line($object) {
  if (-not $script:serial -or -not $script:serial.IsOpen) { return }
  try {
    $line = $object | ConvertTo-Json -Compress -Depth 6
    $script:serial.WriteLine($line)
    if ($Verbose) { Write-Host "[tx] $line" -ForegroundColor DarkCyan }
  } catch {
    try { $script:serial.Close() } catch { }
    $script:serial = $null
  }
}

function Read-Device {
  if (-not $script:serial -or -not $script:serial.IsOpen) { return }
  try {
    $text = $script:serial.ReadExisting()
  } catch {
    try { $script:serial.Close() } catch { }
    $script:serial = $null
    return
  }
  if (-not $text) { return }
  foreach ($line in ($text -split "`r?`n")) {
    if (-not $line) { continue }
    if ($line -like "DISPLAY READY BUILD *") {
      $script:deviceReady = $true
      Write-Host "[box] $line" -ForegroundColor Green
    } elseif ($Verbose) {
      Write-Host "[box] $line" -ForegroundColor DarkGray
    }
  }
}

# --- cards -------------------------------------------------------------------

function Get-Branch($dir) {
  try {
    $branch = & git -C $dir rev-parse --abbrev-ref HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and $branch) {
      $name = ($branch | Select-Object -First 1).Trim()
      # "main" on every card says nothing; the project name reads better.
      if ($name -and $name -ne "main" -and $name -ne "master" -and $name -ne "HEAD") { return $name }
    }
  } catch { }
  return $null
}

function New-Session($id, $cwd) {
  $project = if ($cwd) { Split-Path $cwd -Leaf } else { "session" }
  $title = $null
  if ($cwd) { $title = Get-Branch $cwd }
  if (-not $title) { $title = $project }
  $sessions[$id] = @{
    id = $id
    cwd = $cwd
    project = $project
    title = $title
    status = "working"
    since = (Get-Date)
    last_seen = (Get-Date)
    tok_s = 0
    tok_at = [datetime]::MinValue
  }
}

function Set-Status($id, $status) {
  if (-not $sessions.ContainsKey($id)) { return }
  $session = $sessions[$id]
  if ($session.status -ne $status) {
    $session.since = (Get-Date)
  }
  $session.status = $status
}

# A session is first seen from its prompt, which may not carry a directory; the
# session events that follow do, and on a shared OpenCode service that is the
# only reliable way to know which project a card belongs to.
function Update-Cwd($id, $cwd) {
  if (-not $cwd) { return }
  $session = $sessions[$id]
  if (-not $session) { return }
  if ($session.cwd -eq $cwd) { return }
  $session.cwd = $cwd
  $session.project = Split-Path $cwd -Leaf
  $branch = Get-Branch $cwd
  if ($branch) { $session.title = $branch } else { $session.title = $session.project }
}

function Get-TaskList {
  $open = @()
  foreach ($session in $sessions.Values) {
    if ($session.status -eq "done") { continue }
    $elapsed = [int]((Get-Date) - $session.since).TotalSeconds
    if ($elapsed -lt 0) { $elapsed = 0 }
    $tok_s = 0
    if ($session.tok_s -and ((Get-Date) - $session.tok_at).TotalMilliseconds -le 2000) {
      $tok_s = [math]::Round([double]$session.tok_s, 1)
    }
    $open += [pscustomobject]@{
      id = $session.id
      agent = "opencode"
      title = $session.title
      project = $session.project
      status = $session.status
      elapsed_s = $elapsed
      tok_s = $tok_s
      _since = $session.since
    }
  }
  # Waiting-on-you first, then whatever moved most recently; six is what the
  # protocol allows, the box itself draws three.
  $sorted = @($open | Sort-Object -Property @{ Expression = { if ($_.status -eq "input_required") { 0 } else { 1 } } },
                                            @{ Expression = { $_._since }; Descending = $true })
  return @($sorted | Select-Object -First 6)
}

function Get-Stats {
  @(
    "$($script:stats.done) DONE",
    "$($script:stats.asks) ASKS",
    (Format-Busy $script:stats.busy)
  )
}

function Format-Busy($seconds) {
  $hours = [int]($seconds / 3600)
  $minutes = [int](($seconds % 3600) / 60)
  if ($hours -gt 0) { return "${hours}H{0:D2} BUSY" -f $minutes }
  return "${minutes}M BUSY"
}

# Decides which single event describes the current set, and whether it differs
# from what the box already shows. The box counts elapsed time on its own, so
# identical states are not resent.
function Publish-State {
  # @() matters: a function that returns one object hands back that object, not
  # an array, and ConvertTo-Json would then write "tasks": {...} instead of
  # "tasks": [{...}], which the box cannot read.
  $tasks = @(Get-TaskList)
  $kind = "idle"
  $event = "agent.idle"
  $title = ""

  if ($tasks.Count -gt 0) {
    if ($tasks[0].status -eq "input_required") {
      $kind = "input"
      $event = "agent.input_required"
    } else {
      $kind = "working"
      $event = "task.start"
    }
    $title = $tasks[0].title
  } elseif ($script:lastStateKind -eq "done" -or $script:lastStateKind -eq "error") {
    $kind = $script:lastStateKind
    $event = if ($kind -eq "done") { "task.done" } else { "task.error" }
  }

  # Plan usage belongs on the quiet screen only, and only while it is recent
  # enough to trust (the go-usage plugin refreshes it on its own schedule).
  $usagePayload = $null
  if ($kind -eq "idle" -and ((Get-Date) - $script:usage.at).TotalMinutes -lt 30) {
    if ($null -ne $script:usage.hour -or $null -ne $script:usage.week -or $null -ne $script:usage.month) {
      $usagePayload = @{
        hour = $script:usage.hour
        week = $script:usage.week
        month = $script:usage.month
      }
    }
  }

  $signature = "$kind|" +
    (($tasks | ForEach-Object { "$($_.id):$($_.status):$($_.title):$($_.tok_s)" }) -join ",") +
    "|u:$($usagePayload.hour),$($usagePayload.week),$($usagePayload.month)"
  if ($signature -eq $script:lastSignature) { return }
  $script:lastSignature = $signature
  $script:lastStateKind = $kind

  $line = @{
    version = 1
    event = $event
    title = $title
    tasks = @($tasks)
    tasks_total = $tasks.Count
    stats = Get-Stats
  }
  if ($null -ne $usagePayload) { $line.usage = $usagePayload }
  Send-Line $line
  Write-Host "[state] $event  ($($tasks.Count) task(s)) $title" -ForegroundColor Yellow
}

function Handle-Agent($payload) {
  $id = $payload.session_id
  if (-not $id) { return }
  Roll-Day
  $cwd = $payload.cwd
  $event = $payload.event

  if ($sessions.ContainsKey($id)) {
    $sessions[$id].last_seen = (Get-Date)
  }

  switch ($event) {
    "working" {
      if (-not $sessions.ContainsKey($id)) {
        New-Session $id $cwd
      } else {
        $sessions[$id].status = "working"
        Update-Cwd $id $cwd
      }
    }
    "needs_input" {
      if (-not $sessions.ContainsKey($id)) { New-Session $id $cwd }
      Update-Cwd $id $cwd
      if ($sessions[$id].status -ne "input_required") {
        $script:stats.asks++
        Set-Status $id "input_required"
      }
    }
    "done" {
      if ($sessions.ContainsKey($id)) {
        $script:stats.done++
        $sessions.Remove($id)
        $script:lastStateKind = "done"
      }
    }
    "stopped" {
      if ($sessions.ContainsKey($id)) {
        $sessions.Remove($id)
        $script:lastStateKind = "error"
      }
    }
    "session_end" {
      if ($sessions.ContainsKey($id)) { $sessions.Remove($id) }
    }
    default { return }
  }

  # Stored after the switch so a brand-new session (created above) takes it too.
  if ($null -ne $payload.tok_s -and $sessions.ContainsKey($id)) {
    $sessions[$id].tok_s = [double]$payload.tok_s
    $sessions[$id].tok_at = (Get-Date)
  }

  Publish-State
}

# --- tiny HTTP server --------------------------------------------------------

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $HttpPort)
try {
  $listener.Start()
} catch {
  Write-Host "[bridge] cannot listen on 127.0.0.1:$HttpPort - $($_.Exception.Message)" -ForegroundColor Red
  exit 1
}

function Read-Http($stream) {
  $buffer = New-Object System.Collections.Generic.List[byte]
  $one = New-Object byte[] 1
  $header = ""
  while ($true) {
    if ($stream.Read($one, 0, 1) -le 0) { return $null }
    $buffer.Add($one[0])
    if ($buffer.Count -gt 4) {
      $tail = [System.Text.Encoding]::ASCII.GetString($buffer.GetRange($buffer.Count - 4, 4).ToArray())
      if ($tail -eq "`r`n`r`n") { break }
    }
    if ($buffer.Count -gt 16384) { return $null }
  }
  $header = [System.Text.Encoding]::ASCII.GetString($buffer.ToArray())
  $lines = $header -split "`r`n"
  $requestLine = $lines[0] -split " "
  $method = $requestLine[0]
  $path = $requestLine[1]
  $length = 0
  foreach ($line in $lines) {
    if ($line -match "^Content-Length:\s*(\d+)$") { $length = [int]$Matches[1] }
  }
  $body = ""
  if ($length -gt 0) {
    $bytes = New-Object byte[] $length
    $read = 0
    while ($read -lt $length) {
      $n = $stream.Read($bytes, $read, $length - $read)
      if ($n -le 0) { break }
      $read += $n
    }
    $body = [System.Text.Encoding]::UTF8.GetString($bytes, 0, $read)
  }
  return @{ method = $method; path = $path; body = $body }
}

function Send-Http($stream, $status, $json) {
  $text = $json | ConvertTo-Json -Compress -Depth 5
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
  $head = "HTTP/1.1 $status`r`nContent-Type: application/json`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n"
  $headBytes = [System.Text.Encoding]::ASCII.GetBytes($head)
  $stream.Write($headBytes, 0, $headBytes.Length)
  $stream.Write($bytes, 0, $bytes.Length)
  $stream.Flush()
}

function Handle-Client($client) {
  try {
    $client.ReceiveTimeout = 1000
    $stream = $client.GetStream()
    $request = Read-Http $stream
    if ($null -eq $request) { return }
    if ($request.method -eq "POST" -and ($request.path -eq "/v1/agent-hooks" -or $request.path -eq "/v1/events")) {
      $payload = $null
      try { $payload = $request.body | ConvertFrom-Json } catch { }
      if ($payload -and $payload.session_id) {
        Handle-Agent $payload
      } elseif ($payload -and $payload.event) {
        # A raw protocol event posted by hand: forward it as-is.
        Send-Line $payload
      }
      Send-Http $stream "200 OK" @{ ok = $true }
    } elseif ($request.method -eq "POST" -and $request.path -eq "/v1/usage") {
      $payload = $null
      try { $payload = $request.body | ConvertFrom-Json } catch { }
      if ($payload) {
        $script:usage.hour = if ($null -ne $payload.hour) { [int]$payload.hour } else { $null }
        $script:usage.week = if ($null -ne $payload.week) { [int]$payload.week } else { $null }
        $script:usage.month = if ($null -ne $payload.month) { [int]$payload.month } else { $null }
        $script:usage.at = Get-Date
        $script:lastSignature = ""
        Publish-State
      }
      Send-Http $stream "200 OK" @{ ok = $true }
    } elseif ($request.method -eq "GET" -and $request.path -like "/v1/status*") {
      $status = @(Get-TaskList | Select-Object id, agent, title, project, status, elapsed_s, tok_s)
      Send-Http $stream "200 OK" @{
        device = [bool]$script:deviceReady
        port = $Port
        sessions = $status
        stats = (Get-Stats)
        day = $script:stats.day
      }
    } else {
      Send-Http $stream "404 Not Found" @{ ok = $false }
    }
  } catch {
    if ($Verbose) { Write-Host "[http] $($_.Exception.Message)" -ForegroundColor DarkYellow }
  } finally {
    try { $client.Close() } catch { }
  }
}

# --- main loop ---------------------------------------------------------------

Write-Host "[bridge] listening on http://127.0.0.1:$HttpPort (POST /v1/agent-hooks, GET /v1/status)" -ForegroundColor Green
Open-Serial | Out-Null

while ($true) {
  if (-not $serial -or -not $serial.IsOpen) {
    if (-not (Open-Serial)) { Start-Sleep -Milliseconds 1500 }
  }

  Read-Device

  while ($listener.Pending()) {
    $client = $listener.AcceptTcpClient()
    Handle-Client $client
  }

  $now = Get-Date
  Roll-Day

  # A session that has gone quiet (OpenCode closed, a turn dropped) must not
  # leave a card up forever. The plugin sends a heartbeat every 30 s while a
  # turn is open, so silence beyond the timeout means it is really gone.
  if (($now - $lastStaleCheck).TotalSeconds -ge 5) {
    $lastStaleCheck = $now
    $dropped = $false
    foreach ($id in @($sessions.Keys)) {
      $session = $sessions[$id]
      if (($now - $session.last_seen).TotalSeconds -gt $StaleSeconds) {
        $sessions.Remove($id)
        Write-Host "[stale] dropped $($session.title) after $StaleSeconds s" -ForegroundColor DarkYellow
        $dropped = $true
      }
    }
    if ($dropped) { Publish-State }
  }

  if (($now - $lastHeartbeat).TotalSeconds -ge 5) {
    $lastHeartbeat = $now
    Send-Line @{ version = 1; event = "device.heartbeat"; build = "bridge-0.1"; hour = $now.Hour; day = [int]($now.ToString("yyyyMMdd")) }
  }

  # Busy time counts while at least one session is working.
  if (($now - $lastBusyTick).TotalSeconds -ge 1) {
    $lastBusyTick = $now
    foreach ($session in $sessions.Values) {
      if ($session.status -eq "working") { $script:stats.busy++; break }
    }
  }

  if (($now - $lastPersist).TotalSeconds -ge 30) {
    $lastPersist = $now
    Save-Stats
  }

  Start-Sleep -Milliseconds 25
}

