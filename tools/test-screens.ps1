# Walks the box through the screens that need a human eye: long titles, DONE,
# and FAILED. Each phase is held long enough to photograph.
#
#   powershell -ExecutionPolicy Bypass -File tools\test-screens.ps1
#
# Timeline (seconds from start):
#   0-12   two cards, one with a name long enough to be truncated
#   12-14  back to READY
#   14-26  DONE held on screen
#   26-38  FAILED held on screen
#   38+    READY

param([string]$Bridge = "http://127.0.0.1:7331")

$ErrorActionPreference = "Stop"

function Post($o) {
  $body = $o | ConvertTo-Json -Compress -Depth 4
  Invoke-RestMethod -Method Post -Uri "$Bridge/v1/agent-hooks" -ContentType "application/json" -Body $body | Out-Null
}

# DONE and FAILED only appear when nothing is open, so the caller's own live
# sessions have to be dropped first; the next real event brings them back.
function Clear-Sessions {
  try {
    $status = Invoke-RestMethod "$Bridge/v1/status"
    foreach ($session in @($status.sessions)) {
      if ($session.id) {
        Post @{ agent = "opencode"; session_id = $session.id; event = "session_end" }
      }
    }
  } catch { }
  Start-Sleep -Milliseconds 600
}

function Hold-Done($tag) {
  # Re-announcing a finished turn every three seconds keeps the five-second
  # DONE screen up for as long as this loop runs.
  for ($i = 0; $i -lt 6; $i++) {
    $id = "ses_$tag$i"
    Post @{ agent = "opencode"; session_id = $id; event = "working"; cwd = "D:\code\test" }
    Start-Sleep -Milliseconds 400
    Post @{ agent = "opencode"; session_id = $id; event = "done" }
    Start-Sleep -Seconds 5
  }
}

function Hold-Failed($tag) {
  for ($i = 0; $i -lt 6; $i++) {
    $id = "ses_$tag$i"
    Post @{ agent = "opencode"; session_id = $id; event = "working"; cwd = "D:\code\test" }
    Start-Sleep -Milliseconds 400
    Post @{ agent = "opencode"; session_id = $id; event = "stopped" }
    Start-Sleep -Seconds 5
  }
}

Write-Host "phase 1: two cards, long title (12 s)"
Post @{ agent = "opencode"; session_id = "ses_shot_short"; event = "working"; cwd = "D:\code\vibe-buddy" }
Start-Sleep -Milliseconds 500
Post @{ agent = "opencode"; session_id = "ses_shot_long"; event = "working"; cwd = "D:\code\this-is-a-very-long-project-name-that-should-be-truncated-on-the-card" }
Start-Sleep -Seconds 20

Post @{ agent = "opencode"; session_id = "ses_shot_short"; event = "session_end" }
Post @{ agent = "opencode"; session_id = "ses_shot_long"; event = "session_end" }
Clear-Sessions
Write-Host "phase 2: READY (2 s)"
Start-Sleep -Seconds 2

Write-Host "phase 3: DONE (12 s)"
Clear-Sessions
Hold-Done "done"
Write-Host "phase 4: FAILED (12 s)"
Clear-Sessions
Hold-Failed "fail"
Write-Host "done"


