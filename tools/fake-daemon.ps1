# Fake vibebuddyd: sends the VibeBuddy Protocol v1 sequence to the box over the
# USB cable, so the firmware can be exercised without the real daemon.
#
#   powershell -ExecutionPolicy Bypass -File tools\fake-daemon.ps1 -Mode demo
#
# Modes: demo (full walk through the states), working, input, done, idle.

param(
  [string]$Port = "COM5",
  [ValidateSet("demo", "working", "input", "done", "idle")][string]$Mode = "demo"
)

$ErrorActionPreference = "Stop"
$p = New-Object System.IO.Ports.SerialPort $Port, 115200, None, 8, one
$p.ReadTimeout = 100
$p.Open()

function Send-Event($obj) {
  $line = $obj | ConvertTo-Json -Compress -Depth 6
  $p.WriteLine($line)
  Write-Host "TX $line" -ForegroundColor Cyan
}

function Pump([int]$milliseconds) {
  $until = (Get-Date).AddMilliseconds($milliseconds)
  while ((Get-Date) -lt $until) {
    try {
      $text = $p.ReadExisting()
      if ($text) { Write-Host -NoNewline $text }
    } catch { }
    Start-Sleep -Milliseconds 50
  }
}

function Heartbeat() {
  Send-Event @{
    version = 1; event = "device.heartbeat"; build = "fake-daemon"
    hour = (Get-Date).Hour; day = [int](Get-Date -Format "yyyyMMdd")
  }
}

function Task($id, $agent, $title, $project, $status, $elapsed) {
  @{ id = $id; agent = $agent; title = $title; project = $project; status = $status; elapsed_s = $elapsed }
}

$stats = @("3 DONE", "1 ASK", "2H10 BUSY")
$work = Task "a1" "opencode" "Fix login flow" "vibe-buddy" "working" 75
$wait = Task "a2" "claude-code" "Refactor the parser" "vibe-buddy" "input_required" 900
$done = Task "a3" "codex" "Bump the firmware" "vibe-buddy" "done" 12

Write-Host "Listening for 2 s before writing..." -ForegroundColor DarkGray
Pump 2000

Send-Event @{ version = 1; event = "device.hello" }
Pump 500
Heartbeat
Pump 500

switch ($Mode) {
  "working" {
    Send-Event @{ version = 1; event = "task.start"; title = $work.title; tasks = @($work); tasks_total = 1; stats = $stats }
    Pump 30000
  }
  "input" {
    Send-Event @{ version = 1; event = "agent.input_required"; title = $wait.title; tasks = @($wait, $work); tasks_total = 2; stats = $stats }
    Pump 30000
  }
  "done" {
    Send-Event @{ version = 1; event = "task.done"; title = $done.title; tasks = @(); tasks_total = 0; stats = $stats }
    Pump 30000
  }
  "idle" {
    Send-Event @{ version = 1; event = "agent.idle"; tasks = @(); tasks_total = 0; stats = $stats }
    Pump 30000
  }
  "demo" {
    Send-Event @{ version = 1; event = "task.start"; title = $work.title; tasks = @($work); tasks_total = 1; stats = $stats }
    Pump 6000
    Heartbeat
    Send-Event @{ version = 1; event = "agent.input_required"; title = $wait.title; tasks = @($wait, $work); tasks_total = 2; stats = $stats }
    Pump 8000
    Send-Event @{ version = 1; event = "task.done"; title = $done.title; tasks = @($work); tasks_total = 1; stats = @("4 DONE", "1 ASK", "2H10 BUSY") }
    Pump 6000
    Send-Event @{ version = 1; event = "task.done"; title = $work.title; tasks = @(); tasks_total = 0; stats = @("4 DONE", "1 ASK", "2H22 BUSY") }
    Pump 8000
    Send-Event @{ version = 1; event = "agent.idle"; tasks = @(); tasks_total = 0; stats = $stats }
    Pump 5000
  }
}

Write-Host ""
Write-Host "Done. Leaving the port open is not needed; the box shows NO LINK 15 s after the last line." -ForegroundColor DarkGray
$p.Close()
