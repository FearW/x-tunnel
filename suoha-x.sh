#!/usr/bin/env bash
set -euo pipefail

# suoha x-tunnel (fixed + bind domain support)
linux_os=("Debian" "Ubuntu" "CentOS" "Fedora" "Alpine")
linux_update=("apt update" "apt update" "yum -y update" "yum -y update" "apk update")
linux_install=("apt -y install" "apt -y install" "yum -y install" "yum -y install" "apk add -f")

# -------- helpers --------
os_detect() {
  local n=0
  local pretty
  pretty="$(grep -i PRETTY_NAME /etc/os-release | cut -d '"' -f2 | awk '{print $1}' || true)"

  for i in "${linux_os[@]}"; do
    if [[ "$i" == "$pretty" ]]; then
      echo "$n"
      return
    else
      n=$((n+1))
    fi
  done

  # fallback
  echo "当前系统$(grep -i PRETTY_NAME /etc/os-release | cut -d '"' -f2)没有适配"
  echo "默认使用APT包管理器"
  echo 0
}

need_cmd() {
  local cmd="$1"
  local idx="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    ${linux_update[$idx]} >/dev/null 2>&1 || true
    ${linux_install[$idx]} "$cmd"
  fi
}

get_free_port() {
  # avoid lsof dependency; use ss if available, else fallback to lsof.
  while true; do
    local PORT=$((RANDOM + 1024))
    if command -v ss >/dev/null 2>&1; then
      if ! ss -lnt | awk '{print $4}' | grep -qE ":${PORT}$"; then
        echo "$PORT"
        return
      fi
    else
      if ! command -v lsof >/dev/null 2>&1; then
        # can't install here safely if filesystem is restricted; best-effort:
        true
      fi
      if ! lsof -i TCP:"$PORT" >/dev/null 2>&1; then
        echo "$PORT"
        return
      fi
    fi
  done
}

stop_screen_session() {
  local name="$1"
  # kill if exists
  screen -S "$name" -X quit >/dev/null 2>&1 || true
  # wait until really gone
  for _ in $(seq 1 10); do
    if ! screen -list 2>/dev/null | grep -q "\.${name}[[:space:]]"; then
      return
    fi
    sleep 1
  done
}

download_bin() {
  local url="$1"
  local out="$2"
  if [[ ! -f "$out" ]]; then
    curl -fsSL "$url" -o "$out"
  fi
}

# -------- core: quicktunnel + optional bind domain --------
quicktunnel() {
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
      echo "当前架构$(uname -m)没有适配"
      exit 1
      ;;
  esac

  chmod +x cloudflared-linux x-tunnel-linux opera-linux

  # opera forward proxy (optional)
  if [[ "${opera:-0}" == "1" ]]; then
    operaport="$(get_free_port)"
    screen -dmUS opera ./opera-linux -country "$country" -socks-mode -bind-address "127.0.0.1:${operaport}"
  fi

  sleep 1
  wsport="$(get_free_port)"

  # x-tunnel
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

  # Quick Tunnel (temporary domain) - keep original behavior
  # NOTE: update may fail in restricted FS; ignore errors.
  ./cloudflared-linux update >/dev/null 2>&1 || true
  screen -dmUS argo ./cloudflared-linux --edge-ip-version "$ips" --protocol http2 tunnel \
    --url "127.0.0.1:${wsport}" --metrics "0.0.0.0:${metricsport}"

  # Optional: bind custom domain via Cloudflare Tunnel Token (named tunnel)
  # This will NOT replace quick tunnel; it runs in parallel.
  if [[ "${bind_enable:-0}" == "1" && -n "${cf_tunnel_token:-}" ]]; then
    # Named tunnel run; domain binding is controlled in CF dashboard (Public Hostname)
    screen -dmUS cfbind ./cloudflared-linux --edge-ip-version "$ips" tunnel run --token "$cf_tunnel_token"
  fi

  # Parse quick tunnel domain from metrics (userHostname)
  local DOMAIN=""
  for _ in $(seq 1 60); do
    RESP="$(curl -s "http://127.0.0.1:${metricsport}/metrics" || true)"
    if echo "$RESP" | grep -q 'userHostname='; then
      DOMAIN="$(echo "$RESP" | grep 'userHostname="' | sed -E 's/.*userHostname="https?:\/\/([^"]+)".*/\1/' | head -n1)"
      break
    fi
    sleep 1
  done

  clear
  echo "=============================="
  echo "梭哈模式：启动完成"
  echo "------------------------------"
  if [[ -n "$DOMAIN" ]]; then
    if [[ -z "${token:-}" ]]; then
      echo "【临时域名 Quick Tunnel】链接: ${DOMAIN}:443"
    else
      echo "【临时域名 Quick Tunnel】链接: ${DOMAIN}:443   身份令牌: ${token}"
    fi
  else
    echo "【临时域名 Quick Tunnel】未解析到 userHostname（可稍后手动查看 metrics）"
  fi

  if [[ "${bind_enable:-0}" == "1" && -n "${cf_tunnel_token:-}" ]]; then
    if [[ -n "${bind_domain:-}" ]]; then
      if [[ -z "${token:-}" ]]; then
        echo "【绑定域名】理论可用: ${bind_domain}:443  （前提：你已在CF面板把该域名绑定到此Named Tunnel）"
      else
        echo "【绑定域名】理论可用: ${bind_domain}:443  身份令牌: ${token} （前提：CF面板已绑定）"
      fi
    else
      echo "【绑定域名】已启动 Named Tunnel（前提：CF面板 Public Hostname 已配置）"
    fi
  else
    echo "【绑定域名】未启用"
  fi

  echo "------------------------------"
  # This IP lookup may fail if network restricted; ignore.
  local PUBIP
  PUBIP="$(curl -4 -s https://www.cloudflare.com/cdn-cgi/trace | grep ip= | cut -d= -f2 || true)"
  if [[ -n "$PUBIP" ]]; then
    echo "可访问 http://${PUBIP}:${metricsport}/metrics 查找 userHostname"
  else
    echo "可访问 http://<你的公网IP>:${metricsport}/metrics 查找 userHostname"
  fi
  echo "=============================="
}

