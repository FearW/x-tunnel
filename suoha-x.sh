#!/usr/bin/env bash
set -euo pipefail
# =========================
# suoha x-tunnel FINAL
# - Quick Tunnel (trycloudflare) + Named Tunnel (bind domain)
# - Auto self-check / debug
# - 新增：菜单选项 4.域名绑定查看（查看当前保存的临时域名、绑定域名、端口等信息，并自检）
# - 新增：停止服务/清空缓存时自动删除配置文件
# =========================

CONFIG_FILE="${HOME}/.suoha_tunnel_config"
WG_PROFILE_DIR="${HOME}/.suoha_wg_profiles"

# 传输优化默认参数（可在交互中覆盖）
cf_protocol="quic"        # quic 在大多数网络下延迟更低、抗抖动更好
cf_ha_connections="4"     # 并发隧道连接数，提升吞吐上限
cf_profile="2"            # 1=稳定优先 2=速度优先(默认) 3=高吞吐优先
net_tuned="0"            # 0=未优化 1=已尝试应用系统网络优化
landing_mode="0"         # 0=直连 1=http 2=socks5 3=wireguard
forward_url=""
wg_socks_port=""

linux_os=("Debian" "Ubuntu" "CentOS" "Fedora" "Alpine")
linux_update=("apt update" "apt update" "yum -y update" "yum -y update" "apk update")
linux_install=("apt -y install" "apt -y install" "yum -y install" "yum -y install" "apk add -f")
# ------------- helpers -------------
say(){ printf "%s\n" "$*"; }
os_index(){
  local n=0
  local pretty
  pretty="$(grep -i PRETTY_NAME /etc/os-release | cut -d '"' -f2 | awk '{print $1}' || true)"
  for i in "${linux_os[@]}"; do
    if [[ "$i" == "$pretty" ]]; then
      echo "$n"
      return
    fi
    n=$((n+1))
  done
  echo "当前系统$(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2)没有适配"
  echo "默认使用APT包管理器"
  echo 0
}
need_cmd(){
  local cmd="$1" idx="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    ${linux_update[$idx]} >/dev/null 2>&1 || true
    ${linux_install[$idx]} "$cmd" >/dev/null 2>&1 || true
  fi
}
get_free_port() {
  while true; do
    local PORT=$((RANDOM % 64512 + 1024))
    if command -v ss >/dev/null 2>&1; then
      if ! ss -lnt | awk '{print $4}' | grep -qE ":${PORT}$"; then
        echo "$PORT"; return
      fi
    else
      if command -v lsof >/dev/null 2>&1; then
        if ! lsof -i TCP:"$PORT" >/dev/null 2>&1; then
          echo "$PORT"; return
        fi
      else
        echo "$PORT"; return
      fi
    fi
  done
}
stop_screen(){
  local name="$1"
  screen -S "$name" -X quit >/dev/null 2>&1 || true
  for _ in $(seq 1 10); do
    if ! screen -list 2>/dev/null | grep -q "\.${name}[[:space:]]"; then
      return
    fi
    sleep 1
  done
}
download_bin(){
  local url="$1" out="$2"
  if [[ ! -f "$out" ]]; then
    curl -fsSL "$url" -o "$out"
  fi
}
detect_ws_port(){
  ss -lntp 2>/dev/null | awk '/x-tunnel-linux/ && /127\.0\.0\.1:/ {print $4}' | sed -E 's/.*:([0-9]+)$/\1/' | head -n1
}
http_head(){
  local host="$1"
  curl -I "https://${host}" 2>/dev/null | sed -n '1,8p' || true
}
tcp_check(){
  local host="$1"
  if command -v nc >/dev/null 2>&1; then
    nc -vz "$host" 443 || true
  fi
}
tls_check(){
  local host="$1"
  if command -v openssl >/dev/null 2>&1; then
    echo | openssl s_client -connect "${host}:443" -servername "${host}" 2>/dev/null | sed -n '1,12p' || true
  fi
}
self_check(){
  local bind_domain="${1:-}"
  local try_domain="${2:-}"
  local wsport="${3:-}"
  echo
  say "=============================="
  say "自检 / Debug"
  say "=============================="
  say "screen sessions:"
  screen -list 2>/dev/null || true
  echo
  if [[ -z "$wsport" ]]; then
    wsport="$(detect_ws_port || true)"
  fi
  if [[ -n "$wsport" ]]; then
    say "[OK] 本地监听: 127.0.0.1:${wsport}"
    ss -lntp 2>/dev/null | grep -E "127\.0\.0\.1:${wsport}\b" || true
  else
    say "[FAIL] 未检测到 x-tunnel 本地监听端口"
  fi
  echo
  if [[ -n "$bind_domain" ]]; then
    say "== 绑定域名检测: ${bind_domain} =="
    tcp_check "$bind_domain"
    tls_check "$bind_domain"
    http_head "$bind_domain"
    echo
  fi
  if [[ -n "$try_domain" ]]; then
    say "== 临时域名检测: ${try_domain} =="
    tcp_check "$try_domain"
    tls_check "$try_domain"
    http_head "$try_domain"
    echo
  fi
  cat <<EOF
解释：
- 401 Unauthorized：正常！说明已到达 x-tunnel，但需要 token（你设的 token）。
- 200 OK：也可能正常（HEAD/探测请求），请用客户端带 token 真正连接测试。
- 502 Bad Gateway：Cloudflare 连不到本地服务（端口/协议/路由类型不匹配）。
- 530：被 Cloudflare Access/应用策略拦截（到 Zero Trust → Access → Applications 处理）。
若绑定域名失败但临时域名可用：
- 优先检查 Cloudflare Public Hostname 指向是否是 http://127.0.0.1:${wsport}（强烈建议固定端口）
- 确认同一个 hostname 没有多条冲突路由
EOF
}

