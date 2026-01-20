#!/usr/bin/env bash
set -euo pipefail

# =========================
# suoha x-tunnel FINAL
# - Quick Tunnel (trycloudflare) + Named Tunnel (bind domain)
# - Auto self-check / debug
# =========================

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
    local PORT=$((RANDOM + 1024))
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
  # Detect actual listening port of x-tunnel
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
- 优先检查 Cloudflare Public Hostname 指向是否是 http://127.0.0.1:${wsport}（建议固定端口）
- 确认同一个 hostname 没有多条冲突路由
EOF
}

# ------------- core -------------
quicktunnel(){
  case "$(uname -m)" in
    x86_64|x64|amd64)
      download_bin "https://www.baipiao.eu.org/xtunnel/x-tunnel-linux-amd64" "x-tunnel-linux"
      download_bin "https://github.com/Snawoot/opera-proxy/releases/latest/download/opera-proxy.linux-amd64" "opera-linux"
      download_bin "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" "cloudflared-linux"
      ;;
    i386|i686)
      download_bin "https://www.baipiao.eu.org/xtunnel/x-tunnel-linux-386" "x-tunnel-linux"
      download_bin "https://github.com/Snawoot/opera-proxy/releases/latest/download/opera-proxy.linux-386" "opera-linux"
      download_bin "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-386" "cloudflared-linux"
      ;;
    armv8|arm64|aarch64)
      download_bin "https://www.baipiao.eu.org/xtunnel/x-tunnel-linux-arm64" "x-tunnel-linux"
      download_bin "https://github.com/Snawoot/opera-proxy/releases/latest/download/opera-proxy.linux-arm64" "opera-linux"
      download_bin "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" "cloudflared-linux"
      ;;
    *)
      say "当前架构$(uname -m)没有适配"
      exit 1
      ;;
  esac

  chmod +x cloudflared-linux x-tunnel-linux opera-linux

  # opera proxy (optional)
  if [[ "${opera:-0}" == "1" ]]; then
    operaport="$(get_free_port)"
    screen -dmUS opera ./opera-linux -country "$country" -socks-mode -bind-address "127.0.0.1:${operaport}"
  fi
  sleep 1

  # ws port
  if [[ -z "${wsport:-}" ]]; then
    wsport="$(get_free_port)"
  fi

  # run x-tunnel
  if [[ -z "${token:-}" ]]; then
    if [[ "${opera:-0}" == "1" ]]; then
      screen -dmUS x-tunnel ./x-tunnel-linux -l "ws://127.0.0.1:${wsport}" -f "socks5://127.0.0.1:${operaport}"
    else
      screen -dmUS x-tunnel ./x-tunnel-linux -l "ws://127.0.0.1:${wsport}"
    fi
  else
    if [[ "${opera:-0}" == "1" ]]; then
      screen -dmUS x-tunnel ./x-tunnel-linux -l "ws://127.0.0.1:${wsport}" -token "$token" -f "socks5://127.0.0.1:${operaport}"
    else
      screen -dmUS x-tunnel ./x-tunnel-linux -l "ws://127.0.0.1:${wsport}" -token "$token"
    fi
  fi

  metricsport="$(get_free_port)"

  ./cloudflared-linux update >/dev/null 2>&1 || true

  # Quick Tunnel (temporary domain)
  screen -dmUS argo ./cloudflared-linux --edge-ip-version "$ips" --protocol http2 tunnel \
    --url "127.0.0.1:${wsport}" --metrics "0.0.0.0:${metricsport}"

  # Named Tunnel (bind domain) - runs in parallel
  if [[ "${bind_enable:-0}" == "1" && -n "${cf_tunnel_token:-}" ]]; then
    screen -dmUS cfbind ./cloudflared-linux --edge-ip-version "$ips" tunnel run --token "$cf_tunnel_token"
  fi

  # Parse trycloudflare domain from metrics userHostname
  TRY_DOMAIN=""
  for _ in $(seq 1 60); do
    RESP="$(curl -s "http://127.0.0.1:${metricsport}/metrics" || true)"
    if echo "$RESP" | grep -q 'userHostname='; then
      TRY_DOMAIN="$(echo "$RESP" | grep 'userHostname="' | sed -E 's/.*userHostname="https?:\/\/([^"]+)".*/\1/' | head -n1)"
      break
    fi
    sleep 1
  done

  clear
  say "=============================="
  say "梭哈模式：启动完成"
  say "------------------------------"
  say "本地监听 ws 端口: ${wsport}"

  if [[ -n "$TRY_DOMAIN" ]]; then
    if [[ -z "${token:-}" ]]; then
      say "【临时域名 Quick Tunnel】${TRY_DOMAIN}:443"
    else
      say "【临时域名 Quick Tunnel】${TRY_DOMAIN}:443  身份令牌: ${token}"
    fi
  else
    say "【临时域名 Quick Tunnel】未解析到 userHostname（可稍后查看 metrics）"
  fi

  if [[ "${bind_enable:-0}" == "1" ]]; then
    say "【绑定域名 Named Tunnel】已启动（请在CF面板 Public Hostname 指向 http://127.0.0.1:${wsport}）"
    [[ -n "${bind_domain:-}" ]] && say "绑定域名（展示用）: ${bind_domain}"
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

  # Auto self-check
  self_check "${bind_domain:-}" "${TRY_DOMAIN:-}" "${wsport:-}"
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
printf "0.退出脚本\n\n"

