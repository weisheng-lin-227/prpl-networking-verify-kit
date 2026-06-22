#!/usr/bin/env bash
#
# ns_verify.sh — northbound→southbound networking verification harness (TR-181 / OpenWrt CPE)
#
# 用途：把「環境存取 + 正確觀測法」固化成可複用 helper，在此之上擴充功能面測項。
# 核心紀律（見 METHODOLOGY.md）：
#   - 判封包落地一律在 ENDPOINT 抓（PC2/flybox），不用 DUT conntrack/iptables 計數（offload，P-07）。
#   - LAN→WAN 測試前確認 host route 已強制穿 DUT（P-04）。
#   - DUT 走單一 ssh master（dropbear 節流，P-03）。
#   - PC2 提權密碼 ≠ 登入密碼（值見 bench.env，P-02）；一般 root 仍 password-pipe。
#   - PC2 擷取 tool（tcpdump/socat/ethtool/ncat/ip/tc）已 scoped 免密 sudo
#     （/etc/sudoers.d/10-bench-ns 之類 scoped sudoers）→ cap/cap_prep 走 sudo -n，徹底脫離 P-02。
#
# 用法：
#   ./ns_verify.sh preflight          # 環境健檢（每次接手先跑）
#   ./ns_verify.sh masq               # 已驗證範例：LAN→WAN masquerade 端到端
#   ./ns_verify.sh wan_ingress        # WAN ingress 預設 drop（安全姿態）
#   ./ns_verify.sh chain-audit        # 死鏈/重複名鏈掃描 + DM-path 反查（P-55/P-61）
#   ./ns_verify.sh guard              # §8.5 pre-campaign guard（xtables.lock wedge 等，P-56）
#   ./ns_verify.sh cap <if> <s> <flt> # PC2 tcpdump -U 擷取（P-58）
#   ./ns_verify.sh reach <ip> <port>  # payload-based 可達（取代 nc $?，P-29）
#   ./ns_verify.sh pflow              # 持久流 staleness 測法範式（P-60）
#   ./ns_verify.sh datapath [tuple]   # DUT flow-cache/offload 快照（HW vs SW，P-38/50/62）
#   ./ns_verify.sh l3verify <id> <dm-path> <chain>  # P-22 三層落地一次收齊
#   ./ns_verify.sh clockcheck [thr-s] # 各 node UTC 時鐘漂移（P-48）
#   source ./ns_verify.sh             # 只載入 helper，自己組測項
#
set -u

# Public-repo UX: allow first-time readers to inspect usage without creating bench.env.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-help}" in
    help|-h|--help)
      sed -n '3,27p' "$0"
      exit 0
      ;;
  esac
fi

# ----------------------------- config -----------------------------
# node access inventory（IP/帳號/密碼/iface）從 bench.env 讀——本地檔、git 排除。
# 沒有就：cp bench.env.example bench.env 並填真值（見 README）。
# 已先 `source bench.env` 則沿用；否則自己找同目錄 bench.env。
_need="DUT DUT_WAN FLYBOX PC2 PC2_USER PC2_LOGIN_PW PC2_ROOT_PW PC2_IF LAN_IF WAN_IF"
_miss=0; for _k in $_need; do eval "[ -n \"\${$_k:-}\" ]" || { _miss=1; break; }; done
if [ "$_miss" = 1 ]; then          # 缺任一必要 key（含只 source 了 partial env）→ 載 bench.env
  _ENV="${BENCH_ENV:-$(dirname "$0" 2>/dev/null)/bench.env}"
  if [ -f "$_ENV" ]; then . "$_ENV"; else
    echo "✗ 缺 bench.env：cp bench.env.example bench.env 並填真值（見 README）" >&2
    return 1 2>/dev/null || exit 1
  fi