apply_system_net_tuning(){
  local conf_file="/etc/sysctl.d/99-suoha-tunnel.conf"

  if [[ "$(id -u)" != "0" ]]; then
    say "[WARN] 当前不是 root，跳过系统层网络优化（BBR+FQ）"
    return
  fi

  if command -v modprobe >/dev/null 2>&1; then
    modprobe tcp_bbr >/dev/null 2>&1 || true
  fi

  cat > "$conf_file" <<EOF
# managed by suoha-x.sh
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 33554432
net.ipv4.tcp_wmem=4096 65536 33554432
net.ipv4.tcp_fastopen=3
EOF

  sysctl --system >/dev/null 2>&1 || true

  local current_cc current_qdisc
  current_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  current_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"

  say "系统网络优化结果: tcp_congestion_control=${current_cc:-unknown}, default_qdisc=${current_qdisc:-unknown}"
  if [[ "$current_cc" == "bbr" && "$current_qdisc" == "fq" ]]; then
    say "[OK] 已启用 BBR + FQ"
  else
    say "[WARN] 内核可能不支持完整 BBR+FQ，请检查内核版本或宿主机限制"
  fi
}

save_config(){
  {
    echo "wsport=${wsport:-}"
    echo "metricsport=${metricsport:-}"
    echo "try_domain=${TRY_DOMAIN:-}"
    echo "bind_enable=${bind_enable:-0}"
    echo "bind_domain=${bind_domain:-}"
    echo "token=${token:-}"
    echo "cf_protocol=${cf_protocol:-quic}"
    echo "cf_ha_connections=${cf_ha_connections:-4}"
    echo "cf_profile=${cf_profile:-2}"
    echo "net_tuned=${net_tuned:-0}"
    echo "landing_mode=${landing_mode:-0}"
    echo "wg_socks_port=${wg_socks_port:-}"
  } > "$CONFIG_FILE"
}

load_config(){
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    return 0
  else
    return 1
  fi
}

remove_config(){
  rm -f "$CONFIG_FILE"
}
# ------------- core -------------

wg_profile_path(){
  local name="$1"
  local safe
  safe="$(echo "$name" | tr -cs 'A-Za-z0-9._-' '_')"
  echo "${WG_PROFILE_DIR}/${safe}.conf"
}

