#!/bin/sh
# pc2_lan_netns.sh — 把 armB（DUT LAN 臂）隔離進獨立 netns，物理強制穿 DUT（結構性消滅 P-51）
#
#   背景（見 methodology P-51）：observer 雙臂同主機，armB→armA(observer 本地 IP) 等「本地 IP」
#   會走 kernel local delivery、根本不穿 DUT，NAT 沒驗到。SO_BINDTODEVICE 只約束出介面、
#   不阻止本地投遞。舊解靠 host-route + WAN 對端改上游非本地 IP + conntrack positive control。
#   本 helper：把 armB 物理 NIC move 進 netns `lanns` → netns 內 routing table 隔離、
#   **根本沒有 armA 的 observer IP 這個 local address** → 送往它的封包必照 netns default route 穿 DUT。
#
#   ⚠️ 只動 armB（$ARMB_IF）。armA（$ARMA_IF=$ARMA_IP）=SSH 命脈，絕不碰。
#   ⚠️ 在 observer 上以 root 跑：sudo sh pc2_lan_netns.sh {up|down|status|test|exec <cmd...>}
#   netns 非持久：observer reboot 後消失，重跑 up 即可。
#
#   以 armB 身分跑任何指令（取代舊的 pc2root "... -B <armB-IP>"）：
#     sudo sh pc2_lan_netns.sh exec iperf3 -c <upstream-非本地IP> -p 5201
#     sudo sh pc2_lan_netns.sh exec ping -c3 <observer-本地IP>   # 任何本地 IP 現在都穿 DUT
set -u

NS=lanns
# 真值從 bench.env 讀（部署到 observer 時連 bench.env 一起帶；未提供則報錯停）
[ -f "${BENCH_ENV:-$(dirname "$0")/bench.env}" ] && . "${BENCH_ENV:-$(dirname "$0")/bench.env}"
IF=${ARMB_IF:?在 bench.env 設 ARMB_IF（armB DUT-LAN 臂 iface，非 observer 命脈）}
IF_MAC=${ARMB_MAC:?在 bench.env 設 ARMB_MAC（guard 二次核對防搬錯卡）}
ARMB_IP=${ARMB_IP:-192.168.1.3}
ARMB_CIDR=$ARMB_IP/24
GW=${DUT:-192.168.1.1}                       # DUT LAN gateway
ARMA_IF=${ARMA_IF:?在 bench.env 設 ARMA_IF（observer SSH 命脈 iface，guard 拒絕）}
ARMA_IP=${ARMA_IP:?在 bench.env 設 ARMA_IP（observer SSH 命脈 IP）}
NM_CON="${ARMB_NM_CON:-Wired connection 2}"  # armB 的 NM 連線（回復用）

die(){ echo "FATAL: $*" >&2; exit 1; }

guard(){
  # 三重防呆（守住 SSH 命脈 armA，codex review #2）：
  # (1) 明確拒絕 IF=armA 介面名
  [ "$IF" = "$ARMA_IF" ] && die "IF=$ARMA_IF 是 armA/SSH 命脈，拒絕執行。"
  # (2) IF 不可帶 armA 的 IP
  ip -o -4 addr show "$IF" 2>/dev/null | grep -qw "$ARMA_IP" \
    && die "$IF 帶 $ARMA_IP (armA/SSH 命脈)！iface 傳錯，拒絕執行。"
  # (3) IF 的 MAC 必須是 armB（IF 還在 host 看得到才驗；已在 netns 時 cur_mac 空→跳過）
  cur_mac=$(ip -o link show "$IF" 2>/dev/null | sed -n 's/.*link\/ether \([0-9a-f:]*\).*/\1/p')
  [ -n "$cur_mac" ] && [ "$cur_mac" != "$IF_MAC" ] \
    && die "$IF MAC=$cur_mac ≠ 預期 armB $IF_MAC，拒絕執行（防搬錯卡）。"
  return 0
}