fi
for _k in $_need; do eval "[ -n \"\${$_k:-}\" ]" || { echo "✗ bench.env 缺必要 key：$_k" >&2; return 1 2>/dev/null || exit 1; }; done
LAN_MAC=$(ip link show "$LAN_IF" 2>/dev/null | awk '/link\/ether/{print toupper($2)}')

# ssh opts
DUT_CM=/tmp/ns_dut_cm_$$.sock
SSH_DUT="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 \
 -o LogLevel=ERROR -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa \
 -o ControlMaster=auto -o ControlPath=$DUT_CM -o ControlPersist=180"
SSH_GEN="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o LogLevel=ERROR"

cleanup(){ ssh $SSH_DUT -O exit root@$DUT 2>/dev/null; rm -f "$DUT_CM" 2>/dev/null; }
trap cleanup EXIT

# ----------------------------- node helpers -----------------------------
dut(){      ssh $SSH_DUT root@$DUT "$@" 2>/dev/null; }                              # DUT root（單一 master）
flybox(){   sshpass -p '' ssh $SSH_GEN root@$FLYBOX "$@" 2>/dev/null; }             # flybox root
pc2(){      sshpass -p "$PC2_LOGIN_PW" ssh $SSH_GEN $PC2_USER@$PC2 "$@" 2>/dev/null; }            # PC2 非 root
pc2root(){  sshpass -p "$PC2_LOGIN_PW" ssh $SSH_GEN $PC2_USER@$PC2 "echo '$PC2_ROOT_PW' | sudo -S -p '' $*" 2>/dev/null; }  # PC2 root（P-02）

# DM helpers（北向）
dm_get(){ dut "ubus call '$1' _get '{}'"; }                         # ubus call <Path> _get
dm_supported(){ dut "ubus call '$1' _get_supported '{\"parameters\":true}'"; }   # 查支援 param（避 P-12）
ipt(){ dut "iptables $* -n"; }                                     # 一律 -n（P-10）

# ENDPOINT 抓包：在 PC2 背景啟動 root tcpdump，輸出存本機檔；回傳後再觸發流量（P-07/P-08）
# 用法：pc2_capture <outfile> <secs> <pcap-filter...>
pc2_capture(){
  local out=$1 secs=$2; shift 2; local filt="$*"
  ( sshpass -p "$PC2_LOGIN_PW" ssh $SSH_GEN $PC2_USER@$PC2 \
      "timeout $secs sudo -n tcpdump -i $PC2_IF -n -c 50 $filt" \
      >"$out" 2>/dev/null ) &   # scoped sudo -n（不再 password-pipe，P-02）
  echo $!     # 回傳背景 PID，呼叫端 wait 它
}

# ----------------------------- result bookkeeping -----------------------------
PASS=0; FAIL=0; BLOCK=0; declare -a RESULTS
rec(){ local id=$1 st=$2; shift 2
  case $st in PASS)PASS=$((PASS+1));; FAIL)FAIL=$((FAIL+1));; BLOCK)BLOCK=$((BLOCK+1));; esac
  printf '  [%-5s] %-12s %s\n' "$st" "$id" "$*"; RESULTS+=("$id|$st|$*"); }
summary(){ echo; echo "==== PASS=$PASS FAIL=$FAIL BLOCK=$BLOCK ===="; }

# 確認 LAN→WAN host route 已強制穿 DUT（P-04）；沒有就 BLOCK 並列出 human 指令（P-06）
require_lan_route(){
  local dst=$1
  if ip route get "$dst" 2>/dev/null | grep -q "via $DUT dev $LAN_IF"; then return 0; fi
  rec "route-$dst" BLOCK "PC1→$dst 沒走 DUT（dual-homed 捷徑 P-04）。請 human 執行： sudo ip route add $dst via $DUT dev $LAN_IF"
  return 1
}