save_wg_profile(){
  local name="$1" path
  mkdir -p "$WG_PROFILE_DIR"
  path="$(wg_profile_path "$name")"
  cat > "$path" <<EOF
wg_private_key=${wg_private_key}
wg_address=${wg_address}
wg_dns=${wg_dns}
wg_peer_public_key=${wg_peer_public_key}
wg_preshared_key=${wg_preshared_key}
wg_endpoint=${wg_endpoint}
wg_allowed_ips=${wg_allowed_ips}
EOF
  chmod 600 "$path" || true
  say "[OK] 已保存WG配置: $path"
}

list_wg_profiles(){
  if [[ -d "$WG_PROFILE_DIR" ]]; then
    find "$WG_PROFILE_DIR" -maxdepth 1 -type f -name '*.conf' -printf '%f\n' 2>/dev/null | sed 's/\.conf$//' || true
  fi
}

load_wg_profile(){
  local name="$1" path
  path="$(wg_profile_path "$name")"
  if [[ ! -f "$path" ]]; then
    say "[FAIL] 未找到WG配置: $name"
    return 1
  fi
  # shellcheck source=/dev/null
  source "$path"
  return 0
}

collect_wg_inputs(){
  read -r -p "请输入WG接口私钥(PrivateKey):" wg_private_key
  read -r -p "请输入WG地址(如10.0.0.2/32):" wg_address
  read -r -p "请输入WG DNS(默认1.1.1.1):" wg_dns
  wg_dns="${wg_dns:-1.1.1.1}"
  read -r -p "请输入Peer公钥(PublicKey):" wg_peer_public_key
  read -r -p "请输入Peer预共享密钥(PresharedKey,可留空):" wg_preshared_key
  read -r -p "请输入Peer端点(Endpoint, 如1.2.3.4:51820):" wg_endpoint
  read -r -p "请输入AllowedIPs(默认0.0.0.0/0,::/0):" wg_allowed_ips
  wg_allowed_ips="${wg_allowed_ips:-0.0.0.0/0,::/0}"

  read -r -p "是否保存该WG配置供后续热切换使用(1.是,0.否,默认1):" save_wg
  save_wg="${save_wg:-1}"
  if [[ "$save_wg" == "1" ]]; then
    read -r -p "请输入WG配置名(如 hk-wg):" wg_profile_name
    if [[ -n "${wg_profile_name:-}" ]]; then
      save_wg_profile "$wg_profile_name"
    fi
  fi
}

start_wg_landing(){
  local arch wireproxy_bin use_saved wg_profile_name existing_profiles
  arch="$(uname -m)"
  case "$arch" in
    x86_64|x64|amd64) wireproxy_bin="wireproxy-linux-amd64" ;;
    i386|i686) wireproxy_bin="wireproxy-linux-386" ;;
    armv8|arm64|aarch64) wireproxy_bin="wireproxy-linux-arm64" ;;
    *)
      say "当前架构${arch}不支持 wireguard 落地"
      return 1
      ;;
  esac

  download_bin "https://github.com/pufferffish/wireproxy/releases/latest/download/${wireproxy_bin}" "wireproxy-linux"
  chmod +x wireproxy-linux

  existing_profiles="$(list_wg_profiles || true)"
  if [[ -n "$existing_profiles" ]]; then
    say "检测到已保存WG配置："
    printf '%s\n' "$existing_profiles"
    read -r -p "是否使用已保存WG配置(1.是,0.否,默认1):" use_saved
    use_saved="${use_saved:-1}"
  else
    use_saved="0"
  fi

  if [[ "$use_saved" == "1" ]]; then
    read -r -p "请输入WG配置名:" wg_profile_name
    if ! load_wg_profile "$wg_profile_name"; then
      say "改为手动输入WG参数"
      collect_wg_inputs
    fi
  else
    collect_wg_inputs
  fi

  wg_socks_port="$(get_free_port)"
  cat > wireproxy.conf <<EOF
[Interface]
PrivateKey = ${wg_private_key}
Address = ${wg_address}
DNS = ${wg_dns}

[Peer]
PublicKey = ${wg_peer_public_key}
AllowedIPs = ${wg_allowed_ips}
Endpoint = ${wg_endpoint}
PersistentKeepalive = 25
EOF
  if [[ -n "${wg_preshared_key:-}" ]]; then
    printf 'PresharedKey = %s\n' "$wg_preshared_key" >> wireproxy.conf
  fi
  cat >> wireproxy.conf <<EOF

