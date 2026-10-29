# 首頁資料：天氣（中央氣象署，失敗改用 Open-Meteo）、股票走勢（證交所）、美金匯率（Yahoo 財經）
# 由 GitHub Actions 定時執行（.github/workflows/update.yml），輸出 data/home.json，
# 行事曆首頁再透過 jsDelivr 讀取。不經過 Claude，不消耗 Claude 用量。
# 氣象署授權碼放在 GitHub 的 Secret「CWA_API_KEY」，執行時以環境變數傳入。

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Root = Join-Path $PSScriptRoot ".."
$cfg = Get-Content (Join-Path $Root "config.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$OutPath = Join-Path $Root "data/home.json"
$UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"
$warnings = @()
$TW = [TimeSpan]::FromHours(8)
$nowTw = [DateTimeOffset]::UtcNow.ToOffset($TW)

# 上一次的結果：某個來源這次抓不到時，沿用上次的資料
$prev = $null
if (Test-Path $OutPath) { try { $prev = Get-Content $OutPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }

function Num($s) { [double](($s -replace ',', '').Trim()) }

# ---------- 天氣 ----------
$cwaKey = $env:CWA_API_KEY
if ($cwaKey -notmatch '^CWA-[\w-]+$') { $cwaKey = $null; $warnings += "沒有氣象署授權碼，天氣改用 Open-Meteo" }

# 氣象署天氣現象代碼 → 圖示
function Get-CwaIcon($code) {
    $c = [int]$code
    if ($c -eq 1) { return "☀️" }
    if ($c -in 2, 3) { return "🌤️" }
    if ($c -ge 4 -and $c -le 7) { return "☁️" }
    if ($c -in 15, 16, 17, 18, 33, 34, 35, 36, 41) { return "⛈️" }
    if ($c -ge 24 -and $c -le 28) { return "🌫️" }
    if ($c -eq 42) { return "❄️" }
    if ($c -ge 8) { return "🌧️" }
    return "·"
}

$cwaCache = @{}
function Get-CwaTown($dataset, $town) {
    if (-not $cwaCache.ContainsKey($dataset)) {
        $u = "https://opendata.cwa.gov.tw/api/v1/rest/datastore/${dataset}?Authorization=$cwaKey&format=JSON"
        $r = Invoke-WebRequest $u -UseBasicParsing -TimeoutSec 60
        $cwaCache[$dataset] = [System.Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json
    }
    $loc = $cwaCache[$dataset].records.Locations[0].Location | Where-Object { $_.LocationName -eq $town } | Select-Object -First 1
    if (-not $loc) { throw "氣象署資料裡找不到 $town" }
    return $loc
}
function Get-Element($loc, $name) { $loc.WeatherElement | Where-Object { $_.ElementName -eq $name } | Select-Object -First 1 }

function Get-CwaWeather($w) {
    $week = Get-CwaTown $w.cwaWeek $w.town
    $maxT = Get-Element $week "最高溫度"; $minT = Get-Element $week "最低溫度"
    $pop = Get-Element $week "12小時降雨機率"; $wxE = Get-Element $week "天氣現象"
    $byDay = [ordered]@{}
    for ($i = 0; $i -lt $wxE.Time.Count; $i++) {
        $start = [DateTimeOffset]::Parse($wxE.Time[$i].StartTime).ToOffset($TW)
        $d = $start.ToString("yyyy-MM-dd")
        if (-not $byDay.Contains($d)) { $byDay[$d] = [ordered]@{ d = $d; max = -99; min = 99; rain = 0; text = ""; code = ""; icon = "" } }
        $day = $byDay[$d]
        $day.max = [math]::Max($day.max, [double]$maxT.Time[$i].ElementValue[0].MaxTemperature)
        $day.min = [math]::Min($day.min, [double]$minT.Time[$i].ElementValue[0].MinTemperature)
        $p = $pop.Time[$i].ElementValue[0].ProbabilityOfPrecipitation
        if ($p -match '^\d+$') { $day.rain = [math]::Max($day.rain, [int]$p) }
        # 白天時段（06:00 或 12:00 開始）的天氣代表這一天；沒有就用第一個時段
        if (-not $day.text -or $start.Hour -in 6, 12) {
            $day.text = $wxE.Time[$i].ElementValue[0].Weather
            $day.code = $wxE.Time[$i].ElementValue[0].WeatherCode
            $day.icon = Get-CwaIcon $day.code
        }
    }
    # 現在溫度：2 天逐 3 小時預報裡，涵蓋現在的那一筆
    $nowTemp = $null; $nowText = $byDay[0].text; $nowIcon = $byDay[0].icon
    try {
        $two = Get-CwaTown $w.cwa2Day $w.town
        $t = Get-Element $two "溫度"
        $slot = $t.Time | Where-Object { [DateTimeOffset]::Parse($_.DataTime) -le $nowTw } | Select-Object -Last 1
        if (-not $slot) { $slot = $t.Time[0] }
        $nowTemp = [double]$slot.ElementValue[0].Temperature
        $wx2 = Get-Element $two "天氣現象"
        $ws = $wx2.Time | Where-Object { [DateTimeOffset]::Parse($_.StartTime) -le $nowTw } | Select-Object -Last 1
        if ($ws) { $nowText = $ws.ElementValue[0].Weather; $nowIcon = Get-CwaIcon $ws.ElementValue[0].WeatherCode }
    } catch { $nowTemp = ([double]$byDay[0].max + [double]$byDay[0].min) / 2 }
    $days = @($byDay.Values | Select-Object -First 7)
    [ordered]@{ id = $w.id; place = $w.place; source = "中央氣象署"; now = [ordered]@{ temp = $nowTemp; text = $nowText; icon = $nowIcon }; days = $days }
}

$weather = foreach ($w in $cfg.weather) {
    if ($cwaKey) {
        try { Get-CwaWeather $w; continue } catch { $warnings += "氣象署 $($w.place)：$($_.Exception.Message)，改用 Open-Meteo" }
    }
    try {
        $u = "https://api.open-meteo.com/v1/forecast?latitude=$($w.lat)&longitude=$($w.lng)&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max&current=temperature_2m,weather_code&timezone=Asia%2FTaipei&forecast_days=7"
        $j = Invoke-RestMethod $u -TimeoutSec 30
        $days = for ($i = 0; $i -lt $j.daily.time.Count; $i++) {
            [ordered]@{ d = $j.daily.time[$i]; code = $j.daily.weather_code[$i]; max = $j.daily.temperature_2m_max[$i]; min = $j.daily.temperature_2m_min[$i]; rain = $j.daily.precipitation_probability_max[$i] }
        }
        [ordered]@{ id = $w.id; place = $w.place; source = "Open-Meteo"; now = [ordered]@{ temp = $j.current.temperature_2m; code = $j.current.weather_code }; days = @($days) }
    } catch {
        $warnings += "天氣 $($w.place)：$($_.Exception.Message)"
        $old = $prev.weather | Where-Object { $_.id -eq $w.id } | Select-Object -First 1
        if ($old) { $old }
    }
}

# ---------- 股票：近幾個月每日收盤 ----------
$months = @(); $m = $nowTw.AddMonths( - ($cfg.historyMonths - 1))
for ($i = 0; $i -lt $cfg.historyMonths; $i++) { $months += $m.AddMonths($i).ToString("yyyyMM01") }

# 盤中即時價（開盤後才有當天的成交）
$live = @{}
try {
    $ex = ($cfg.stocks | ForEach-Object { "tse_$($_.code).tw" }) -join "|"
    (Invoke-RestMethod "https://mis.twse.com.tw/stock/api/getStockInfo.jsp?ex_ch=$ex&json=1&delay=0" -UserAgent $UA -TimeoutSec 30).msgArray | ForEach-Object { $live[$_.c] = $_ }
} catch { $warnings += "盤中報價：$($_.Exception.Message)" }

$stocks = foreach ($s in $cfg.stocks) {
    $series = @()
    foreach ($mo in $months) {
        try {
            $j = Invoke-RestMethod "https://www.twse.com.tw/exchangeReport/STOCK_DAY?response=json&date=$mo&stockNo=$($s.code)" -UserAgent $UA -TimeoutSec 30
            if ($j.stat -eq "OK") {
                foreach ($row in $j.data) {
                    if ($row[6] -notmatch '[\d.]') { continue }
                    $p = $row[0] -split '/'   # 民國年/月/日
                    $series += [ordered]@{ d = "{0}-{1}-{2}" -f ([int]$p[0] + 1911), $p[1], $p[2]; c = Num $row[6] }
                }
            }
        } catch { $warnings += "$($s.code) $mo：$($_.Exception.Message)" }
        Start-Sleep -Milliseconds 700   # 證交所有頻率限制
    }
    $old = $prev.stocks | Where-Object { $_.code -eq $s.code } | Select-Object -First 1
    if ($series.Count -eq 0 -and $old) { $series = @($old.series) }
    $q = $live[$s.code]
    $latest = $null
    # z 是最近成交價，但盤中常常是 "-"（那一刻沒成交），就改用最佳買價，再不行用開盤價
    $px = $null
    if ($q) {
        if ($q.z -match '^[\d.]+$') { $px = [double]$q.z }
        elseif (($q.b -split '_')[0] -match '^[\d.]+$' -and [double](($q.b -split '_')[0]) -gt 0) { $px = [double](($q.b -split '_')[0]) }
        elseif ($q.o -match '^[\d.]+$') { $px = [double]$q.o }
    }
    if ($px -and $q.y -match '^[\d.]+$') {
        $latest = [ordered]@{ price = $px; prevClose = [double]$q.y; date = "{0}-{1}-{2}" -f $q.d.Substring(0, 4), $q.d.Substring(4, 2), $q.d.Substring(6, 2); time = $q.t }
    } elseif ($series.Count -ge 2) {
        $latest = [ordered]@{ price = $series[-1].c; prevClose = $series[-2].c; date = $series[-1].d; time = "13:30:00" }
    }
    [ordered]@{ code = $s.code; name = $s.name; latest = $latest; series = @($series) }
}

# ---------- 美金匯率 ----------
$fx = $null
try {
    $j = Invoke-RestMethod "https://query1.finance.yahoo.com/v8/finance/chart/TWD=X?range=3mo&interval=1d" -UserAgent $UA -TimeoutSec 30
    $r = $j.chart.result[0]
    $series = for ($i = 0; $i -lt $r.timestamp.Count; $i++) {
        $c = $r.indicators.quote[0].close[$i]
        if ($null -ne $c) { [ordered]@{ d = [DateTimeOffset]::FromUnixTimeSeconds($r.timestamp[$i]).ToOffset($TW).ToString("yyyy-MM-dd"); c = [math]::Round([double]$c, 4) } }
    }
    $fx = [ordered]@{
        pair = "USD/TWD"; price = [math]::Round([double]$r.meta.regularMarketPrice, 4); prevClose = [math]::Round([double]$r.meta.chartPreviousClose, 4)
        time = [DateTimeOffset]::FromUnixTimeSeconds($r.meta.regularMarketTime).ToOffset($TW).ToString("yyyy-MM-dd HH:mm")
        series = @($series)
    }
} catch {
    $warnings += "匯率：$($_.Exception.Message)"
    if ($prev.fx) { $fx = $prev.fx }
}

$out = [ordered]@{
    updatedAt = $nowTw.ToString("yyyy-MM-ddTHH:mm:sszzz")
    weather = @($weather); stocks = @($stocks); fx = $fx; warnings = @($warnings)
}
New-Item -ItemType Directory -Force (Split-Path $OutPath) | Out-Null
[System.IO.File]::WriteAllText($OutPath, ($out | ConvertTo-Json -Depth 8 -Compress), (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("[完成] data/home.json：天氣 {0} 地、股票 {1} 檔、匯率 {2} 筆、警告 {3} 則" -f @($weather).Count, @($stocks).Count, @($fx.series).Count, $warnings.Count)
$warnings | ForEach-Object { Write-Host "[警告] $_" }