# ============================= preflight =============================
preflight(){
  echo "== Preflight =="
  for ip in $DUT $FLYBOX $PC2; do ping -c1 -W2 "$ip" >/dev/null 2>&1 \
     && rec "ping-$ip" PASS "reachable" || rec "ping-$ip" FAIL "UNREACHABLE"; done
  local osr; osr=$(dut 'cat /etc/os-release 2>/dev/null | sed -n "s/PRETTY_NAME=//p"')
  [ -n "$osr" ] && rec "dut-ssh" PASS "DUT root shell OK ($osr $(dut uname -r))" || rec "dut-ssh" FAIL "DUT ssh 進不去"
  local wan; wan=$(dut "ip -4 -o addr show $DUT_WAN_IF 2>/dev/null | awk '{print \$4}' | cut -d/ -f1")
  [ "$wan" = "${DUT_WAN%/*}" ] && rec "dut-wan" PASS "DUT WAN=$wan" || rec "dut-wan" FAIL "DUT WAN=$wan (expected $DUT_WAN)"
  local uid; uid=$(pc2root id 2>/dev/null)
  echo "$uid" | grep -q "uid=0" && rec "pc2-root" PASS "PC2 sudo OK" || rec "pc2-root" FAIL "PC2 提權失敗（密碼?P-02）"
  rec "lan-mac" PASS "PC1 LAN client MAC=$LAN_MAC"
  summary
  clockcheck     # P-48 時鐘漂移（資訊性，不計入 PASS/FAIL）
}

# ============================= 範例測項（已驗證 2026-06-05）=============================

# NS-MASQ：LAN client → WAN 的 source NAT 真的改了來源 IP（黃金標準：endpoint 觀測）
test_masq(){
  echo "== NS-MASQ: LAN→WAN masquerade 端到端 =="
  require_lan_route "$PC2" || { summary; return; }
  local cap=/tmp/ns_masq_$$.txt
  local pid; pid=$(pc2_capture "$cap" 10 "icmp")
  sleep 2                                   # 等 tcpdump 起來（standalone script 可 sleep）
  ping -c5 "$PC2" >/dev/null 2>&1
  wait "$pid" 2>/dev/null
  if grep -q "$DUT_WAN > $PC2" "$cap"; then
    rec "NS-MASQ" PASS "PC2 收到來源=$DUT_WAN（DUT 做了 SNAT，原始來源 $LAN_CLIENT_IP 被改寫）"
  elif grep -q "$LAN_CLIENT_IP > $PC2" "$cap"; then
    rec "NS-MASQ" FAIL "PC2 收到原始來源 $LAN_CLIENT_IP（NAT 沒生效！）"
  else
    rec "NS-MASQ" BLOCK "PC2 沒抓到 ICMP（route?tcpdump?觀測點?見 P-04/P-07/P-20）"
  fi
  echo "  evidence: $cap"; summary
}

# NS-WANIN：WAN ingress 預設 drop（安全姿態，P-19）——這是「預期通過」的負向測試
test_wan_ingress(){
  echo "== NS-WANIN: WAN ingress 預設 drop =="
  # 從 WAN 側（PC1-eth2 直連）ping DUT-WAN，應該不通
  if ping -I "$WAN_IF" -c2 -W2 "$DUT_WAN" >/dev/null 2>&1; then
    rec "NS-WANIN" FAIL "DUT-WAN 回應 WAN 側 ping（防火牆沒擋？需確認是否預期）"
  else
    rec "NS-WANIN" PASS "DUT-WAN 不回 WAN 側 ping（CPE 預設安全姿態，正確）"
  fi
  summary
}

# ═══════════ orchestrator-端 helper（P-29/55/58/60 + §8.3/8.5；2026-06-10 加）═══════════