[Socks5]
BindAddress = 127.0.0.1:${wg_socks_port}
EOF

  stop_screen wg
  screen -dmUS wg ./wireproxy-linux -c wireproxy.conf
  sleep 1
  if ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE ":${wg_socks_port}$"; then
    forward_url="socks5://127.0.0.1:${wg_socks_port}"
    say "[OK] WG落地已启动，本地Socks5: 127.0.0.1:${wg_socks_port}"
    return 0
  fi

  say "[FAIL] WG落地启动失败，请检查参数"
  return 1
}

landing_mode_text(){
  case "${1:-0}" in
    1) echo "HTTP" ;;
    2) echo "SOCKS5" ;;
    3) echo "WG" ;;
    *) echo "直连" ;;
  esac
}

configure_landing(){
  say "落地模式：0.直连[默认] 1.HTTP落地 2.SOCKS5落地 3.WG落地"
  read -r -p "请选择落地模式:" landing_mode
  landing_mode="${landing_mode:-0}"
  forward_url=""

  case "$landing_mode" in
    0)
      ;;
    1)
      read -r -p "请输入HTTP落地地址(host:port):" proxy_hostport
      if [[ -z "${proxy_hostport:-}" ]]; then
        say "HTTP落地地址不能为空，回退直连"
        landing_mode="0"
      else
        read -r -p "请输入HTTP用户名(可留空):" proxy_user
        if [[ -n "$proxy_user" ]]; then
          read -r -p "请输入HTTP密码:" proxy_pass
          forward_url="http://${proxy_user}:${proxy_pass}@${proxy_hostport}"
        else
          forward_url="http://${proxy_hostport}"
        fi
      fi
      ;;
    2)
      read -r -p "请输入SOCKS5落地地址(host:port):" proxy_hostport
      if [[ -z "${proxy_hostport:-}" ]]; then
        say "SOCKS5落地地址不能为空，回退直连"
        landing_mode="0"
      else
        read -r -p "请输入SOCKS5用户名(可留空):" proxy_user
        if [[ -n "$proxy_user" ]]; then
          read -r -p "请输入SOCKS5密码:" proxy_pass
          forward_url="socks5://${proxy_user}:${proxy_pass}@${proxy_hostport}"
        else
          forward_url="socks5://${proxy_hostport}"
        fi
      fi
      ;;
    3)
      start_wg_landing || {
        say "WG落地初始化失败，自动回退到直连"
        landing_mode="0"
      }
      ;;
    *)
      say "未识别落地模式，使用直连"
      landing_mode="0"
      ;;
  esac
}

start_x_tunnel_service(){
  local x_args=( -l "ws://127.0.0.1:${wsport}" )
  if [[ -n "${token:-}" ]]; then
    x_args+=( -token "$token" )
  fi
  if [[ -n "${forward_url:-}" ]]; then
    x_args+=( -f "$forward_url" )
  fi
  screen -dmUS x-tunnel ./x-tunnel-linux "${x_args[@]}"
}

hot_switch_landing(){
  if ! load_config; then
    say "未找到运行配置，无法热切换，请先启动(选项1)"
    return
  fi

  if [[ -z "${wsport:-}" ]]; then
    wsport="$(detect_ws_port || true)"
  fi
  if [[ -z "${wsport:-}" ]]; then
    say "未检测到x-tunnel监听端口，无法热切换"
    return
  fi

  say "当前落地模式: $(landing_mode_text "${landing_mode:-0}")"
  configure_landing

  if [[ "${landing_mode:-0}" != "3" ]]; then
    stop_screen wg
  fi

  stop_screen x-tunnel
  start_x_tunnel_service
  save_config

  say "[OK] 热切换完成，当前落地模式: $(landing_mode_text "${landing_mode:-0}")"
  self_check "${bind_domain:-}" "${try_domain:-}" "${wsport:-}"
}

