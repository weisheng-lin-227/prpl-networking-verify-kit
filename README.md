---
title: networking_verify_kit — TR-181 CPE 北向→南向驗證套件
---

# networking_verify_kit

> 一套在 **TR-181 data-model 驅動的 OpenWrt CPE**（含 Broadcom 硬體 flow offload）上，
> 系統化驗證「北向設定 → 南向落地 → 封包真實行為」是否貫通的 **方法論 + 自動化 harness**。
> 方法論萃取、harness 設計與發布前檢查由 **AI agent 協作**（agent 1 指揮＋裁定、agent 2 執行、必要時 cross-review）完成。

## 這是什麼

電信 CPE 的網路功能走「北向 data model（TR-181）→ 翻譯層 → 南向 Linux → 硬體 datapath」，
每一層都可能 silent fail：DM 寫了沒生效、規則長了封包沒照走。本套件把「**怎麼驗才不被假象騙**」
固化成方法論、可複用腳本與發布前安全檢查。

- **方法論** → **[`METHODOLOGY.md`](METHODOLOGY.md)**：三層驗證（L1 DM / L2 南向 / L3 endpoint）、
  七步流程、offload 計數失真、假陽性陷阱、4-node bench 設計、測項框架、通用踩坑精華。
- **工具**：
  - `ns_verify.sh` — 驗證 harness（preflight / endpoint 抓包 / 三層落地 / offload 快照 / 死鏈掃描…）
  - `pc2_lan_netns.sh` — LAN 端點 netns harness（消滅雙臂短路假陽性）
- **發布邊界**：`bench.env.example`（node access inventory 範本）、`check_secrets.sh`（發布前掃描）、
  `SANITIZE.md`（public release boundary）。

## 適合誰

- prplOS / OpenWrt CPE 產品工程師：要判斷 TR-181 設定是否真的落到 Linux/HW datapath。
- QA / FAE / 系統整合：要把「GUI/DM readback 正常」推進到 endpoint 封包行為證據。
- Networking 開發者：要避免硬體 offload、雙臂測試機、buffered tcpdump 造成的假陽性/假陰性。

**不是什麼**：這不是 prpl 官方測試套件，也不是針對特定產品的 findings dump；公開版只保留去識別的方法論與可移植 harness。

## 快速使用

先看 CLI 能提供哪些 helper（不需要實機設定）：

```bash
./ns_verify.sh help
```

接上自己的 bench 後：

```bash
cp bench.env.example bench.env       # 填你自己的節點 IP / 帳號 / 憑證
chmod 600 bench.env
source bench.env && source ns_verify.sh
./ns_verify.sh preflight             # 環境健檢
```

LAN 端點測項需先把 `pc2_lan_netns.sh` + `bench.env` 部署到 observer，`up` 建好 netns。

> **節點角色 ↔ 變數名**：`DUT`=受測 CPE｜`FLYBOX`=upstream gateway｜`PC2`/`armA`=observer（WAN 抓包點）｜`armB`=LAN client（netns 隔離）。`ns_verify.sh` 跑在你的控制機、SSH 連各節點（PC2 也是 SSH 目標，非執行處）。變數名沿用 legacy 代號，語意見此對照與 `bench.env.example` 註解。

## 去識別 E2E 範例

同一個測項至少收三層證據；只看到 L1/L2 不宣告 PASS。

| 層 | 例子（以 NAT / port-forward 類測項為例） | 判定 |
|---|---|---|
| L1 北向 | `_set/_add` 後 `_get`，確認 DM instance 與參數存在 | 設定被 data model 接受 |
| L2 南向 | `iptables -S` / route / daemon config / HW flow table 出現對應 artifact | 翻譯層產生控制面意圖 |
| L3 行為 | observer endpoint 抓到改寫後位址、payload 或連通性變化 | 封包真的照設定走 |

若改 firewall/QoS 後既有流量仍照舊，先 flush flow-cache 並重跑 L3；不要用 DUT slow-path counter 當唯一證據。

## 無實機時 / 發布前

```bash
bash -n *.sh                                    # 腳本語法檢查
./check_secrets.sh                              # 機密掃描（需 bench.env；失敗只印 KEY 名、不印值）
git archive --format=tar HEAD > kit-public.tar  # 安全打包：只含 git 追蹤的公開軌（勿用 naive tar，會包進機密）
```

> 沒有實機 bench 的讀者：直接讀 **`METHODOLOGY.md`**；`bench.env.example` 即 integration contract（照欄位填即可接上自己的環境）。

## 倉庫邊界（重要）

本倉庫**只發布方法論與工具**。實機環境值、未去識別的工作筆記、原始證據與結果紀錄
以 `.gitignore` 排除、**不隨倉庫發布**（本地可保留，不影響執行）：

| 不發布（本地保留） | 內容 |
|---|---|
| `bench.env` | 實機節點 IP / MAC / 帳號 / 憑證（node access inventory） |
| `private/` | 本地工作筆記與未去識別細節 |
| `evidence/` · `*_RESULTS.md` · `*_report.md` | 原始證據與結果紀錄（測試產物） |

> 新接手者照 `bench.env.example` 填自己的環境、照 `METHODOLOGY.md` 跑，自建自己的證據與結果。
> 發布邊界與「新東西該放哪」見 `SANITIZE.md`。

## License

MIT（見 `LICENSE`）。方法論與工具可自由取用；內部資產不在此倉庫。