# chain_audit — 死鏈/重複名鏈掃描 + DM-path 反查（P-55 曾害 REFUTED；P-61 rule comment=來源 DM）
chain_audit(){
  echo "== Chain integrity audit — 死鏈(P-55) + DM-path comment(P-61) =="
  local raw
  raw=$(dut 'for t in filter nat mangle raw; do iptables -w 5 -t "$t" -S 2>/dev/null | sed "s/^/$t /"; done')
  [ -z "$raw" ] && { echo "  ⚠ DUT iptables 無回應 → 先 ns_verify.sh guard 查 xtables.lock wedge(P-56)"; return 1; }
  printf '%s\n' "$raw" | awk '
    $2=="-P"{ live[$1 SUBSEP $3]=1; next }
    $2=="-N"{ decl[$1 SUBSEP $3]=1; tb[$1 SUBSEP $3]=$1; nm[$1 SUBSEP $3]=$3; next }
    $2=="-A"{ c=$1 SUBSEP $3; rules[c]++; for(i=4;i<=NF;i++) if($i=="-j"||$i=="-g") ref[$1 SUBSEP $(i+1)]++; next }
    END{
      for(k in decl) if(ref[k]>0) live[k]=1
      d=0
      for(k in decl){
        if(k in live) continue
        d++; r=(k in rules)?rules[k]:0
        if(nm[k] ~ /^FORWARD6?_L_/) printf "  ⚪ inactive-PolicyLevel [%s] %s (refs=0 rules=%d) — 非當前 active level，通常 benign\n", tb[k], nm[k], r
        else if(r>0) printf "  🔴 DEAD+RULES [%s] %s (refs=0 rules=%d) — rule 落死鏈永不命中\n", tb[k], nm[k], r
        else    printf "  🟡 dead-empty [%s] %s (refs=0)\n", tb[k], nm[k]
        for(j in live) if((j in nm) && nm[j]!=nm[k] && index(nm[j],nm[k])>0) printf "       ↳ twin-trap: live 鏈 %s 含同名片段 — 別把 rule 誤指死鏈\n", nm[j]
      }
      if(d==0) print "  ✅ 無 0-ref 死鏈"
    }'
  echo "  --- rule 的 DM-path comment（P-61 反查來源 DM；空=該 build 未帶）---"
  printf '%s\n' "$raw" | grep -oE '"(Firewall|NAT|QoS|Routing|DHCP)[^"]*"' | sort -u | sed 's/^/    /'
}

# verdict_gate <id> [p50=1] [p51=1] [p07=1] [p55=1] — 宣告 🔴 前強制勾 §8.3 四假陰排除
verdict_gate(){
  local id=${1:?need id}; shift; local p50=0 p51=0 p07=0 p55=0
  for kv in "$@"; do case $kv in p50=1)p50=1;; p51=1)p51=1;; p07=1)p07=1;; p55=1)p55=1;; esac; done
  echo "== verdict gate $id (§8.3) =="
  printf "  [%s] P-50 改設定後 fcctl flush\n"          "$([ $p50 = 1 ] && echo ✅ || echo ❌)"
  printf "  [%s] P-51 流量真穿 DUT(positive control)\n" "$([ $p51 = 1 ] && echo ✅ || echo ❌)"
  printf "  [%s] P-07 判定信端點、非 DUT 計數\n"        "$([ $p07 = 1 ] && echo ✅ || echo ❌)"
  printf "  [%s] P-55 看完整 -S + references\n"         "$([ $p55 = 1 ] && echo ✅ || echo ❌)"
  if [ $p50 = 1 ] && [ $p51 = 1 ] && [ $p07 = 1 ] && [ $p55 = 1 ]
  then echo "  → 四項全綠：可宣告 🔴 $id"; return 0
  else echo "  → ⛔ 缺項：禁止宣告 🔴 $id，退回補測"; return 1; fi
}

# cap <iface> <secs> <pcap-filter...> — PC2 tcpdump，-U 即時寫(P-58)
#   timeout/sudo 跑在 user，只有 tcpdump 走 sudo -n（scoped sudoers /etc/sudoers.d/10-bench-ns）
#   → 脫離 P-02 password-pipe（餵錯密碼 silent-fail）；timeout 不進 sudoers，避免 sudo-root-equivalent
cap(){ local i=$1 s=$2; shift 2; pc2 "timeout $s sudo -n tcpdump -i $i -U -nn -e -v -c 200 $*"; }
# cap_prep <iface> — 關 capture NIC offload，避免合包污染 per-packet 觀測(P-58)
cap_prep(){ pc2 "sudo -n ethtool -K $1 gro off gso off tso off lro off 2>/dev/null; sudo -n ethtool -k $1 | grep -E 'receive-offload|segmentation-offload'"; }

