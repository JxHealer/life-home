# 開盤前參考：平日早上台股開盤前，發一則 Discord #金融日報
# 整理前一晚美股、VIX、台指期夜盤、日經期貨，並附上「過去 2 年類似情況」的統計。
# 只是整理數據與過去統計，不是預測，也不是買賣建議。
# 由 GitHub Actions 執行（.github/workflows/premarket.yml），不消耗 Claude 用量。
# 用法：./scripts/premarket-report.ps1 [-Test] [-DryRun]
#   -Test：休市、已發過、太晚也照樣發送，標題加【測試】
#   -DryRun：只在畫面印出內容，不送 Discord（在自己電腦上檢查用）

param([switch]$Test, [switch]$DryRun)

$ErrorActionPreference = "Stop"
if (-not $DryRun) { . "$PSScriptRoot/discord.ps1" }

$UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"
$Week = "日", "一", "二", "三", "四", "五", "六"
$nowTw = [DateTimeOffset]::UtcNow.ToOffset([TimeSpan]::FromHours(8))
$todayKey = $nowTw.ToString("yyyy-MM-dd")
$SentPath = Join-Path $PSScriptRoot "../data/premarket-sent.json"

# ---------- 要不要發 ----------
if (-not $Test) {
    if ($nowTw.DayOfWeek -in "Saturday", "Sunday") { Write-Host "週末，不發送"; exit 0 }
    if ($nowTw.Hour -ge 9) { Write-Host "已經 9 點後（開盤報告會接手），不發送"; exit 0 }
    if (Test-Path $SentPath) {
        $sent = Get-Content $SentPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($sent.date -eq $todayKey) { Write-Host "今天已經發過，不重複發送"; exit 0 }
    }
    # 證交所休市日（取不到就照樣發）
    try {
        $raw = Invoke-WebRequest "https://openapi.twse.com.tw/v1/holidaySchedule/holidaySchedule" -UserAgent $UA -TimeoutSec 30 -UseBasicParsing
        $hol = [Text.Encoding]::UTF8.GetString($raw.RawContentStream.ToArray()) | ConvertFrom-Json
        $roc = "{0}{1:MMdd}" -f ($nowTw.Year - 1911), $nowTw
        $hit = $hol | Where-Object { $_.Date -eq $roc -and $_.Name -notmatch "交易日" }
        if ($hit) { Write-Host "今天休市（$($hit.Name)），不發送"; exit 0 }
    } catch { Write-Host "查不到休市日，照樣發送：$_" }
}

# ---------- 工具 ----------
function Get-Series($symbol, [int]$offsetHours, $range = "2y") {
    $enc = [uri]::EscapeDataString($symbol)
    $j = Invoke-RestMethod "https://query1.finance.yahoo.com/v8/finance/chart/$($enc)?range=$range&interval=1d" -UserAgent $UA -TimeoutSec 30
    $r = $j.chart.result[0]; $q = $r.indicators.quote[0]
    $list = New-Object System.Collections.ArrayList
    $n = $r.timestamp.Count
    for ($i = 0; $i -lt $n; $i++) {
        $close = $q.close[$i]
        # Yahoo 最新一天常常只有即時價、收盤欄位是空的 → 改用 meta 的最新價
        if (-not $close -and $i -eq $n - 1 -and $r.meta.regularMarketPrice) { $close = $r.meta.regularMarketPrice }
        if ($close -and $q.open[$i]) {
            [void]$list.Add([pscustomobject]@{
                d = [DateTimeOffset]::FromUnixTimeSeconds($r.timestamp[$i]).ToOffset([TimeSpan]::FromHours($offsetHours)).Date
                o = [double]$q.open[$i]; c = [double]$close
            })
        }
    }
    return , $list
}
# 台股慣例：漲紅、跌綠
function Format-Pct([double]$pct) {
    $p = ($pct * 100).ToString("+0.00;-0.00;0.00")
    if ($pct -gt 0) { return "🔴 ▲ $p%" }
    if ($pct -lt 0) { return "🟢 ▼ $p%" }
    return "⚪ 0.00%"
}
function Pct([double]$x) { ($x * 100).ToString("+0.00;-0.00;0.00") + "%" }

# ---------- 台股過去 2 年（用來判斷「前一個交易日」和做統計） ----------
$tw = Get-Series "^TWII" 8
$twToday = $nowTw.Date
$twPast = @($tw | Where-Object { $_.d -lt $twToday })
$prevTwDay = $twPast[-1].d

