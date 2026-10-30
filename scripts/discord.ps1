# 共用函式：把訊息送到 Discord 頻道
# 用法：. "$PSScriptRoot/discord.ps1"; Send-Discord -Channel finance -Title "標題" -Description "內容"
#
# Webhook 網址放在 GitHub 的 Secret「DISCORD_WEBHOOKS」（內容和電腦上的 config\webhooks.json 一樣），
# 執行時以環境變數傳入，不會出現在資料庫裡。
# 頻道：finance（#金融日報）、sports（#球賽）、pogo、pikmin、idol（#追星資訊）、game（#遊戲活動）
# pogo / pikmin 沒設定自己的 Webhook 時，會改送到 game，但仍然是各自獨立的一則訊息。

$Channels = @("finance", "sports", "pogo", "pikmin", "idol", "game")
$Fallback = @{ pogo = "game"; pikmin = "game" }
if (-not $env:DISCORD_WEBHOOKS) { throw "沒有 DISCORD_WEBHOOKS（請在 GitHub 的 Secrets 設定）" }
$WebhookConfig = $env:DISCORD_WEBHOOKS | ConvertFrom-Json

function Test-WebhookUrl($url) {
    return $url -match '^https://(discord|discordapp)\.com/api/webhooks/\d+/[\w-]+$'
}

function Get-WebhookUrl {
    param([Parameter(Mandatory)][ValidateScript({ $_ -in $Channels })][string]$Channel)
    $url = $WebhookConfig.$Channel
    if (-not (Test-WebhookUrl $url) -and $Fallback.ContainsKey($Channel)) { $url = $WebhookConfig.($Fallback[$Channel]) }
    if (-not (Test-WebhookUrl $url)) { throw "DISCORD_WEBHOOKS 裡的 '$Channel' 不是有效的 Webhook 網址" }
    return $url
}

function Send-Discord {
    param(
        [Parameter(Mandatory)][ValidateScript({ $_ -in $Channels })][string]$Channel,
        [Parameter(Mandatory)][string]$Title,
        [string]$Description = "",
        [int]$Color = 0x5865F2,
        [array]$Fields = @()
    )
    $embed = @{ title = $Title; description = $Description; color = $Color; timestamp = [DateTimeOffset]::UtcNow.ToString("o") }
    if ($Fields.Count -gt 0) { $embed.fields = $Fields }
    $json = @{ embeds = @($embed) } | ConvertTo-Json -Depth 6
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    Invoke-RestMethod -Uri (Get-WebhookUrl $Channel) -Method Post -Body $bytes -ContentType "application/json; charset=utf-8" | Out-Null
}
