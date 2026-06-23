---
title: AGENTS.md — agent 驅動 networking_verify_kit 的「執行 + 歸檔」契約
---

# AGENTS.md

> 給用 AI agent 驅動 **networking_verify_kit** 的人與 agent 讀。
> 目標：agent 跑測項時**自動把證據累積進私有軌**（`evidence/` + `networking_verify_RESULTS.md`），
> 同時**結構性保證不洩漏回公開軌**。本檔屬公開軌、已去識別。

採用者照本契約讓 agent 跑，就能「邊驗邊長出自己的私有證據庫」，而公開的方法論/工具仍可持續 `git pull` 更新，兩者零衝突、零洩漏。

> **agent 動手前先吃這兩節**：**§1 兩條軌**（真值只進私有軌、公開軌只放去識別內容）＋ **§2 護欄 R1–R5**（硬規則，違反即停手）。其餘為流程、範例與輸出契約。

## 0. 動手前先讀

- **`METHODOLOGY.md`** — 三層驗證（L1 北向 DM / L2 南向 / L3 endpoint）、假陽性陷阱、判讀紀律；verdict gate 實作見 `ns_verify.sh` 的 `verdict_gate`（用法見 §2 R4）。
- **`SANITIZE.md`** — 公開↔私有邊界與「新東西該放哪」SOP。
- **`bench.env`** — 環境存取值（IP/帳號/憑證/iface；git 排除）。缺就 `cp bench.env.example bench.env` 填真值。

## 1. 兩條軌，agent 必須分清（最重要）

| 軌 | 檔 | agent 可否寫 | 可否含真值 |
|---|---|---|---|
| **公開軌**（git 追蹤） | `README` / `METHODOLOGY` / `SANITIZE` / `AGENTS` / `LICENSE` / `.gitignore` / `bench.env.example` / `check_secrets.sh` / `ns_verify.sh` / `pc2_lan_netns.sh` | 可，但**去識別 + `check_secrets.sh` 通過**才行 | ❌ 絕不 |
| **私有軌**（git 排除，**累積層**） | `bench.env`、`evidence/`、`networking_verify_RESULTS.md`、`*_report.md`、`private/` | 自由寫 | ✅ 原始真值 OK（不發布） |

> 一句話：**真值只進私有軌；公開軌只放去識別的方法論/工具。** agent 每次寫檔前先問「這檔在哪一軌」。

## 2. 護欄（硬規則，違反即停手 escalate）

- **R1 只自動寫三個私有桶**：`evidence/`、`networking_verify_RESULTS.md`、`private/`。其餘一律不自動寫。
- **R2 禁止在 repo 根目錄產「非 ignore 命名」的檔** — 那會變成 commit 候選 → 洩漏：
  - ❌ 散落根目錄的 `summary.md`、`report.txt`、`cap.pcap`、`run.log`、`out.txt`
  - ✅ 一律收進 `evidence/<TS>/`，或寫進 `networking_verify_RESULTS.md`
  - （`.gitignore` 已對 `*.pcap/*.cap/*.log/*.txt` 設安全網，但別依賴它 — 命名照 R1）
- **R3 碰公開軌前 = 去識別 + 機密掃描**：要改 `METHODOLOGY.md`（升教訓）或任一公開檔前，先把真值換 placeholder
  （IP→`192.168.1.x` / RFC5737、設備→泛化名如「OpenWrt/TR-181 CPE」「Broadcom offload」、存取值→`bench.env` 變數），
  再 `./check_secrets.sh` **必須 exit 0** 才 `git add` 公開檔。
- **R4 verdict 紀律**：宣告 🔴 FAIL 前過 verdict gate 四勾（`ns_verify.sh` 的 `verdict_gate`）—
  `source ns_verify.sh; verdict_gate <id> p50=1 p51=1 p07=1 p55=1`，缺項退回補測，不硬宣告。
- **R5 觀測紀律沿用 methodology**：判封包落地**信端點、非 DUT offload 計數**（P-07）；抓包 `-U` / 關 NIC offload 保真（P-58）；
  改設定後 `dut "fcctl flush"` 再驗 L3（P-50）；LAN→WAN 先確認流量真穿 DUT（P-04/P-51，用 `pc2_lan_netns.sh`）。

## 3. run-and-record 迴圈（每跑一個測項就做）

```bash
TS=$(date -u +%Y%m%dT%H%M%SZ)          # agent 直接跑 Bash，date 可用
mkdir -p "evidence/$TS"

# 1) 跑測項，接住 stdout（含 rec() 印的 [PASS/FAIL/BLOCK] <id> <msg> 裁定行）
out=$(./ns_verify.sh masq); printf '%s\n' "$out"

# 2) 把腳本印出的 /tmp 抓包搬進 evidence/（腳本會印 "evidence: /tmp/..."）
#    ns_verify.sh masq → /tmp/ns_masq_*.txt ；pc2_lan_netns.sh test → /tmp/armA_p51_cap.txt
mv /tmp/ns_masq_*.txt "evidence/$TS/" 2>/dev/null || true
```