# -------- main --------
idx="$(os_detect)"

need_cmd screen "$idx"
need_cmd curl "$idx"
# optional tools; don't hard fail
need_cmd awk "$idx" >/dev/null 2>&1 || true
need_cmd grep "$idx" >/dev/null 2>&1 || true
need_cmd sed "$idx" >/dev/null 2>&1 || true

clear
echo "梭哈模式不需要自己提供域名,使用CF ARGO QUICK TUNNEL创建快速链接"
echo "梭哈模式在重启或者脚本再次运行后失效,如果需要使用需要再次运行创建"
printf "\n梭哈是一种智慧!!!梭哈!梭哈!梭哈!梭哈!梭哈!梭哈!梭哈...\n\n"
echo "1.梭哈模式"
echo "2.停止服务"
echo "3.清空缓存"
printf "0.退出脚本\n\n"

read -r -p "请选择模式(默认1):" mode
mode="${mode:-1}"

if [[ "$mode" == "1" ]]; then
  read -r -p "是否启用opera前置代理(0.不启用[默认],1.启用):" opera
  opera="${opera:-0}"

  if [[ "$opera" == "1" ]]; then
    echo "注意:opera前置代理仅支持AM,AS,EU地区"
    echo "AM: 北美地区"
    echo "AS: 亚太地区"
    echo "EU: 欧洲地区"
    read -r -p "请输入opera前置代理的国家代码(默认AM):" country
    country="${country:-AM}"
    # uppercase
    country="$(echo "$country" | tr '[:lower:]' '[:upper:]')"
    if [[ "$country" != "AM" && "$country" != "AS" && "$country" != "EU" ]]; then
      echo "请输入正确的opera前置代理国家代码"
      exit 1
    fi
  fi

  if [[ "$opera" != "0" && "$opera" != "1" ]]; then
    echo "请输入正确的opera前置代理模式"
    exit 1
  fi

  read -r -p "请选择cloudflared连接模式IPV4或者IPV6(输入4或6,默认4):" ips
  ips="${ips:-4}"
  if [[ "$ips" != "4" && "$ips" != "6" ]]; then
    echo "请输入正确的cloudflared连接模式"
    exit 1
  fi

  read -r -p "请设置x-tunnel的token(可留空):" token
  token="${token:-}"

  # New: bind domain support
  read -r -p "是否启用绑定自定义域名(0.不启用[默认],1.启用):" bind_enable
  bind_enable="${bind_enable:-0}"
  if [[ "$bind_enable" == "1" ]]; then
    echo "提示：绑定域名需要你在Cloudflare Zero Trust中创建Named Tunnel并配置Public Hostname"
    read -r -p "请输入Cloudflare Tunnel Token(必填):" cf_tunnel_token
    if [[ -z "${cf_tunnel_token:-}" ]]; then
      echo "未提供Tunnel Token，已取消绑定域名功能"
      bind_enable=0
    else
      read -r -p "请输入你绑定的域名(可留空，仅用于展示):" bind_domain
      bind_domain="${bind_domain:-}"
    fi
  else
    bind_enable=0
    cf_tunnel_token=""
    bind_domain=""
  fi

  # stop old sessions
  screen -wipe >/dev/null 2>&1 || true
  stop_screen_session x-tunnel
  stop_screen_session opera
  stop_screen_session argo
  stop_screen_session cfbind

  clear
  sleep 1
  quicktunnel

elif [[ "$mode" == "2" ]]; then
  screen -wipe >/dev/null 2>&1 || true
  stop_screen_session x-tunnel   # fixed: was "ech" typo
  stop_screen_session opera
  stop_screen_session argo
  stop_screen_session cfbind
  clear

elif [[ "$mode" == "3" ]]; then
  screen -wipe >/dev/null 2>&1 || true
  stop_screen_session x-tunnel
  stop_screen_session opera
  stop_screen_session argo
  stop_screen_session cfbind
  clear
  rm -f cloudflared-linux x-tunnel-linux opera-linux

else
  echo "退出成功"
  exit 0
fi