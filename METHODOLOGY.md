---
title: Northbound→Southbound Networking Verification — 方法論
scope: 在 OpenWrt / TR-181 (data-model) 架構的 CPE 上，驗證「北向設定 → 南向實際落地 → 封包真實行為」是否貫通
---

# Networking 北向→南向落地驗證方法論

> 一套在 **TR-181 data-model 驅動的 OpenWrt CPE**（具 Broadcom 硬體 flow offload）上，
> 系統化驗證「設定有沒有**真的生效到封包行為**」的方法論、工具與檢查清單。
> 本文件是去識別的**方法論精華**；可執行工具見 `ns_verify.sh` / `pc2_lan_netns.sh`。

## 1. 要解決的問題

電信 CPE 的網路功能走 **北向 data model（TR-181）→ 翻譯層 → 南向 Linux（iptables / route / dnsmasq…）→ 硬體 datapath**。
每一層都可能 **silent fail**：data model 寫進去了、readback 也對，但南向沒長出規則；或規則長了，但封包根本沒照走。

> **核心命題**：「設定吃進去了」≠「南向有規則」≠「封包真的照走」。三者要**各自獨立驗證**。

## 2. 三層驗證模型（核心）

| 層 | 驗什麼 | 怎麼看 |
|---|---|---|
| **L1 北向** | data model `_set/_add` 後 `_get` 對拍 | DM readback |
| **L2 南向** | 翻譯層有沒有產出對應 artifact | `iptables -S` / `ip route` / dnsmasq conf / tc / HW 表 |
| **L3 行為** | 封包是否真的照走（金標準） | **endpoint 觀測**（吞吐 / loss / 連通性 / 改寫後位址） |

> **判定鐵則**：只到 L1/L2 **不算落地**。最終連通性/吞吐/loss 一律以 **endpoint** 為金標準。

### 七步流程（每個測項）
`baseline → 北向 _set/_add → L1 _get 對拍 → L2 南向 artifact → L3 endpoint 行為 → revert → 記錄`

## 3. 為什麼 endpoint 是金標準：offload 計數失真

具硬體 flow offload（如 Broadcom Runner/Archer）的平台上，**被 offload 的 forwarded flow 繞過 Linux slow-path** → DUT 本機的 `conntrack`/`iptables` 計數**失真**，拿來判「封包有沒有落地」會得到假結論。

- **定性**可用 CPU-mirror（把 offloaded flow 鏡一份到 host 才能 tcpdump，但 lossy）做 NAT/DSCP/TTL 改寫的**性質**檢查。
- **精確量化**要選對抽象層：讀**硬體 flow 計數**（廠商 flow-cache 的 HW 命中欄），而非 legacy software flow-cache（會假 0）。
- **吞吐/loss/連通性**永遠以 **endpoint** 為準。

## 4. 假陽性陷阱（最隱蔽、最該先記住）

驗證「流量真的穿過 DUT」時，有兩類結構性假陽性會讓你誤判「有 NAT/forward」：

- **多宿主捷徑**：測試機若同時連在 LAN 與 WAN 兩側，流量可能走**直連捷徑、根本沒碰 DUT**。→ 必須加 **host route 強制穿 DUT**，或用下面的 netns 隔離。
- **同主機雙臂短路**：同一台機器上的兩個網卡互 ping，會走 **kernel local delivery、不出網卡**。`SO_BINDTODEVICE` 只約束出介面、不阻止本地投遞。

### 結構性解法：netns 隔離 LAN 端點
把 LAN client 網卡 move 進獨立 network namespace → namespace 內 **routing table 隔離、根本沒有對側的 local address** → 送任何位址都**必照 default route 穿 DUT**，捷徑物理上不存在。（實作見 `pc2_lan_netns.sh`）

## 5. 環境設計：4-node bench

```
   upstream gateway（模擬 ISP；DUT 的 default route）
      │  WAN 段 198.51.100.0/24（RFC5737 文件網段；實機 IP/iface 見 bench.env）
      │
   DUT  受測 CPE ── ssh root@$DUT
      │  ① 北向 TR-181 data model
      │  ② 南向 Linux（iptables / route / dnsmasq…）
      │  ③ HW datapath（Broadcom offload）
      │
      ├─ WAN 側 ── observer·armA（$PC2_IF）
      │              ├ forwarded flow 金標準：tcpdump -U 抓 post-NAT 來源位址
      │              ├ ⚠ 只是 WAN 抓包點，ns_verify.sh 不在此跑（在控制機，見下）
      │              └ ⚠ SSH 命脈，絕不碰
      │
      └─ LAN 段 ── observer·armB（$ARMB_IF）  192.168.1.0/24
                     └ netns「lanns」隔離（pc2_lan_netns.sh up）：namespace 內
                        無對側 local IP → 送任何位址都必照 default route 穿 DUT
                        → 結構性消滅雙臂短路；ns_verify.sh 的流量源出於此
```