# tcp_reachable <ip> <port> — PC1 用 python3 socket 判可達(看實際 connect/banner，不信 nc \$?，P-29)
tcp_reachable(){
  python3 - "$1" "$2" <<'PY'
import socket,sys
ip,port=sys.argv[1],int(sys.argv[2])
s=socket.socket(); s.settimeout(4)
try:
    s.connect((ip,port))
    try: s.settimeout(2); b=s.recv(64)
    except Exception: b=b""
    print("OPEN  banner=%r"%(b[:48],)); sys.exit(0)
except Exception as e:
    print("CLOSED (%s)"%e); sys.exit(1)
PY
}

# guard — §8.5 pre-campaign guard：xtables.lock wedge / 殘留 probe / daemon / 殘留 gen 規則(P-56)
guard(){
  echo "== §8.5 pre-campaign guard (P-56) =="
  dut '
    echo "--- xtables.lock flock holder (應只有 radvd 等正常) ---"
    grep -i FLOCK /proc/locks 2>/dev/null | while read -r col typ knd mod pid rest; do
      echo "  pid=$pid -> $(readlink /proc/$pid/exe 2>/dev/null || cat /proc/$pid/comm 2>/dev/null)"
    done
    echo "--- iptables 即時回應? (wedge 偵測) ---"
    iptables -w 5 -nL INPUT >/dev/null 2>&1 && echo "  ✅ iptables OK (no wedge)" || echo "  🔴 iptables WEDGE — 照 P-56 優先 reboot 勿 SIGKILL"
    echo "--- 殘留 probe shell ---"
    ps -w 2>/dev/null | grep -E "(ash|sh) -c.*iptables" | grep -v grep || echo "  (無殘留 probe)"
    echo "--- firewall daemon ---"
    pgrep -af tr181-firewall | head -1
    echo "--- 殘留 gen 規則 (PortTrigger/StaticNAT 應空) ---"
    ubus call NAT _get 2>/dev/null | grep -iE "PortTriggerNumberOfEntries|StaticNAT" | head -3
  '
}

# pflow — 持久流 staleness 測法(P-60) 範式 + 現成指令(多 shell 協調，手動跑)
pflow(){
  cat <<'EOF'
== 持久流 staleness 測法 (P-60) — 抓 flow-cache 不 flush 的假陰 ==
per-invocation(每次新 5-tuple) 測不到；要單一持久流 + mid-stream 改 config：
  1) 起持久 offloaded 流(PC2-armB 穿 DUT)：
     pc2root "timeout 60 iperf3 -u -c <upstream-非本地IP> -p 5201 -b 50M -B <armB-IP>"
  2) 另一 shell 端點觀測舊值： ns_verify.sh cap eth0 6 "udp port 5201"
  3) mid-stream 改 config(不 flush) → cap 仍見舊值(stale)
  4) dut "fcctl flush" → cap 見新值
  配套：cap 已 -U(P-58)；判定信端點非 DUT 計數(P-07)。
EOF
}

# ═══════════ A 案新增（2026-06-12）：offload 黑箱 + 三層落地 + 時鐘漂移 ═══════════

