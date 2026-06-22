# SANITIZE — public release boundary

本倉庫只發布去識別的方法論與工具；實機值、未去識別工作筆記、原始證據與結果紀錄不進版控。
本文件是維護時的 release boundary，避免把本地執行資料誤放進公開軌。

## 機密 ↔ 公開 對照

| 類別 | 本地資料 | 公開用 |
|---|---|---|
| 節點 IP / MAC | `bench.env` 的實機 access inventory | `$DUT_WAN` / `$ARMB_MAC` 等變數與 example placeholder |
| 帳號 / 密碼 | observer 登入與提權值 | `$PC2_USER` / `$PC2_*_PW`，值只在 `bench.env` |
| 設備識別 | board 序號 / SoC 型號 / image 名 | 泛化為「OpenWrt/TR-181 CPE」「Broadcom offload」 |
| 實測細節 | 未去識別工作筆記、平台特定缺陷、原始證據 | 不發布；只把跨平台教訓抽象到 `METHODOLOGY.md` |

> 保留為公開的通用技術名（不算機密）：OpenWrt、TR-181/data model、netfilter/iptables、
> conntrack、dnsmasq、odhcpd、Broadcom offload 等公開概念，以及通用網段 192.168.1.x。

## 邊界（`.gitignore`）
- `bench.env` — 實機 access inventory（建議 `chmod 600`）
- `private/` — 本地工作筆記與未去識別細節
- `evidence/`、`*_RESULTS.md`、`*_report.md` — 測試產物

## 新東西該放哪（SOP）
| 新產生的 | 放哪 | 上傳? |
|---|---|---|
| 測試證據輸出 | `evidence/` | ✗ |
| 結果 / verdict / run note | `networking_verify_RESULTS.md`（根目錄**唯一一份**；勿另存 private/） | ✗ |
| 平台特定 finding / 原始根因 | `private/` | ✗ |
| 跨平台方法論教訓 | `METHODOLOGY.md` §7（去識別後） | ✅ |
| 新節點 / 環境值變更 | `bench.env`（+ 同步 `bench.env.example` 的 placeholder） | env 本身 ✗ / example ✅ |

## 發布前必做
```bash
./check_secrets.sh          # 機密掃描，必須 exit 0
git status --ignored        # 確認 bench.env / private/ / 產物 在 ignored
git ls-files                # 確認只追蹤公開軌
```
> ⚠️ 用 tar/zip 打包（而非 git push）時 `.gitignore` 不生效 → 改用 `git archive`，
> 或手動剔除 `private/`、`bench.env`、產物後再打包。
