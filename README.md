# Usage Ring for Claude

> **非官方工具，與 Anthropic 無關。** "Claude" 是 Anthropic 的商標，本專案僅用來描述它支援的服務。
> *Unofficial. Not affiliated with, endorsed by, or sponsored by Anthropic.*

在 Mac 上常駐顯示你的 Claude 方案用量，數字跟 [claude.ai › Settings › Usage](https://claude.ai/settings/usage) 上的 **Current session** 一樣。不管你切到 Chrome、桌面還是全螢幕 app，都看得到。

A tiny macOS app that keeps your Claude plan usage (the "Current session" limit from claude.ai › Settings › Usage) visible on top of every app.

## 功能

- **選單列**：小圓環加上目前 session 的百分比，例如 `◔ 42%`。點開可以看詳細用量和設定。
- **懸浮圓環**：浮在所有視窗最上層的小圓環，切到任何 app 都看得到。
  - 顏色：綠色（< 70%）、橘色（70–89%）、紅色（≥ 90%）
  - **滑鼠移上去**：顯示 Current session 和 Weekly（All models / Opus / Sonnet）的用量，以及多久後重置
  - **單擊**：在瀏覽器開啟 claude.ai 用量設定頁
  - **拖曳**：移動位置（會記住）；**右鍵**：選單
- 每 60 秒自動更新，電腦醒來時也會更新
- 可以設定登入時自動開啟，也可以只保留選單列、把懸浮圓環關掉

## 安裝

需要 macOS 13 以上。

1. 到 [Releases](https://github.com/QQ1010/usage-ring-for-claude/releases) 下載最新的 `Usage-Ring-for-Claude-vX.Y.Z.zip`
2. 解壓縮，把 `Usage Ring for Claude.app` 拖到「應用程式」資料夾
3. 第一次打開：這個 app 沒有 Apple 開發者簽章，macOS 會擋下來。
   - 對 app 按右鍵 › **打開** › 再按一次 **打開**
   - 如果沒有「打開」可以按（macOS 15 以後）：到 **系統設定 › 隱私權與安全性**，往下捲找到這個 app，按 **強制打開**
4. 點懸浮圓環或選單列的「登入」，在跳出的視窗裡登入 claude.ai

### 從原始碼編譯

只需要 Xcode Command Line Tools（`xcode-select --install`）：

```bash
git clone https://github.com/QQ1010/usage-ring-for-claude.git
cd usage-ring-for-claude
./build.sh
open "build/Usage Ring for Claude.app"
```

## 登入說明

- **請用 email 登入。** Google 不允許在 app 內嵌的瀏覽器裡登入 Google 帳號，這是 Google 的規定，所以「使用 Google 帳號繼續」會被擋下。
- **為什麼 Claude Desktop 已經登入了，這裡還要再登入？** macOS 上每個 app 的登入資料是分開保存的，這個 app 讀不到 Claude Desktop 的登入資料，也不會去讀。
- 登入資料只存在這台 Mac 上這個 app 自己的 WebKit 資料夾裡，app 不會把它傳到 claude.ai 以外的任何地方。

## 運作方式與限制

- app 在一個隱藏的 WebKit 視窗裡，用你的 claude.ai 登入去讀網頁版用量頁面使用的同一份資料（`/api/organizations/{id}/usage`）。
- **這份資料沒有官方公開文件。** Anthropic 隨時可能修改它，這個 app 就可能失效。
- 選單列和懸浮圓環顯示的是 **Current session**（5 小時時窗）；Weekly 的用量放在詳細資訊裡。
- 需要 Claude 訂閱方案（Pro / Max 等）。只用 API key 的帳號沒有這些額度資料。
- 目前狀態：**實驗性**。如果圓環顯示「!」，把滑鼠移上去就能看到錯誤訊息，歡迎到 [Issues](https://github.com/QQ1010/usage-ring-for-claude/issues) 回報。

## 移除

在選單列選 **結束**，再把 app 從「應用程式」資料夾刪掉。如果要一併清掉登入資料和設定：

```bash
rm -rf ~/Library/WebKit/io.github.qq1010.usage-ring-for-claude ~/Library/Caches/io.github.qq1010.usage-ring-for-claude
defaults delete io.github.qq1010.usage-ring-for-claude
```

## 授權

[MIT](LICENSE)
