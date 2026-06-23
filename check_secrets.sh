#!/usr/bin/env bash
# check_secrets.sh — 發布前機密掃描 gate。
# 從 bench.env 動態載入真值 + 通用機密樣式，掃「會上傳的檔」有無洩漏；命中即非 0 退出。
# ⚠️ 本腳本不含真值（規則從 bench.env 讀）；失敗只印 KEY 名、不印值（避免二次洩漏）→ 可公開。
# 用法：./check_secrets.sh   （git repo 內掃 git ls-files；否則掃根目錄公開檔）
set -u
cd "$(dirname "$0")"

ENV="${BENCH_ENV:-./bench.env}"
[ -f "$ENV" ] || { echo "⚠ 缺 $ENV，無法掃描（cp bench.env.example bench.env 並填）" >&2; exit 2; }
. "$ENV"

# 待掃清單＝即將發布面：git 追蹤檔 + 未追蹤但未被 ignore 的檔（涵蓋新建未 add 的公開檔，
# 這正是 agent 產出公開軌新檔最常見的狀態）；非 git 則根目錄公開檔。排除掃描器與範本自身。
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  mapfile -t files < <(git ls-files --cached --others --exclude-standard)
else
  mapfile -t files < <(ls ./*.md ./*.sh ./*.example 2>/dev/null | sed 's|^\./||')
fi
mapfile -t files < <(printf '%s\n' "${files[@]}" | grep -vE 'check_secrets\.sh|bench\.env\.example')
[ "${#files[@]}" -eq 0 ] && { echo "（無待掃檔）"; exit 0; }

# 規則 1：逐一掃 bench.env 的敏感 key（array 比對，免 word-split；失敗印 KEY 不印值）
KEYS=(DUT DUT_WAN DUT_WAN_IF DUT_LAN_MAC FLYBOX PC2 PC2_USER PC2_LOGIN_PW PC2_ROOT_PW
      PC2_IF ARMB_IF ARMB_MAC ARMB_IP ARMB_NM_CON ARMA_IF ARMA_IP
      LAN_IF WAN_IF LAN_CLIENT_IP LAN_CLIENT_MAC DEV_BOARD DEV_SOC DEV_VENDOR)
# 通用預設/非機密值，略過避免誤報（通用 LAN 192.168.x、ethN、NM 連線名、空）
GENERIC='^(192\.168\.[0-9]+\.[0-9]+|eth[0-9]+|Wired connection [0-9]+)$'

hit=0
for k in "${KEYS[@]}"; do
  v="${!k:-}"
  [ -z "$v" ] && continue
  printf '%s' "$v" | grep -qE "$GENERIC" && continue
  case "$v" in REPLACE_ME*) continue;; esac
  f=$(printf '%s\n' "${files[@]}" | xargs -r grep -lFi -- "$v" 2>/dev/null | tr '\n' ' ')
  [ -n "$f" ] && { echo "🔴 洩漏 KEY=$k（值已 REDACTED）於：$f"; hit=1; }
done

# 規則 2：通用機密樣式（私有網段 10.x / 172.16-31、任意 MAC）；排除文件保留值。只印檔:行不印內容。
DOC_SAFE='2001:db8|203\.0\.113|198\.51\.100|192\.0\.2|02:00:00:[Dd][Ee][Aa][Dd]'
for r in '10\.[0-9]+\.[0-9]+\.[0-9]+' '172\.(1[6-9]|2[0-9]|3[01])\.[0-9]+\.[0-9]+' '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}'; do
  loc=$(printf '%s\n' "${files[@]}" | xargs -r grep -nEH -- "$r" 2>/dev/null | grep -vE "$DOC_SAFE" | cut -d: -f1-2 | sort -u | tr '\n' ' ')
  [ -n "$loc" ] && { echo "🔴 命中機密樣式 [$r] 於：$loc"; hit=1; }
done

if [ "$hit" -eq 0 ]; then
  echo "✅ 機密掃描通過：發布清單無真值殘留"; exit 0
else
  echo "✗ 發現疑似機密 → 抽進 bench.env / 改 placeholder 後再 push"; exit 1
fi