quicktunnel(){
  case "$(uname -m)" in
    x86_64|x64|amd64)
      download_bin "https://www.baipiao.eu.org/xtunnel/x-tunnel-linux-amd64" "x-tunnel-linux"
      download_bin "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" "cloudflared-linux"
      ;;
    i386|i686)
      download_bin "https://www.baipiao.eu.org/xtunnel/x-tunnel-linux-386" "x-tunnel-linux"
      download_bin "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-386" "cloudflared-linux"
      ;;
    armv8|arm64|aarch64)
      download_bin "https://www.baipiao.eu.org/xtunnel/x-tunnel-linux-arm64" "x-tunnel-linux"
      download_bin "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" "cloudflared-linux"
      ;;
    *)
      say "当前架构$(uname -m)没有适配"
      exit 1
      ;;
  esac
  chmod +x cloudflared-linux x-tunnel-linux

  if [[ -n "${wsport:-}" ]]; then
    if ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE ":${wsport}$"; then
      say "[ERROR] 固定端口 ${wsport} 已被占用，请手动释放或选择其他端口"
      exit 1
    fi
  fi

  if [[ -z "${wsport:-}" ]]; then
    wsport="$(get_free_port)"
  fi

  local x_args=( -l "ws://127.0.0.1:${wsport}" )
  if [[ -n "${token:-}" ]]; then
    x_args+=( -token "$token" )
  fi
  if [[ -n "${forward_url:-}" ]]; then
    x_args+=( -f "$forward_url" )
  fi
  screen -dmUS x-tunnel ./x-tunnel-linux "${x_args[@]}"

  metricsport="$(get_free_port)"
  ./cloudflared-linux update >/dev/null 2>&1 || true

  screen -dmUS argo ./cloudflared-linux --edge-ip-version "$ips" --protocol "$cf_protocol" tunnel \
    --url "127.0.0.1:${wsport}" --metrics "0.0.0.0:${metricsport}"

  if [[ "${bind_enable:-0}" == "1" && -n "${cf_tunnel_token:-}" ]]; then
    screen -dmUS cfbind ./cloudflared-linux --edge-ip-version "$ips" --protocol "$cf_protocol" \
      --ha-connections "$cf_ha_connections" tunnel run --token "$cf_tunnel_token"
  fi

  TRY_DOMAIN=""
  for _ in $(seq 1 60); do
    RESP="$(curl -s "http://127.0.0.1:${metricsport}/metrics" || true)"
    if echo "$RESP" | grep -q 'userHostname='; then
      TRY_DOMAIN="$(echo "$RESP" | grep 'userHostname="' | sed -E 's/.*userHostname="https?:\/\/([^"]+)".*/\1/' | head -n1)"
      break
    fi
    sleep 1
  done

  # 保存配置，便于后续查看
  save_config

  clear
  say "=============================="
  say "梭哈模式：启动完成（配置已保存，可用选项4查看）"
  say "------------------------------"
  say "传输优化档位: ${cf_profile}  协议: ${cf_protocol}  并发连接: ${cf_ha_connections}"
  say "系统网络优化(BBR+FQ): ${net_tuned}"
  say "落地模式: $(landing_mode_text "${landing_mode}")"
  say "本地监听 ws 端口: ${wsport}"

  if [[ -n "$TRY_DOMAIN" ]]; then
    if [[ -z "${token:-}" ]]; then
      say "【临时域名 Quick Tunnel】 ${TRY_DOMAIN}:443"
    else
      say "【临时域名 Quick Tunnel】 ${TRY_DOMAIN}:443   身份令牌: ${token}"
    fi
  else
    say "【临时域名 Quick Tunnel】未解析到（可稍后查看 metrics）"
  fi

  if [[ "${bind_enable:-0}" == "1" ]]; then
    if [[ -n "${bind_domain:-}" ]]; then
      if [[ -z "${token:-}" ]]; then
        say "【绑定域名 Named Tunnel】 ${bind_domain}:443"
      else
        say "【绑定域名 Named Tunnel】 ${bind_domain}:443   身份令牌: ${token}"
      fi
      say "（请确保 Cloudflare 面板 Public Hostname 已正确指向 http://127.0.0.1:${wsport}）"
    else
      say "【绑定域名 Named Tunnel】已启用（未提供具体域名，仅后台运行）"
      say "（请在 Cloudflare 面板配置 Public Hostname 指向 http://127.0.0.1:${wsport}）"
    fi
  else
    say "【绑定域名 Named Tunnel】未启用"
  fi

  PUBIP="$(curl -4 -s https://www.cloudflare.com/cdn-cgi/trace | grep ip= | cut -d= -f2 || true)"
  if [[ -n "$PUBIP" ]]; then
    say "metrics: http://${PUBIP}:${metricsport}/metrics"
  else
    say "metrics: http://<你的公网IP>:${metricsport}/metrics"
  fi
  say "=============================="

  self_check "${bind_domain:-}" "${TRY_DOMAIN:-}" "${wsport:-}"
}

