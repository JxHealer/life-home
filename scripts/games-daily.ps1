# 遊戲日報：每天早上把「今天進行中的遊戲活動」和截止時間發到 Discord
# Pokémon GO → pogo 頻道、Pikmin Bloom → pikmin 頻道、其他遊戲 → game 頻道（各自一則訊息）
# 活動資料在 data/games.json（電腦上的 sync-events-github.ps1 從行事曆匯出）。
# 由 GitHub Actions 執行（.github/workflows/games.yml），不消耗 Claude 用量。
# 用法：./scripts/games-daily.ps1 [-Test] [-DryRun]
#   -Test：標題加上【測試】
#   -DryRun：只印出內容，不發 Discord

param([switch]$Test, [switch]$DryRun)

$ErrorActionPreference = "Stop"
if (-not $DryRun) { . "$PSScriptRoot/discord.ps1" }

$File = Join-Path $PSScriptRoot "../data/games.json"
$tw = [TimeSpan]::FromHours(8)
$now = [DateTimeOffset]::UtcNow.ToOffset($tw)
$today = $now.Date
$week = "日一二三四五六"
$data = Get-Content $File -Raw -Encoding UTF8 | ConvertFrom-Json

$cats = [ordered]@{
    pogo   = @{ name = "Pokémon GO"; icon = "🔴"; color = 0xE3350D }
    pikmin = @{ name = "Pikmin Bloom"; icon = "🌱"; color = 0x4CAF50 }
    game   = @{ name = "其他遊戲"; icon = "🎮"; color = 0x5865F2 }
}
$regions = [ordered]@{
    global   = "🏠 在家就能玩（全球）"
    taiwan   = "🇹🇼 台灣現場"
    overseas = "🌏 海外活動"
}

# 資料太久沒更新就提醒
$warn = ""
try {
    $upd = [DateTimeOffset]::Parse($data.updatedAt).ToOffset($tw)
    $age = [int]($now - $upd).TotalDays
    if ($age -gt 10) { $warn = "⚠️ 活動資料已經 $age 天沒更新，可能有新活動沒列到" }
} catch {}

function Format-End($ev) {
    $raw = [DateTimeOffset]::Parse($ev.end)
    $end = $raw.ToOffset($tw)
    $days = ($end.Date - $today).Days
    # 只有台灣時間的「整天」才省略時刻；海外的 23:59 換成台灣時間後要寫出幾點
    $whole = $raw.Offset -eq $tw -and ($ev.allDay -or ($end.Hour -eq 23 -and $end.Minute -ge 59))
    $fmt = if ($end.Year -ne $today.Year) { "yyyy/M/d" } else { "M/d" }
    $t = if ($whole) { $end.ToString($fmt) } else { $end.ToString("$fmt HH:mm") }
    $left = if ($days -le 0) { "⚠️ **今天結束**" } elseif ($days -eq 1) { "⚠️ **明天結束**" } else { "還有 $days 天" }
    return @{ text = "到 $t（$left）"; end = $end }
}

$sent = 0
foreach ($c in $cats.Keys) {
    $list = @($data.events | Where-Object {
        $_.category -eq $c -and
        [DateTimeOffset]::Parse($_.start).ToOffset($tw).Date -le $today -and
        [DateTimeOffset]::Parse($_.end) -ge $now
    })
    if ($list.Count -eq 0) { continue }

    $fields = @()
    $soon = 0
    foreach ($r in $regions.Keys) {
        $items = @($list | Where-Object { $_.region -eq $r } | Sort-Object { [DateTimeOffset]::Parse($_.end) })
        if ($items.Count -eq 0) { continue }
        $lines = foreach ($ev in $items) {
            $e = Format-End $ev
            if (($e.end.Date - $today).Days -le 1) { $soon++ }
            $tag = if ($ev.status -eq "pending") { "（待確認）" } else { "" }
            $where = if ($r -eq "overseas" -and $ev.tzName) { "📍$($ev.tzName)｜" } else { "" }
            $hl = if ($ev.highlight) { $h = [string]$ev.highlight; if ($h.Length -gt 70) { $h = $h.Substring(0, 68) + "…" }; "`n　$h" } else { "" }
            "**$($ev.title)**$tag`n　⏰ $where$($e.text)$hl"
        }
        # 每欄最多 1024 字，太長就拆成好幾欄
        $chunk = ""; $part = 0
        foreach ($ln in $lines) {
            if (($chunk.Length + $ln.Length + 2) -gt 1000) {
                $fields += @{ name = $(if ($part -eq 0) { $regions[$r] } else { "$($regions[$r])（續）" }); value = $chunk.TrimEnd(); inline = $false }
                $chunk = ""; $part++
            }
            $chunk += "$ln`n`n"
        }
        if ($chunk) { $fields += @{ name = $(if ($part -eq 0) { $regions[$r] } else { "$($regions[$r])（續）" }); value = $chunk.TrimEnd(); inline = $false } }
    }

    $info = $cats[$c]
    $dayText = "{0:M/d}（{1}）" -f $today, $week[[int]$today.DayOfWeek]
    $desc = "$dayText 進行中 **$($list.Count) 個**活動"
    if ($soon -gt 0) { $desc += "，其中 **$soon 個今明兩天結束**" }
    $desc += "`n時間都是台灣時間。"
    if ($warn) { $desc += "`n`n$warn" }
    $desc += "`n`n☁️ 雲端通知"
    $prefix = if ($Test) { "🧪【測試】" } else { "" }
    $title = "$prefix$($info.icon) 今日$($info.name)活動｜$dayText"
    $fields = @($fields | Select-Object -First 25)

    if ($DryRun) {
        Write-Host "===== [$c] $title"; Write-Host $desc
        $fields | ForEach-Object { Write-Host "--- $($_.name)"; Write-Host $_.value }
    } else {
        Send-Discord -Channel $c -Color $info.color -Title $title -Description $desc -Fields $fields
        Write-Host "已發送：$title"
    }
    $sent++
}
if ($sent -eq 0) { Write-Host "今天沒有進行中的遊戲活動，不發通知" }