3) 追加一筆結構化 run-note 到 `networking_verify_RESULTS.md`（根目錄**唯一一份**，append-only）：

```markdown
## <TS> · <test-id>
- verdict : <PASS|FAIL|BLOCK> <id> — <一句判讀>
- cmd     : ./ns_verify.sh masq
- evidence: evidence/<TS>/<file>
- layer   : L1=<北向DM結果> L2=<南向artifact> L3=<endpoint行為>   # 三層收齊才宣告 PASS（P-22）
- notes   : <agent 判讀；可關聯 methodology 的踩坑/觀測紀律；BLOCK 就接著查根因再補記>
```

> 比腳本硬寫多出來的價值：agent **判讀**而非 dump、能跨關聯 methodology 踩坑/根因、BLOCK 時自己接著查根因再記。

## 4. 把教訓升上公開軌（`METHODOLOGY.md §7`）

只有**跨平台、去識別**的通用教訓才上公開軌；平台特定 finding / 原始根因留 `private/`。

```
private/ 草擬 finding  →  抽象成跨平台教訓 + 去識別  →  ./check_secrets.sh（exit 0）
  →  寫進 METHODOLOGY.md §7  →  git add 只加公開檔  →  commit
```

## 5. 一輪端到端範例（agent 視角）

```
1. ./ns_verify.sh preflight            # 環境健檢；把 [PASS/FAIL] 摘要記進 RESULTS（TS 一筆）
2. ./ns_verify.sh masq                 # 跑測項
   → 解析裁定行：[PASS ] NS-MASQ PC2 收到來源=$DUT_WAN（SNAT 生效）
   → mv /tmp/ns_masq_*.txt evidence/<TS>/
   → 追加 RESULTS：verdict=PASS / evidence 連結 / layer L1L2L3 / notes
3. 若 FAIL：先 verdict_gate 四勾（R4）→ 過了才宣告 🔴；查根因寫 private/，別寫公開軌
4. 收斂出跨平台教訓 → 照 §4 去識別升 METHODOLOGY §7
```

> 全程：證據與真值只落 `evidence/` / `*_RESULTS.md` / `private/`（gitignore）；公開軌只在 §4 去識別後才動
## 6. 輸出契約（你要交付什麼）

1. **結果持續紀錄 `networking_verify_RESULTS.md`**（私有軌）：每個測項要有 verdict / 證據索引 / run note / caveat；候選坑先留 draft，過 §2 R4 的 verdict gate 再定案。
2. **原始證據 `evidence/`**（私有軌）：每測項關鍵指令輸出存 `evidence/<TS>/` 或具辨識度的命名檔；不要刪舊證據、不要覆蓋不同輪次快照。
3. **踩坑持續追加**（**最重要**）：每個新坑一條，標發現來源 + 證據強度。平台特定坑留 `private/`（自建你自己的 pitfalls 檔）；唯有**跨平台、去識別**的通用教訓才照 §4 升 `METHODOLOGY.md §7`（通用踩坑精華）。
4. **DM→南向落地對照**：確認新的 DM→鏈 / 物件 / daemon / offload / 觀測點時，回寫到你自己在 `private/` 的落地對照筆記。
5. **run log**：跑了哪些、跳過哪些、為什麼跳、下一棒從哪接，寫在 `networking_verify_RESULTS.md` 對應區。

---

## 7. 一鍵起步

1. `cp bench.env.example bench.env` 填真值（建議 `chmod 600`）→ `source bench.env && source ns_verify.sh` → `./ns_verify.sh preflight` 對現況；任何節點 / IP / 權限不符就 STOP，先修環境。
2. 三大「假落地」陷阱（① DM 有值 ≠ 南向有 rule ≠ 封包照走；② offload 繞過 Linux 計數；③ 雙臂 / 多宿主短路）每項都適用 —— 完整根因見 `METHODOLOGY.md`（§2 三層驗證 / §3 offload 失真 / §4 假陽性陷阱）。
3. 測什麼、優先序與測項框架見 `METHODOLOGY.md §6`；平台特定測計畫自建於 `private/`。
4. 每項照 §2 護欄 + §3 run-and-record 跑：證據落 `evidence/`，結果回 `networking_verify_RESULTS.md`，跨平台教訓照 §4 升 `METHODOLOGY.md §7`（平台特定留 `private/`）。

> ⚠️ 接手第一件事是**重驗環境**（IP / image / 存取值都 volatile）：先 `./ns_verify.sh preflight`。本契約寫的指令 / 路徑若與現況衝突，**信現況**。