view_domains(){
  clear
  if load_config; then
    say "=============================="
    say "域名绑定查看（读取上次启动保存的配置）"
    say "------------------------------"
    say "传输优化档位: ${cf_profile:-未知}  协议: ${cf_protocol:-未知}  并发连接: ${cf_ha_connections:-未知}"
    say "系统网络优化(BBR+FQ): ${net_tuned:-未知}"
    say "落地模式: $(landing_mode_text "${landing_mode:-0}")  WG-SOCKS端口: ${wg_socks_port:-无}"
    say "本地监听 ws 端口: ${wsport:-未知}"

    if [[ -n "${try_domain:-}" ]]; then
      if [[ -z "${token:-}" ]]; then
        say "【临时域名 Quick Tunnel】 ${try_domain}:443"
      else
        say "【临时域名 Quick Tunnel】 ${try_domain}:443   身份令牌: ${token}"
      fi
    else
      say "【临时域名 Quick Tunnel】无记录（可能上次未解析成功）"
    fi

    if [[ "${bind_enable:-0}" == "1" ]]; then
      if [[ -n "${bind_domain:-}" ]]; then
        if [[ -z "${token:-}" ]]; then
          say "【绑定域名 Named Tunnel】 ${bind_domain}:443"
        else
          say "【绑定域名 Named Tunnel】 ${bind_domain}:443   身份令牌: ${token}"
        fi
      else
        say "【绑定域名 Named Tunnel】已启用（上次未提供具体域名）"
      fi
      say "（请确保 Cloudflare 面板 Public Hostname 已正确指向 http://127.0.0.1:${wsport:-未知}）"
    else
      say "【绑定域名 Named Tunnel】未启用"
    fi

    if [[ -n "${metricsport:-}" ]]; then
      PUBIP="$(curl -4 -s https://www.cloudflare.com/cdn-cgi/trace | grep ip= | cut -d= -f2 || true)"
      if [[ -n "$PUBIP" ]]; then
        say "metrics: http://${PUBIP}:${metricsport}/metrics"
      else
        say "metrics: http://<你的公网IP>:${metricsport}/metrics"
      fi
    fi
    say "=============================="

    # 实时自检（使用保存的域名）
    self_check "${bind_domain:-}" "${try_domain:-}" "${wsport:-}"
  else
    say "未找到上次启动的配置记录（可能未启动过或已清理）"
    say "请先运行选项1启动服务"
  fi
}

# ------------- main -------------
idx="$(os_index)"
need_cmd screen "$idx"
need_cmd curl "$idx"
need_cmd sed "$idx"
need_cmd grep "$idx"
need_cmd awk "$idx"
need_cmd ss "$idx" || true
need_cmd openssl "$idx" || true
need_cmd nc "$idx" || true

clear
say "梭哈模式不需要自己提供域名,使用CF ARGO QUICK TUNNEL创建快速链接"
say "梭哈模式在重启或者脚本再次运行后失效,如果需要使用需要再次运行创建"
printf "\n梭哈是一种智慧!!!梭哈!梭哈!梭哈!梭哈!梭哈!梭哈!梭哈...\n\n"
say "1.梭哈模式"
say "2.停止服务"
say "3.清空缓存"
say "4.域名绑定查看"
say "5.热切换落地(直连/HTTP/SOCKS5/WG)"
printf "0.退出脚本\n\n"
read -r -p "请选择模式(默认1):" mode
mode="${mode:-1}"

