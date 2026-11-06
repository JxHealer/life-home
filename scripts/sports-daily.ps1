# 球賽日報：每天早上把「今天的比賽」和「昨天的比分」發到 Discord #球賽
# 賽程在 data/schedules/*.json（build-schedules.ps1 從官網抓）。所有球隊的所有比賽都列出來。
# 由 GitHub Actions 執行（.github/workflows/sports.yml），不消耗 Claude 用量。
# 用法：./scripts/sports-daily.ps1 [-Test] [-DryRun]
#   -Test：標題加上【測試】，今天沒比賽時改列「下一個有比賽的日子」
#   -DryRun：只印出內容，不發 Discord

param([switch]$Test, [switch]$DryRun)

$ErrorActionPreference = "Stop"
if (-not $DryRun) { . "$PSScriptRoot/discord.ps1" }

$Dir = Join-Path $PSScriptRoot "../data/schedules"
$tw = [TimeSpan]::FromHours(8)
$now = [DateTimeOffset]::UtcNow.ToOffset($tw)
$today = $now.Date
$week = "日一二三四五六"
$icon = @{ basketball = "🏀"; volleyball = "🏐"; baseball = "⚾" }

$fields = @()
$warn = @()
$todayCount = 0
$targetDay = $today

$leagues = @()
foreach ($f in Get-ChildItem $Dir -Filter *.json | Sort-Object Name) {
    $leagues += Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
}

# 測試時今天若沒有比賽，改用下一個有比賽的日子
if ($Test) {
    $next = $leagues | ForEach-Object { $_.games } | ForEach-Object { [DateTimeOffset]::Parse($_.start).ToOffset($tw).Date } |
        Where-Object { $_ -ge $today } | Sort-Object | Select-Object -First 1
    if ($next) { $targetDay = $next }
}

foreach ($lg in $leagues) {
    $ic = $icon[$lg.sport]
    # 賽程超過 3 天沒更新，代表官網一直抓不到
    try {
        $upd = [DateTime]::ParseExact($lg.updatedAt, "yyyy-MM-dd HH:mm", $null)
        if (($now.DateTime - $upd).TotalDays -gt 3) { $warn += "$($lg.name) 賽程已經 $([int]($now.DateTime - $upd).TotalDays) 天沒更新（官網可能抓不到）" }
    } catch {}

    $todayLines = @(); $ydLines = @()
    foreach ($g in $lg.games) {
        $st = [DateTimeOffset]::Parse($g.start).ToOffset($tw)
        if ($st.Date -eq $targetDay) {
            $extra = switch ($g.status) { "postponed" { "（延賽）" } "cancelled" { "（取消）" } default { "" } }
            $todayLines += "``{0:HH:mm}`` {1} vs {2}（主）{3}`n　📍{4}" -f $st, $g.away, $g.home, $extra, $g.venue
        } elseif ($st.Date -eq $today.AddDays(-1) -and $g.status -eq "final" -and $null -ne $g.hs) {
            $win = if ([int]$g.as -gt [int]$g.hs) { $g.away } else { $g.home }
            $ydLines += "{0} **{1}：{2}** {3}（主）→ {4} 勝" -f $g.away, $g.as, $g.hs, $g.home, $win
        }
    }
    if ($todayLines.Count -gt 0) {
        $todayCount += $todayLines.Count
        $fields += @{ name = "$ic $($lg.name)｜$($todayLines.Count) 場"; value = ($todayLines -join "`n"); inline = $false }
    }
    if ($ydLines.Count -gt 0) {
        $fields += @{ name = "$ic $($lg.name)｜昨天比分"; value = ($ydLines -join "`n"); inline = $false }
    }
}

if ($fields.Count -eq 0 -and $warn.Count -eq 0) { Write-Host "今天和昨天都沒有比賽，不發通知"; exit 0 }

$dayText = "{0:M/d}（{1}）" -f $targetDay, $week[[int]$targetDay.DayOfWeek]
$desc = if ($todayCount -gt 0) { "$dayText 共 **$todayCount 場** 比賽" } else { "$dayText 沒有比賽" }
if ($warn.Count -gt 0) { $desc += "`n`n⚠️ " + ($warn -join "`n⚠️ ") }
$desc += "`n`n☁️ 雲端通知"
$prefix = if ($Test) { "🧪【測試】" } else { "" }
$title = "$($prefix)🏟️ 今日賽程｜$dayText"

# Discord 一則訊息最多 25 個欄位、每欄 1024 字
$fields = @($fields | ForEach-Object { if ($_.value.Length -gt 1024) { $_.value = $_.value.Substring(0, 1020) + "…" }; $_ } | Select-Object -First 25)

if ($DryRun) {
    Write-Host $title; Write-Host $desc
    $fields | ForEach-Object { Write-Host "--- $($_.name)"; Write-Host $_.value }
} else {
    Send-Discord -Channel sports -Color 0xF5A524 -Title $title -Description $desc -Fields $fields
    Write-Host "已發送：$title"
}