# ---------- 前一晚美股 ----------
$usList = @(
    @{ key = "SOX"; sym = "^SOX"; name = "費城半導體指數"; digits = 0 },
    @{ key = "TSM"; sym = "TSM"; name = "台積電 ADR"; digits = 2 },
    @{ key = "IXIC"; sym = "^IXIC"; name = "那斯達克"; digits = 0 },
    @{ key = "GSPC"; sym = "^GSPC"; name = "S&P 500"; digits = 0 },
    @{ key = "NVDA"; sym = "NVDA"; name = "輝達 NVDA"; digits = 2 }
)
$us = @{}; $fields = @(); $up = 0; $down = 0; $usUp = 0; $usDown = 0; $usStale = $false; $usDate = $null
$nightChg = $null; $nightField = $null; $nikkeiField = $null
foreach ($x in $usList) {
    try {
        $range = if ($x.key -eq "SOX") { "2y" } else { "1mo" }
        $s = Get-Series $x.sym -5 $range
        $last = $s[-1]; $prev = $s[-2]
        $chg = $last.c / $prev.c - 1
        $us[$x.key] = @{ chg = $chg; series = $s }
        $usDate = $last.d
        if ($last.d -lt $prevTwDay) { $usStale = $true }
        if ($chg -gt 0) { $up++; $usUp++ } elseif ($chg -lt 0) { $down++; $usDown++ }
        $fields += @{ name = $x.name; value = "**$($last.c.ToString('N' + $x.digits))**`n$(Format-Pct $chg)"; inline = $true }
    } catch { $fields += @{ name = $x.name; value = "取不到資料"; inline = $true } }
}

# ---------- VIX 恐慌指數（和台股方向相反） ----------
try {
    $v = Get-Series "^VIX" -5 "1mo"
    $vix = $v[-1].c; $vChg = $vix / $v[-2].c - 1
    $level = if ($vix -ge 30) { "😱 恐慌（30 以上）" } elseif ($vix -ge 20) { "😟 偏緊張（20～30）" } else { "😌 平靜（20 以下）" }
    if ($vChg -gt 0.03) { $down++; $usDown++ } elseif ($vChg -lt -0.03) { $up++; $usUp++ }
    $fields += @{ name = "VIX 恐慌指數"; value = "**$($vix.ToString('0.00'))**（$(Pct $vChg)）`n$level`n⬆ 越高代表越恐慌"; inline = $true }
} catch { $fields += @{ name = "VIX 恐慌指數"; value = "取不到資料"; inline = $true } }

# ---------- 台指期夜盤（期交所） ----------
$nightText = "取不到資料"
try {
    $body = '{"MarketType":"1","SymbolType":"F","KindID":"1","CID":"TXF","ExpireMonth":"","RowSize":"全部","PageNo":"","SortColumn":"","AscDesc":"A"}'
    $r = Invoke-RestMethod "https://mis.taifex.com.tw/futures/api/getQuoteList" -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType "application/json; charset=utf-8" -UserAgent $UA -TimeoutSec 30
    $near = $r.RtData.QuoteList | Where-Object { $_.SymbolID -match '^TXF\w+-M$' -and $_.CLastPrice } | Select-Object -First 1
    if ($near) {
        $last = [double]$near.CLastPrice; $ref = [double]$near.CRefPrice
        $chg = $last / $ref - 1
        $nightChg = $chg
        if ($chg -gt 0) { $up++ } elseif ($chg -lt 0) { $down++ }
        $nightText = "**$($last.ToString('N0'))**（$(([double]$near.CDiff).ToString('+0;-0;0')) 點）`n$(Format-Pct $chg)`n和白天收盤比，交易到清晨 05:00"
    }
} catch {}
$nightField = @{ name = "⭐ 🌙 台指期夜盤（最重要）"; value = $nightText; inline = $true }

# ---------- 日經期貨（美國晚上也在交易） ----------
try {
    $j = Invoke-RestMethod "https://query1.finance.yahoo.com/v8/finance/chart/NIY%3DF?range=1d&interval=1d" -UserAgent $UA -TimeoutSec 30
    $m = $j.chart.result[0].meta
    $chg = [double]$m.regularMarketPrice / [double]$m.chartPreviousClose - 1
    if ($chg -gt 0) { $up++ } elseif ($chg -lt 0) { $down++ }
    $nikkeiField = @{ name = "🇯🇵 日經期貨"; value = "**$(([double]$m.regularMarketPrice).ToString('N0'))**`n$(Format-Pct $chg)`n美股收盤後仍在交易"; inline = $true }
} catch { $nikkeiField = @{ name = "🇯🇵 日經期貨"; value = "取不到資料"; inline = $true } }
# 夜盤、日經期貨反映「美股收盤後」的新消息，排在最前面
$fields = @($nightField, $nikkeiField) + $fields