- **observer（PC2，一台雙網卡機·雙臂）**：`armA`（`$PC2_IF`，WAN 段）= forwarded flow 金標準觀測點（WAN 端抓 post-NAT 來源）+ SSH 命脈（絕不碰）；`armB`（`$ARMB_IF`，LAN 段）= LAN client。同一台兩臂，故能同時當 WAN 觀測點與 LAN 打流端。
- **harness 執行處 ≠ 受測節點**：`ns_verify.sh` 跑在你的**控制機**（`source` 它的那台），透過 SSH 連 `DUT`/`FLYBOX`/`PC2`；故腳本把 PC2 當遠端目標（`pc2()`/`pc2_capture()`），與「在 PC2 上跑」無關。部署到 observer 本機跑的是另一支 `pc2_lan_netns.sh`。
- **armB netns 隔離**：`pc2_lan_netns.sh up` 把 armB 物理 NIC move 進 netns `lanns` → 內無對側 local address → 送任何位址都必穿 DUT，結構性消滅雙臂短路假陽性。
- **access inventory**：所有節點的 IP/帳號/憑證/iface 集中在 `bench.env`（git 排除），腳本/文件 runtime `source` 它 → 單一真相來源、憑證不進版控。範本見 `bench.env.example`。
- **網段去識別**：圖中 `192.168.1.0/24`（LAN）、`198.51.100.0/24`（WAN，RFC5737 文件網段）為 placeholder；實機 IP/MAC/iface 名只在 `bench.env`，不進版控（邊界見 `SANITIZE.md`）。

## 6. 測項框架（功能面）

以 WebUI **功能面**（而非翻譯層）展開測項，每項標準化欄位：
**北向 DM path · 可寫 param · 南向 artifact · 是否 offload · L3 觀測點/工具 · Pass 條件 · Revert · verdict**。

涵蓋面：WAN（DHCP/PPPoE）、LAN+DHCP、QoS（classification/queue/shaper）、NAT（DMZ/port-forward/static/port-trigger）、Firewall/IP-filter、Multicast（IGMP snooping/proxy）、DNS、IPv6（PD/RA/firewall）、VLAN、ALG、Guest 隔離。

> 配套：CMS-diff oracle（北向設定 → 南向 diff 對照）、優先序（電信 CPE 高頻 + 最易藏坑者先）、回寫 SOP（verdict 單一來源 + 證據索引 + 通用踩坑升級）。

## 7. 通用踩坑精華（去識別，跨平台適用）

| # | 踩坑 | 教訓 |
|---|---|---|
| 觀測 | offload 繞過 Linux 計數 | 判落地看 endpoint，不信 DUT slow-path counter |
| 觀測 | 多宿主捷徑 / 雙臂短路假陽性 | host route 或 netns 強制穿 DUT |
| 觀測 | `tcpdump -w` 預設 block-buffered | 抓 forwarded 流量要 `-U`；文字輸出用 `-l`，否則假陰 |
| 觀測 | `nc` 退出碼不可靠（timeout 也回 0） | 判服務可達看實際 banner/payload，不看 `$?` |
| data model | search-expression 當 `_add` parent 會 silent fail | 先解 concrete key |
| data model | readback 對、南向卻沒生效 | 三層獨立驗，別只信 L1 |
| 行為 | 改規則對「已 offload 的既有 flow」不生效 | 改 firewall/QoS 後 flush flow-cache；用單一持久流 + mid-stream 改設定才測得到 staleness |
| 行為 | 規則落在「被遍歷但 `-i/-o` 方向錯」的鏈 | DM rule 落 iptables ≠ 真 match |
| 環境 | 破壞性測項會切斷控制通道 | 先畫控制通道安全地圖；備 serial console |
| 環境 | 非同步/debounced apply | `_set` 後南向延遲生效，立讀=假陰，要 poll |
| 觀測 | offload 宣稱只憑「單次 dump」 | 判 offload 要 **idle baseline → 實起一條 flow → 多個獨立 HW 觀測面交叉對拍**（各面 flow 數/key 須一致）；且「計數表空」≠「沒 offload」——offload 常有獨立的**資格/skip-reason 層**說明為何沒被加速 |
| 驗證 | 搜尋/grep 回 0 命中就斷定「不存在」 | 先做 **positive control**（搜一個已知存在的詞必須命中）證明搜尋真有讀到內容，否則 0 可能是搜尋壞掉的**假陰** |
| 環境 | 「文件/BSP 列了此工具/功能」≠「本 image 編進來可用」 | 動手前在**受測目標上**驗工具/能力存在（如 `command -v`）；缺＝該解法不可行（轉 rebuild 決策），別把文件能力誤推成 runtime 可用 |
| 環境 | 判「環境壞了/節點不在」前沒先排除自己 tooling 假陰 | 經 sudo/ssh 包裝的遠端**多步**指令，特權常只套到第一段→後續靜默失敗（stderr 還被吞）；先用**單一自包裝腳本**（`sudo sh <file>`）重驗，排除是 wrapper 造的假陰 |

腳本註解中的 `P-NN` 是原驗證 campaign 的歷史 shorthand；公開版不依賴完整內部編號庫，
其去識別後的通用教訓已收斂在上表。

## 8. 工具 / 自動化

- **`ns_verify.sh`** — 驗證 harness：`preflight`（環境健檢）/ `masq` / `chain-audit`（死鏈掃描）/ `cap`（endpoint 抓包）/ `reach`（payload-based 可達）/ `l3verify`（三層一次收齊）/ `datapath`（offload 快照）…。`source` 後即得各節點 access helper。
- **`pc2_lan_netns.sh`** — LAN 端點 netns harness：`up/down/status/exec`，消滅雙臂短路。
- **`bench.env`** — node access inventory（單一真相來源，git 排除）。
- **`check_secrets.sh`** — 發布前機密掃描 gate。

## 9. AI 協作（多 agent）

本套件的驗證/維護採**雙 agent 分工**：**agent 1**（指揮＋裁定）指揮 **agent 2**（執行）跑七步測項、產候選結論，再由 agent 1 排假陰、判真假、回寫三層；必要時以 cross-review（不同模型互審）降低單一模型盲點。兩 agent 透過跨 pane 傳輸層（終端多工的 pane 間通訊）交換指令與結果。