# 冪等補齊 netns 內設定（v4 addr / default route / offload / accept_ra），可重複呼叫自癒（codex #3）
ensure_cfg(){
  ip netns exec "$NS" ip -4 addr show "$IF" 2>/dev/null | grep -qw "$ARMB_IP" \
    || ip netns exec "$NS" ip addr add "$ARMB_CIDR" dev "$IF" || die "配 $ARMB_CIDR 失敗"
  ip netns exec "$NS" ip route show default 2>/dev/null | grep -qw "$GW" \
    || ip netns exec "$NS" ip route add default via "$GW" dev "$IF" || die "配 default route 失敗"
  ip netns exec "$NS" ethtool -K "$IF" gro off gso off tso off 2>/dev/null \
    || echo "  ⚠ ethtool offload 設定異常（P-58 capture 保真可能受影響）" >&2
  ip netns exec "$NS" sysctl -qw net.ipv6.conf."$IF".accept_ra=2 2>/dev/null || true
}

up(){
  guard
  if ip netns list 2>/dev/null | grep -qw "$NS" && ip netns exec "$NS" ip link show "$IF" >/dev/null 2>&1; then
    echo "[up] netns $NS 已存在且 $IF 已在其中（idempotent：驗證並補齊設定）"
    ip netns exec "$NS" ip link set "$IF" up || die "$IF up 失敗"
    ensure_cfg            # codex #3：補齊 addr/route/offload/RA，修復前次半失敗
    status; return 0
  fi
  echo "[up] 1) NM 放手 $IF"
  nmcli device set "$IF" managed no 2>/dev/null || true
  echo "[up] 2) 建 netns $NS"
  ip netns add "$NS" 2>/dev/null || true
  ip netns exec "$NS" ip link set lo up
  echo "[up] 3) move 物理 NIC $IF 進 netns（會清掉原 IP/route）"
  ip link set "$IF" netns "$NS" || die "move $IF 進 netns 失敗（codex #1 fail-fast）"
  echo "[up] 4) netns 內配 v4 static + SLAAC v6（+ P-58 capture 保真）"
  ip netns exec "$NS" ip link set "$IF" up || die "$IF up 失敗"
  ip netns exec "$NS" sysctl -qw net.ipv6.conf."$IF".disable_ipv6=0 2>/dev/null || true
  ensure_cfg            # v4 addr + default route + offload + accept_ra（失敗即 die）
  # 主動送 RS 加速 SLAAC（有 rdisc6 就用，沒有就等 kernel 週期 RA）
  command -v rdisc6 >/dev/null 2>&1 && ip netns exec "$NS" rdisc6 -1 "$IF" >/dev/null 2>&1 || true
  echo "[up] done. （v6 SLAAC 可能需幾秒成形）"
  status
}

down(){
  if ip netns list 2>/dev/null | grep -qw "$NS"; then
    # codex #5：netns 內若有 process hold，del 只刪名字、NIC 會困匿名 netns → 先警示
    pids=$(ip netns pids "$NS" 2>/dev/null)
    [ -n "$pids" ] && echo "  ⚠ netns $NS 內仍有 process（pid: $pids），先確認再續" >&2
    echo "[down] 1) 把 $IF 移回 host netns"
    ip netns exec "$NS" ip link set "$IF" netns 1 2>/dev/null \
      || die "把 $IF 移回 host 失敗 → 拒絕 netns del（避免 NIC 困匿名 netns，codex #5）"
    ip link show "$IF" >/dev/null 2>&1 || die "$IF 未出現在 host（移回異常），中止 del"
    ip netns del "$NS" 2>/dev/null || true
  else
    echo "[down] netns $NS 不存在，僅確保 $IF 在 host"
  fi
  ip link set "$IF" up 2>/dev/null || true
  echo "[down] 2) NM 收回管理 + 重新拉起連線（autoconnect 應自動 DHCP 復原 .3）"
  nmcli device set "$IF" managed yes 2>/dev/null || true
  nmcli con up "$NM_CON" 2>/dev/null || echo "  ⚠ nmcli con up '$NM_CON' 失敗（連線名變了?）" >&2
  # codex #4：等 DHCP 並 assert .3（bench contract），失敗 loud
  i=0; while [ $i -lt 10 ]; do ip -4 addr show "$IF" 2>/dev/null | grep -qw "$ARMB_IP" && break; i=$((i+1)); sleep 1; done
  echo "[down] 復原後 $IF："; ip -br addr show "$IF"
  if ip -4 addr show "$IF" 2>/dev/null | grep -qw "$ARMB_IP"; then
    echo "  ✅ $IF 已復原 $ARMB_IP"
  else
    echo "  🔴 $IF 未復原到 $ARMB_IP！手動檢查：nmcli con up '$NM_CON' 或 dhclient $IF" >&2
    exit 1
  fi
}

