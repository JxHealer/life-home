# 開賣提醒：售票開始前 1 小時，發 Discord 通知
# 活動資料在 data/events/*.json（Claude 更新行事曆後上傳，只有含售票時間的遊戲、追星活動）。
# 由 GitHub Actions 每 10 分鐘執行（.github/workflows/tickets.yml），不消耗 Claude 用量。
# 用法：./scripts/ticket-reminder.ps1 [-Test]
#   -Test：不管時間，把下一個開賣項目發一則【測試】通知，不記錄為已通知

param([switch]$Test)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot/discord.ps1"

$Root = Join-Path $PSScriptRoot ".."
$EventsDir = Join-Path $Root "data/events"
$StatePath = Join-Path $Root "data/ticket-reminder-state.json"

# 開賣前 2 小時、1 小時各提醒一次（雲端排程大約 30～60 分鐘才跑一次，所以用區間判斷）
$Stages = @(@{ mins = 120; prefix = "2h|"; text = "2 小時前" }, @{ mins = 60; prefix = ""; text = "1 小時前" })
$now = [DateTimeOffset]::UtcNow
if (-not (Test-Path $EventsDir)) { exit 0 }

# 每個售票階段一筆；同一個售票階段出現在兩天場次時合併成一筆
$items = [ordered]@{}
foreach ($f in Get-ChildItem $EventsDir -Filter *.json) {
    $ev = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($ev.status -eq "false" -or -not $ev.tickets) { continue }
    foreach ($t in $ev.tickets) {
        if (-not $t.start) { continue }
        $start = [DateTimeOffset]::Parse($t.start)
        $who = if ($ev.subject) { $ev.subject } else { $ev.title }
        $key = "{0}|{1}|{2:o}" -f $who, $t.label, $start.ToOffset([TimeSpan]::FromHours(8))
        if (-not $items.Contains($key)) {
            $items[$key] = [ordered]@{ key = $key; who = $who; label = $t.label; start = $start; url = $t.url; category = $ev.category; titles = @() }
        }
        $items[$key].titles += $ev.title
    }
}

$sent = @()
if (Test-Path $StatePath) { $sent = @((Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json).sent) }

$due = @()
if ($Test) {
    $next = $items.Values | Where-Object { $_.start -gt $now } | Sort-Object { $_.start } | Select-Object -First 1
    if ($next) { $due += @{ item = $next; stage = $Stages[0] } }
} else {
    # 每一筆只發「目前所在的那一段」：剩 60～120 分鐘發 2 小時提醒，剩 60 分鐘內發 1 小時提醒
    # 1 小時提醒的紀錄沿用原本的 key，2 小時提醒在前面加 "2h|"（清理舊紀錄時看的是最後一段的時間）
    foreach ($it in $items.Values) {
        $left = ($it.start - $now).TotalMinutes
        if ($left -le 0) { continue }
        $stage = if ($left -le 60) { $Stages[1] } elseif ($left -le 120) { $Stages[0] } else { $null }
        if ($stage -and ($stage.prefix + $it.key) -notin $sent) { $due += @{ item = $it; stage = $stage } }
    }
}

$week = "日一二三四五六"
foreach ($d in $due) {
    $it = $d.item
    $channel = switch ($it.category) { { $_ -in "idol", "stayc" } { "idol" } "pogo" { "pogo" } "pikmin" { "pikmin" } default { "game" } }
    $local = $it.start.ToOffset([TimeSpan]::FromHours(8))
    $mins = [math]::Max(0, [math]::Round(($it.start - $now).TotalMinutes))
    $desc = "**{0}**`n{1}`n`n⏰ **{2:M/d}（{3}）{2:HH:mm}** 開賣，大約還有 **{4} 分鐘**`n`n☁️ 雲端通知" -f $it.who, $it.label, $local, $week[[int]$local.DayOfWeek], $mins
    $fields = @(@{ name = "場次"; value = (($it.titles | Select-Object -Unique) -join "`n"); inline = $false })
    if ($it.url) { $fields += @{ name = "購票網站"; value = $it.url; inline = $false } }
    $prefix = if ($Test) { "🧪【測試】" } else { "" }
    Send-Discord -Channel $channel -Color 0xE5484D -Title "$($prefix)🎫 開賣提醒（$($d.stage.text)）｜$($it.who)" -Description $desc -Fields $fields
    if (-not $Test) { $sent += $d.stage.prefix + $it.key }
    Write-Host ("{0}通知 {1}{2}" -f $prefix, $d.stage.prefix, $it.key)
}

if (-not $Test -and $due.Count -gt 0) {
    # 只留還沒過期太久的紀錄，檔案不會越來越大
    $keep = @($sent | Where-Object { $p = ($_ -split '\|')[-1]; try { [DateTimeOffset]::Parse($p) -gt $now.AddDays(-7) } catch { $false } })
    [System.IO.File]::WriteAllText($StatePath, (@{ sent = $keep } | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
}
