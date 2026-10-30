# life-home

生活助理的雲端排程（GitHub Actions），結果發到 Discord。

- **開賣提醒**（`.github/workflows/tickets.yml`）：每 10 分鐘檢查 `data/events`，售票開始前 1 小時通知。
- **股票日報**（`.github/workflows/finance.yml`）：平日 09:10 開盤後、13:40 收盤後各一次。

Discord 網址存在 Secret `DISCORD_WEBHOOKS`，不在程式碼裡。