status(){
  echo "== netns 列表 =="
  ip netns list | grep -w "$NS" || echo "  ($NS 不存在 → 跑 up)"
  if ip netns list 2>/dev/null | grep -qw "$NS"; then
    echo "== $NS 內 $IF 位址 =="; ip netns exec "$NS" ip -br addr show "$IF" 2>/dev/null
    echo "== $NS v4 路由 =="; ip netns exec "$NS" ip route 2>/dev/null
    echo "== $NS v6 default 路由 =="; ip netns exec "$NS" ip -6 route show default 2>/dev/null || echo "  (尚無 v6 default)"
  fi
  echo "== armA 仍在 host？(必須 UP $ARMA_IP，SSH 命脈) =="
  ip -br addr show "$ARMA_IF"
  echo "== armB 位置（三態）=="
  if ip netns exec "$NS" ip -br link show "$IF" >/dev/null 2>&1; then
    echo "  ✅ $IF 在 netns $NS（已隔離，正確）"
  elif ip -br link show "$IF" >/dev/null 2>&1; then
    echo "  ⚠ $IF 仍在 host netns（未隔離 → 跑 up）"
  else
    echo "  ⚠ $IF 兩邊都找不到（iface 名錯？檢查 bench.env 的 ARMB_IF）"
  fi
}

# P-51 結構性消滅證明：netns 內 armB ping armA 的本地 IP（observer IP）
#  舊 workaround 下這會 local 短路、不穿 DUT；netns 內該 IP 非本地 → 必穿 DUT NAT。
#  decisive：在 armA(host) 抓包，src 必為 DUT-WAN post-NAT IP，非 armB IP。
test(){
  if ! ip netns list 2>/dev/null | grep -qw "$NS"; then echo "netns $NS 不存在，先跑 up"; return 1; fi
  CAP=/tmp/armA_p51_cap.txt
  echo "== [P-51 proof] 在 armA($ARMA_IF) 抓 icmp，同時 netns armB ping $ARMA_IP(本地IP) =="
  ( timeout 6 tcpdump -i "$ARMA_IF" -nn -c 6 "icmp and host $ARMA_IP" >"$CAP" 2>/dev/null ) &
  TPID=$!
  sleep 1
  ip netns exec "$NS" ping -c3 -W2 -I "$IF" "$ARMA_IP"
  wait $TPID 2>/dev/null
  echo "--- armA($ARMA_IF) 抓到的封包 ---"
  cat "$CAP"
  echo "--- 判讀 ---"
  if grep -q "$DUT_WAN > $ARMA_IP" "$CAP"; then
    echo "  ✅ src=$DUT_WAN (DUT-WAN post-NAT) → 封包真穿 DUT NAT。P-51 結構性消滅。"
  elif grep -q "$ARMB_IP > $ARMA_IP" "$CAP"; then
    echo "  🔴 src=$ARMB_IP → 仍短路、沒穿 DUT（netns 未生效?）"
  else
    echo "  ⚠ armA 沒抓到 → 檢查 ping 是否通 / DUT NAT / 抓包窗"
  fi
}

case "${1:-status}" in
  up) up ;;
  down) down ;;
  status) status ;;
  test) test ;;
  exec) shift; ip netns exec "$NS" "$@" ;;   # 以 armB 身分跑（穿 DUT 保證）
  *) echo "用法: sudo sh $0 {up|down|status|test|exec <cmd...>}"; exit 1 ;;
esac