read -r -p "请选择模式(默认1):" mode
mode="${mode:-1}"

if [[ "$mode" == "1" ]]; then
  read -r -p "是否启用opera前置代理(0.不启用[默认],1.启用):" opera
  opera="${opera:-0}"

  if [[ "$opera" == "1" ]]; then
    say "注意:opera前置代理仅支持AM,AS,EU地区"
    say "AM: 北美地区"
    say "AS: 亚太地区"
    say "EU: 欧洲地区"
    read -r -p "请输入opera前置代理的国家代码(默认AM):" country
    country="${country:-AM}"
    country="$(echo "$country" | tr '[:lower:]' '[:upper:]')"
    if [[ "$country" != "AM" && "$country" != "AS" && "$country" != "EU" ]]; then
      say "请输入正确的opera前置代理国家代码"
      exit 1
    fi
  fi

  read -r -p "请选择cloudflared连接模式IPV4或者IPV6(输入4或6,默认4):" ips
  ips="${ips:-4}"
  if [[ "$ips" != "4" && "$ips" != "6" ]]; then
    say "请输入正确的cloudflared连接模式"
    exit 1
  fi

  read -r -p "请设置x-tunnel的token(可留空):" token
  token="${token:-}"

  # Fix port (recommended)
  read -r -p "是否固定ws端口用于绑定域名(0.不固定[默认],1.固定):" fixp
  fixp="${fixp:-0}"
  if [[ "$fixp" == "1" ]]; then
    read -r -p "请输入固定ws端口(默认 12345):" wsport
    wsport="${wsport:-12345}"
  else
    wsport=""
  fi

  # Bind domain
  read -r -p "是否启用绑定自定义域名(Named Tunnel)(0.不启用[默认],1.启用):" bind_enable
  bind_enable="${bind_enable:-0}"
  cf_tunnel_token=""
  bind_domain=""
  if [[ "$bind_enable" == "1" ]]; then
    say "提示：绑定域名需要你在Cloudflare Zero Trust创建Named Tunnel并配置Public Hostname"
    read -r -p "请输入Cloudflare Tunnel Token(必填):" cf_tunnel_token
    if [[ -z "${cf_tunnel_token:-}" ]]; then
      say "未提供Tunnel Token，已取消绑定域名功能"
      bind_enable=0
    else
      read -r -p "请输入绑定域名(可留空，仅用于展示):" bind_domain
      bind_domain="${bind_domain:-}"
    fi
  fi

  screen -wipe >/dev/null 2>&1 || true
  stop_screen x-tunnel
  stop_screen opera
  stop_screen argo
  stop_screen cfbind

  clear
  sleep 1
  quicktunnel

elif [[ "$mode" == "2" ]]; then
  screen -wipe >/dev/null 2>&1 || true
  stop_screen x-tunnel
  stop_screen opera
  stop_screen argo
  stop_screen cfbind
  clear
  say "已停止服务"

elif [[ "$mode" == "3" ]]; then
  screen -wipe >/dev/null 2>&1 || true
  stop_screen x-tunnel
  stop_screen opera
  stop_screen argo
  stop_screen cfbind
  rm -f cloudflared-linux x-tunnel-linux opera-linux
  clear
  say "已清空缓存"

else
  say "退出成功"
  exit 0
fi
