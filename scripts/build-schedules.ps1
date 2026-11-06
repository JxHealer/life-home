# 從各聯盟官網抓 2026-27 賽程（TPBL、PLG、TPVL），整理成 data/schedules/*.json
# 由 GitHub Actions 每天早上執行（.github/workflows/sports.yml），不消耗 Claude 用量。
# 某個聯盟抓不到時只跳過那一個，保留上一次的檔案。
# 用法：./scripts/build-schedules.ps1

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$OutDir = Join-Path $PSScriptRoot "../data/schedules"
New-Item -ItemType Directory -Force $OutDir | Out-Null
$UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"
$Now = [DateTimeOffset]::UtcNow.ToOffset([TimeSpan]::FromHours(8)).ToString("yyyy-MM-dd HH:mm")
$Failed = @()
function Get-Text($url) {
    $r = Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 60 -UserAgent $UA -Headers @{ "Accept-Language" = "zh-TW,zh;q=0.9" }
    return [System.Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
}

function Save-Schedule($id, $doc) {
    $json = $doc | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText((Join-Path $OutDir "$id.json"), $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ("[完成] {0}：{1} 場" -f $doc.name, $doc.games.Count) -ForegroundColor Green
}

# ---------- TPBL ----------
try {
    $seasons = Get-Text "https://api.tpbl.basketball/api/seasons" | ConvertFrom-Json
    $season = $seasons | Where-Object { $_.name -like "2026-2027*" } | Select-Object -First 1
    $tpbl = Get-Text "https://api.tpbl.basketball/api/seasons/$($season.id)/games" | ConvertFrom-Json
    # 開季前的熱身賽在另一個 division，只取 10/17 開幕後的正式賽事
    $regular = $tpbl | Where-Object { $_.gamed_at -ge "2026-10-17" }
    $statusMap = @{ COMPLETED = "final"; NOT_STARTED = "scheduled"; POSTPONED = "postponed"; CANCELED = "cancelled"; CANCELLED = "cancelled" }
    Save-Schedule "tpbl-2026-27" ([ordered]@{
        league = "tpbl"; sport = "basketball"; name = "TPBL 2026-27"; sourceUrl = "https://tpbl.basketball/schedule"; updatedAt = $Now
        games = @($regular | Sort-Object gamed_at | ForEach-Object {
            $st = if ($statusMap.ContainsKey($_.status)) { $statusMap[$_.status] } else { "scheduled" }
            $g = [ordered]@{
                id = "tpbl-$($_.id)"; code = "G$($_.code)"; stage = "例行賽"
                start = ($_.gamed_at -replace " ", "T") + "+08:00"
                home = $_.home_team.name; away = $_.away_team.name; venue = $_.venue; status = $st
            }
            if ($st -eq "final") { $g.hs = $_.home_team.won_score; $g.as = $_.away_team.won_score }
            if ($_.meta.ticket_url) { $g.ticket = $_.meta.ticket_url }
            $g
        })
    })

} catch { $Failed += "TPBL"; Write-Warning "TPBL 抓取失敗：$_" }

# ---------- PLG ----------
try {
    $html = Get-Text "https://pleagueofficial.com/schedule-regular-season/2026-27"
    $plgNames = @{ "勇士" = "臺北富邦勇士"; "領航猿" = "桃園璞園領航猿"; "獵鷹" = "台鋼獵鷹"; "洋基工程" = "洋基工程" }
    $rows = [regex]::Split($html, '<div[^>]*class="row justify-content-center[^"]*match_row[ "]') | Select-Object -Skip 1
    $plgGames = foreach ($blk in $rows) {
        $cls = [regex]::Match($blk, '^[^"]*').Value
        $t = ($blk -replace '<script.*?</script>', '' -replace '<[^>]+>', '|' -replace '\s+', ' ' -replace '(\| ?)+', '|').Trim('|', ' ') -split '\|' |
            ForEach-Object { $_.Trim() } | Where-Object { $_ }
        $md = $t | Where-Object { $_ -match '^\d{1,2}/\d{1,2}$' } | Select-Object -First 1
        $hm = $t | Where-Object { $_ -match '^\d{1,2}:\d{2}$' } | Select-Object -First 1
        $code = $t | Where-Object { $_ -match '^G\d+$' } | Select-Object -First 1
        $year = [regex]::Match($cls, 'd-(\d{4})-').Groups[1].Value
        if (-not ($md -and $hm -and $code -and $year)) { throw "PLG 賽程格式和預期不同，無法解析：$code $md $hm" }
        $m, $d = $md -split '/'
        $awayName = $t[[array]::IndexOf($t, '客隊') + 1]; $homeName = $t[[array]::IndexOf($t, '主隊') + 1]
        $codeAt = [array]::IndexOf($t, $code); $homeAt = [array]::IndexOf($t, '主隊')
        $isFinal = $cls -notmatch 'is-future'
        $g = [ordered]@{
            id = "plg-" + [regex]::Match($blk, '/game/(\d+)').Groups[1].Value; code = $code; stage = "例行賽"
            start = "{0}-{1:D2}-{2:D2}T{3}:00+08:00" -f $year, [int]$m, [int]$d, $hm
            home = $(if ($plgNames[$homeName]) { $plgNames[$homeName] } else { $homeName })
            away = $(if ($plgNames[$awayName]) { $plgNames[$awayName] } else { $awayName })
            venue = $t[$codeAt + 1]
            status = $(if ($isFinal) { "final" } else { "scheduled" })
        }
        # 已結束的比賽：客隊比分在場次編號前一格，主隊比分在「主隊」前一格
        if ($isFinal -and $t[$codeAt - 1] -match '^\d+$' -and $t[$homeAt - 1] -match '^\d+$') {
            $g.as = [int]$t[$codeAt - 1]; $g.hs = [int]$t[$homeAt - 1]
        }
        $g
    }
    Save-Schedule "plg-2026-27" ([ordered]@{
        league = "plg"; sport = "basketball"; name = "P. LEAGUE+ 2026-27"; sourceUrl = "https://pleagueofficial.com/schedule-regular-season/2026-27"; updatedAt = $Now
        games = @($plgGames | Sort-Object { $_.start })
    })

} catch { $Failed += "PLG"; Write-Warning "PLG 抓取失敗：$_" }

# ---------- TPVL ----------
try {
    $api = "https://tpvl.tw/v1/public/content"
    $teams = @{}; (Get-Text "$api/teams/entries?limit=100" | ConvertFrom-Json).items | ForEach-Object { $teams[$_.slug] = $_.title }
    $venues = @{}; (Get-Text "$api/venues/entries?limit=100" | ConvertFrom-Json).items | ForEach-Object { $venues[$_.slug] = $_.title }
    $matches = (Get-Text "$api/matches/entries?limit=200" | ConvertFrom-Json).items | Where-Object { $_.slug -like "2026-27-*" }
    Save-Schedule "tpvl-2026-27" ([ordered]@{
        league = "tpvl"; sport = "volleyball"; name = "TPVL 2026-27"; sourceUrl = "https://tpvl.tw/schedule"; updatedAt = $Now
        games = @($matches | Sort-Object { $_.fields.start_time } | ForEach-Object {
            $f = $_.fields
            $g = [ordered]@{
                id = "tpvl-$($_.slug)"; code = "G$($f.match_no)"; stage = "例行賽"
                start = "$($f.start_time):00+08:00"
                home = $teams[$f.home_team]; away = $teams[$f.away_team]; venue = $venues[$f.venue]; status = $f.status
            }
            if ($f.status -eq "final") { $g.hs = $f.home_sets; $g.as = $f.away_sets }
            if ($f.ticket_url) { $g.ticket = $f.ticket_url }
            $g
        })
    })
} catch { $Failed += "TPVL"; Write-Warning "TPVL 抓取失敗：$_" }

if ($Failed.Count -gt 0) { Write-Warning ("抓不到：" + ($Failed -join "、") + "（沿用上一次的賽程）") }
if ($Failed.Count -eq 3) { exit 1 }
