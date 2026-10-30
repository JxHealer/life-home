# 股票日報：開盤後、收盤後各發一次 Discord #金融日報（0050、2330、美金匯率）
# 由 GitHub Actions 執行（.github/workflows/finance.yml），不消耗 Claude 用量。
# 用法：./scripts/finance-report.ps1 -Mode open|close [-Test]
#   open：開盤價與目前價格；close：今天收盤價
#   休市日（證交所沒有今天的資料）不發送；-Test 則照樣發送並在標題加【測試】

param([ValidateSet("open", "close")][string]$Mode = "close", [switch]$Test)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot/discord.ps1"

$watch = Get-Content (Join-Path $PSScriptRoot "../config/watchlist.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$Week = "日", "一", "二", "三", "四", "五", "六"
$UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"
$nowTw = [DateTimeOffset]::UtcNow.ToOffset([TimeSpan]::FromHours(8))
$todayKey = $nowTw.ToString("yyyyMMdd")

# 台股慣例：漲紅、跌綠
function Format-Change([double]$change, [double]$prev, [int]$digits = 2) {
    if ($prev -le 0) { return "—" }
    $pct = $change / $prev * 100
    $c = $change.ToString("+0." + "0" * $digits + ";-0." + "0" * $digits + ";0")
    $p = $pct.ToString("+0.00;-0.00;0.00")
    if ($change -gt 0) { return "🔴 ▲ $c（$p%）" }
    if ($change -lt 0) { return "🟢 ▼ $c（$p%）" }
    return "⚪ 平盤（0.00%）"
}
function Px($s) { if ("$s" -match '^[\d.]+$' -and [double]$s -gt 0) { [double]$s } else { $null } }

# ---------- 台股：證交所盤中資訊（收盤後也會保留當天最後成交） ----------
$ex = ($watch.stocks | ForEach-Object { "tse_$($_.code).tw" }) -join "|"
$quotes = @{}
(Invoke-RestMethod "https://mis.twse.com.tw/stock/api/getStockInfo.jsp?ex_ch=$ex&json=1&delay=0" -UserAgent $UA -TimeoutSec 30).msgArray | ForEach-Object { $quotes[$_.c] = $_ }

$tradeDay = ($quotes.Values | Select-Object -First 1).d
if ($tradeDay -ne $todayKey -and -not $Test) { Write-Host "今天休市（證交所最近交易日 $tradeDay），不發送"; exit 0 }

$fields = @(); $upCount = 0; $downCount = 0
foreach ($s in $watch.stocks) {
    $q = $quotes[$s.code]
    $prev = if ($q) { Px $q.y } else { $null }
    # z 是最近成交價，盤中常常是 "-"（那一刻沒成交），就改用最佳買價
    $price = if ($q) { Px $q.z } else { $null }
    if (-not $price -and $q) { $price = Px (($q.b -split '_')[0]) }
    $open = if ($q) { Px $q.o } else { $null }
    if (-not $price -or -not $prev) {
        $fields += @{ name = "$($s.code) $($s.name)"; value = "目前沒有成交資料"; inline = $true }
        continue
    }
    $change = $price - $prev
    if ($change -gt 0) { $upCount++ } elseif ($change -lt 0) { $downCount++ }
    $lines = @("**$($price.ToString('0.00'))**", (Format-Change $change $prev))
    if ($Mode -eq "open" -and $open) { $lines += "開盤 $($open.ToString('0.00'))　昨收 $($prev.ToString('0.00'))" }
    if ($Mode -eq "close" -and (Px $q.h) -and (Px $q.l)) { $lines += "最高 $((Px $q.h).ToString('0.00'))　最低 $((Px $q.l).ToString('0.00'))" }
    $fields += @{ name = "$($s.code) $($s.name)"; value = ($lines -join "`n"); inline = $true }
}

# ---------- 美金匯率（Yahoo 財經，取不到時改用 open.er-api.com） ----------
$fxText = "目前取不到匯率"
try {
    $j = Invoke-RestMethod "https://query1.finance.yahoo.com/v8/finance/chart/TWD=X?range=5d&interval=1d" -UserAgent $UA -TimeoutSec 30
    $m = $j.chart.result[0].meta
    $rate = [double]$m.regularMarketPrice; $prevFx = [double]$m.chartPreviousClose
    $fxText = "**$($rate.ToString('0.000'))**`n$(Format-Change ($rate - $prevFx) $prevFx 3)"
} catch {
    try {
        $j = Invoke-RestMethod "https://open.er-api.com/v6/latest/USD" -TimeoutSec 30
        $fxText = "**$(([double]$j.rates.TWD).ToString('0.000'))**`n（備用來源，沒有漲跌資料）"
    } catch {}
}
$fields += @{ name = "💵 美金兌台幣 USD/TWD"; value = "$fxText`n▲ 代表台幣貶值"; inline = $false }

# ---------- 發送 ----------
$dateText = "{0:M/d}（{1}）" -f $nowTw, $Week[[int]$nowTw.DayOfWeek]
$time = ($quotes.Values | Select-Object -First 1).t
$what = if ($Mode -eq "open") { "開盤" } else { "收盤" }
$note = if ($Mode -eq "open") { "早安！今天開盤後的價格（資料時間 $time），漲跌是和昨天收盤比。" } else { "今天的收盤價（資料時間 $time）。" }
$summary = "上漲 $upCount 檔、下跌 $downCount 檔、平盤 $($watch.stocks.Count - $upCount - $downCount) 檔"
$color = if ($upCount -gt $downCount) { 0xD9363E } elseif ($downCount -gt $upCount) { 0x2F9E57 } else { 0x808080 }
$prefix = if ($Test) { "🧪【測試】" } else { "" }

Send-Discord -Channel finance -Color $color `
    -Title "$($prefix)💰 金融日報｜$dateText $what" `
    -Description "$note`n$summary`n資料來源：臺灣證券交易所、Yahoo 財經" `
    -Fields $fields
Write-Host "已送出金融日報（$dateText $what）"