# datapath [grep-pattern] — DUT flow-cache/offload 狀態快照（唯讀）
#   用途：改設定後「行為沒變」時，分辨「規則沒落地」vs「舊 flow 還在 HW 套舊決策」(P-38/P-50/P-62)
#   給 pattern（如 "<DUT-WAN-IP>" 或 "dport=9999"）只看該 5-tuple 在 HW/SW
datapath(){
  local pat="${1:-}"
  echo "== DUT datapath / flow-cache snapshot (P-38/50/62) =="
  dut '
    echo "--- fcctl status (active flows / idle-timer / evict) ---"
    fcctl status 2>/dev/null | sed -n "1,40p" || echo "  (fcctl status n/a)"
    echo "--- /proc/fcache/stats/path (active_flows / sw_pkt_count / hw_pkt_count) ---"
    cat /proc/fcache/stats/path 2>/dev/null || echo "  (n/a)"
    echo "--- /proc/fcache/stats/evict (flow 怎麼被拆 tcp_fin/idle) ---"
    cat /proc/fcache/stats/evict 2>/dev/null || echo "  (n/a)"
    echo "--- conntrack accel 標記 (hwaccel=2 Runner fast-path / 0 slow-path, P-62) ---"
    cat /proc/net/nf_conntrack 2>/dev/null | grep -oE "(sw|hw)accel=[0-9]+" | sort | uniq -c || echo "  (n/a)"
  '
  if [ -n "$pat" ]; then
    echo "--- nflist + conntrack 過濾 '$pat'（該 flow 在 HW 還 SW?）---"
    dut "echo '  [/proc/fcache/nflist]'; cat /proc/fcache/nflist 2>/dev/null | grep -i '$pat'; echo '  [nf_conntrack]'; cat /proc/net/nf_conntrack 2>/dev/null | grep -i '$pat'"
  else
    echo "--- /proc/fcache/nflist 前 20 筆（active offloaded flows）---"
    dut 'cat /proc/fcache/nflist 2>/dev/null | head -20 || echo "  (n/a)"'
  fi
  echo "  → 既有 flow 還在 nflist/hwaccel=2 = 套舊決策(stale)：dut \"fcctl flush\" 後再驗(P-50)；判定仍認端點(P-07)"
}

# l3verify <id> <dm-path> <chain> — P-22 三層落地一次收齊（DM≠iptables≠封包）
#   例：l3verify <id> "Firewall.Chain.[Name=='<chain-name>']" <iptables-chain>
#   例：l3verify <id> NAT.PortMapping.1 PREROUTING_PortForwarding
#   層①②自動跑（唯讀）；層③行為是 item-specific，印 recipe + 提醒 verdict_gate
l3verify(){
  local id=${1:?need id} dmp=${2:?need DM path} chain=${3:?need chain}
  echo "== l3verify $id — P-22 三層 (層①北向DM ≠ 層②南向iptables ≠ 層③封包) =="

  echo "--- 層① 北向 DM ($dmp) ---"
  # 先試 ubus（concrete path 回 JSON）；空則 ba-cli（search-expr，ubus 不解析 search-expr，P-11）
  # 雙引號包 path 讓內含的單引號變字面，避 P-33 單引號地獄；去掉 ba-cli 的互動 echo 行(^>)
  local l1; l1=$(dut "ubus call \"$dmp\" _get '{}'")
  [ -z "$l1" ] && l1=$(dut "ba-cli \"${dmp}.?\"" | grep -vE '^>')
  [ -z "$l1" ] && l1=$(dut "ba-cli \"${dmp}?\"" | grep -vE '^>')
  if [ -n "$l1" ]; then printf '%s\n' "$l1" | sed -n '1,30p' | sed 's/^/    /'
  else echo "  🟡 DM 查不到 — path? 手動跑 ba-cli \"${dmp}.?\" 解析（R4 discovery / P-33）"; fi

  echo "--- 層② 南向 iptables ($chain) + references ---"
  local l2 refs
  l2=$(dut 'for t in filter nat mangle raw; do r=$(iptables -w 5 -t $t -S '"$chain"' 2>/dev/null); [ -n "$r" ] && printf "[table=%s]\n%s\n" "$t" "$r"; done')   # -S 不吃 -n
  if [ -z "$l2" ]; then
    echo "  🔴 鏈 $chain 全表無回應/不存在 — 可能落死鏈 or wedge：跑 chain-audit / guard(P-56)"
  else
    printf '%s\n' "$l2" | sed 's/^/    /'
    refs=$(dut 'for t in filter nat mangle raw; do iptables -w 5 -t $t -S 2>/dev/null; done' | grep -cE -- "-(j|g) $chain(\$|[[:space:]])")
    if [ "${refs:-0}" -gt 0 ]; then echo "  references(被 -j/-g 指向)=$refs ✅ 被遍歷"
    else echo "  references=0 🔴 0-ref 死鏈/未掛載 → rule 在但永不命中(P-55)"; fi
  fi

  echo "--- 層③ 行為（端點 write-test，item-specific，照 §8.3）---"
  echo "    端點抓包  : ns_verify.sh cap <if> <secs> '<filter>'   （pcap 用 -U / 文字用 -l，P-58/64）"
  echo "    可達/banner: ns_verify.sh reach <ip> <port>           （不信 nc \$?，P-29）"
  echo "    DSCP 讀值 : 端點 IP_RECVTOS 讀 tos / 或 cap 抓包看 tos      （QoS marking 驗證）"
  echo "    offload   : ns_verify.sh datapath '<5-tuple>'         （改設定後 dut \"fcctl flush\"，P-50/07）"
  echo "--- 宣告 verdict 前跑 §8.3 gate ---"
  echo "    source ns_verify.sh; verdict_gate $id p50=1 p51=1 p07=1 p55=1"
}