# ---------- 過去 2 年類似情況（以費城半導體分組） ----------
$histText = "取不到資料"
if ($us.SOX) {
    $sox = $us.SOX.series; $rows = @()
    for ($t = 1; $t -lt $twPast.Count; $t++) {
        $p = $twPast[$t - 1].d; $c = $twPast[$t].d; $idx = -1
        for ($k = $sox.Count - 1; $k -ge 1; $k--) { if ($sox[$k].d -ge $p -and $sox[$k].d -lt $c) { $idx = $k; break } }
        if ($idx -lt 1) { continue }
        $rows += [pscustomobject]@{
            us = $sox[$idx].c / $sox[$idx - 1].c - 1
            gap = $twPast[$t].o / $twPast[$t - 1].c - 1
            day = $twPast[$t].c / $twPast[$t - 1].c - 1
        }
    }
    $sc = $us.SOX.chg
    $bucket = if ($sc -ge 0.02) { @("大漲超過 2%", { $_.us -ge 0.02 }) } elseif ($sc -gt 0) { @("小漲 0～2%", { $_.us -gt 0 -and $_.us -lt 0.02 }) } elseif ($sc -gt -0.02) { @("小跌 0～2%", { $_.us -le 0 -and $_.us -gt -0.02 }) } else { @("大跌超過 2%", { $_.us -le -0.02 }) }
    $sub = @($rows | Where-Object $bucket[1])
    if ($sub.Count -gt 0) {
        $ag = ($sub.gap | Measure-Object -Average).Average
        $ad = ($sub.day | Measure-Object -Average).Average
        $redPct = @($sub | Where-Object { $_.day -gt 0 }).Count / $sub.Count
        $histText = "費城半導體 **$($bucket[0])** 的隔天，過去 2 年有 $($sub.Count) 天：`n" +
            "・台股開盤平均 **$(Pct $ag)**`n" +
            "・整天平均 **$(Pct $ad)**`n" +
            "・收紅的比例 **$([math]::Round($redPct * 100))%**"
    }
}
$fields += @{ name = "📊 過去類似情況（統計，不是預測）"; value = $histText; inline = $false }

# ---------- 綜合 ----------
$total = $up + $down
$dir = if ($up -gt $down) { "偏多（往上）" } elseif ($down -gt $up) { "偏空（往下）" } else { "方向不一致" }
$color = if ($up -gt $down) { 0xD9363E } elseif ($down -gt $up) { 0x2F9E57 } else { 0x808080 }
$strength = if ($total -gt 0 -and [math]::Max($up, $down) / $total -ge 0.8) { "大多數指標同方向，訊號比較一致" } elseif ($up -eq $down) { "指標互相矛盾，開盤方向較難判斷" } else { "指標有分歧，訊號較弱" }
$summary = "🧭 **$($total) 個指標中：$up 個偏漲、$down 個偏跌 → $dir**`n$strength"
if ($null -ne $nightChg) {
    $nightDir = if ($nightChg -gt 0) { "偏漲" } elseif ($nightChg -lt 0) { "偏跌" } else { "持平" }
    $usDir = if ($usUp -gt $usDown) { "偏漲" } elseif ($usDown -gt $usUp) { "偏跌" } else { "持平" }
    $nightLine = "⭐ **夜盤 $(Pct $nightChg)（$nightDir）**：交易到清晨 05:00，是最接近開盤的參考"
    if ($nightDir -ne "持平" -and $usDir -ne "持平" -and $nightDir -ne $usDir) {
        $nightLine += "`n⚠️ **美股$($usDir)、夜盤卻$($nightDir)**：美股收盤後可能有新消息，開盤通常比較接近夜盤的方向"
        $color = 0x808080
    } elseif ($nightDir -eq $usDir) {
        $nightLine += "`n✅ 美股和夜盤方向一致，訊號比較可靠"
    }
    $summary = "$nightLine`n`n$summary"
}
$staleNote = if ($usStale) { "`n⚠️ 昨晚美股休市，美股是較舊的資料（$($usDate.ToString('M/d'))），參考價值較低" } else { "" }

$dateText = "{0:M/d}（{1}）" -f $nowTw, $Week[[int]$nowTw.DayOfWeek]
$prefix = if ($Test) { "🧪【測試】" } else { "" }
$desc = "早安！台股 08:45 開盤前的參考數值。$staleNote`n`n$summary`n`n" +
    "💡 小提醒：美股**大跌**時，台股開盤後常常還會繼續弱；**小跌**影響不大。日經、韓股 08:00 開盤，可以再看一眼。`n" +
    "（只是整理數據和過去統計，不是預測，也不是買賣建議）`n資料來源：Yahoo 財經、臺灣期貨交易所"

if ($DryRun) {
    Write-Host "== $($prefix)🌅 開盤前參考｜$dateText"
    Write-Host $desc
    foreach ($f in $fields) { Write-Host "-- $($f.name)`n$($f.value)" }
    exit 0
}
Send-Discord -Channel finance -Color $color -Title "$($prefix)🌅 開盤前參考｜$dateText" -Description $desc -Fields $fields
Write-Host "已送出開盤前參考（$dateText）"
if (-not $Test) {
    [System.IO.File]::WriteAllText($SentPath, (@{ date = $todayKey } | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
}