if [[ "$mode" == "1" ]]; then
  read -r -p "请选择cloudflared连接模式IPV4或者IPV6(输入4或6,默认4):" ips
  ips="${ips:-4}"
  if [[ "$ips" != "4" && "$ips" != "6" ]]; then
    say "请输入正确的cloudflared连接模式"
    exit 1
  fi

  say "传输优化档位：1.稳定优先(HTTP2) 2.速度优先(QUIC+2并发) 3.高吞吐优先(QUIC+4并发)"
  read -r -p "请选择传输优化档位(默认2):" cf_profile
  cf_profile="${cf_profile:-2}"
  case "$cf_profile" in
    1)
      cf_protocol="http2"
      cf_ha_connections="1"
      ;;
    2)
      cf_protocol="quic"
      cf_ha_connections="2"
      ;;
    3)
      cf_protocol="quic"
      cf_ha_connections="4"
      ;;
    *)
      say "未识别的档位，已使用默认速度优先(2)"
      cf_profile="2"
      cf_protocol="quic"
      cf_ha_connections="2"
      ;;
  esac

  configure_landing

  read -r -p "请设置x-tunnel的token(可留空):" token
  token="${token:-}"

  read -r -p "是否固定ws端口(0.不固定[默认],1.固定):" fixp
  fixp="${fixp:-0}"
  if [[ "$fixp" == "1" ]]; then
    read -r -p "请输入固定ws端口(默认 12345):" wsport
    wsport="${wsport:-12345}"
  else
    wsport=""
  fi

  read -r -p "是否启用绑定自定义域名(Named Tunnel)(0.不启用[默认],1.启用):" bind_enable
  bind_enable="${bind_enable:-0}"
  cf_tunnel_token=""
  bind_domain=""
  if [[ "$bind_enable" == "1" ]]; then
    say "提示：绑定域名需要你在 Cloudflare Zero Trust 创建 Named Tunnel 并配置 Public Hostname"
    read -r -p "请输入 Cloudflare Tunnel Token(必填):" cf_tunnel_token
    if [[ -z "${cf_tunnel_token:-}" ]]; then
      say "未提供 Tunnel Token，已取消绑定域名功能"
      bind_enable=0
    else
      read -r -p "请输入绑定域名(可留空，仅用于展示和自检):" bind_domain
      bind_domain="${bind_domain:-}"

      if [[ "$fixp" == "0" ]]; then
        say "警告：使用绑定域名时强烈建议固定 ws 端口，否则端口变动会导致 Cloudflare 面板配置失效"
        read -r -p "是否现在固定端口？(1.是[推荐], 0.否): " force_fix
        force_fix="${force_fix:-1}"
        if [[ "$force_fix" == "1" ]]; then
          fixp=1
          read -r -p "请输入固定 ws 端口(默认 12345):" wsport
          wsport="${wsport:-12345}"
        fi
      fi
    fi
  fi


  read -r -p "是否应用系统网络优化(BBR+FQ)(1.是[默认],0.否):" tune_net
  tune_net="${tune_net:-1}"
  if [[ "$tune_net" == "1" ]]; then
    apply_system_net_tuning
    net_tuned="1"
  else
    net_tuned="0"
  fi

  screen -wipe >/dev/null 2>&1 || true
  stop_screen x-tunnel
  stop_screen argo
  stop_screen cfbind
  stop_screen wg
  remove_config  # 清理旧配置
  clear
  sleep 1
  quicktunnel

elif [[ "$mode" == "2" ]]; then
  screen -wipe >/dev/null 2>&1 || true
  stop_screen x-tunnel
  stop_screen argo
  stop_screen cfbind
  stop_screen wg
  remove_config
  clear
  say "已停止服务（配置记录已清除）"

elif [[ "$mode" == "3" ]]; then
  screen -wipe >/dev/null 2>&1 || true
  stop_screen x-tunnel
  stop_screen argo
  stop_screen cfbind
  stop_screen wg
  rm -f cloudflared-linux x-tunnel-linux wireproxy-linux wireproxy.conf
  remove_config
  clear
  say "已清空缓存（配置记录已清除）"

elif [[ "$mode" == "4" ]]; then
  view_domains

elif [[ "$mode" == "5" ]]; then
  hot_switch_landing

else
  say "退出成功"
  exit 0
fi