# clockcheck [threshold-s] — 各 node UTC 時鐘漂移（P-48 scheduler 用 UTC 判排程窗）
clockcheck(){
  local thr=${1:-5}
  echo "== clockcheck — node 時鐘漂移 (P-48, threshold=${thr}s) =="
  local ref now utc drift ad
  ref=$(date -u +%s)
  printf '  %-8s %s  (UTC %s)  [ref]\n' "PC1" "$ref" "$(date -u '+%H:%M:%S')"
  for n in DUT flybox PC2; do
    case $n in
      DUT)    now=$(dut 'date -u +%s');    utc=$(dut "date -u '+%H:%M:%S'") ;;
      flybox) now=$(flybox 'date -u +%s'); utc=$(flybox "date -u '+%H:%M:%S'") ;;
      PC2)    now=$(pc2 'date -u +%s');    utc=$(pc2 "date -u '+%H:%M:%S'") ;;
    esac
    if [ -z "$now" ]; then printf '  %-8s (取時間失敗：節點不可達?)\n' "$n"; continue; fi
    drift=$(( now - ref )); ad=${drift#-}
    printf '  %-8s %s  (UTC %s)  drift=%+ds %s\n' "$n" "$now" "$utc" "$drift" \
      "$([ "$ad" -le "$thr" ] && echo ✅ || echo "🔴 >${thr}s — scheduler/排程窗會偏(P-48)")"
  done
  echo "  caveat：含 ssh RTT(~<1s) 誤差；DUT chronyd 在跑、PC1(WSL)/PC2/flybox 漂移才是重點"
}

# ----------------------------- dispatch -----------------------------
# 只在「直接執行」時跑 dispatch；被 `source` 時只載入 helper（README 推薦用法）
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
case "${1:-help}" in
  preflight) preflight ;;
  masq) preflight; test_masq ;;
  wan_ingress) test_wan_ingress ;;
  chain-audit) chain_audit ;;
  guard) guard ;;
  cap) shift; cap "$@" ;;
  cap-prep) shift; cap_prep "$@" ;;
  reach) shift; tcp_reachable "$@" ;;
  pflow) pflow ;;
  datapath) shift; datapath "$@" ;;
  l3verify) shift; l3verify "$@" ;;
  clockcheck) shift; clockcheck "$@" ;;
  help|*) sed -n '3,29p' "$0" ;;
esac
fi
