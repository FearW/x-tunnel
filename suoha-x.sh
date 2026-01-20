#!/bin/bash
set -e

# suoha x-tunnel (fixed + bind domain support)

linux_os=("Debian" "Ubuntu" "CentOS" "Fedora" "Alpine")
linux_update=("apt update" "apt update" "yum -y update" "yum -y update" "apk update")
linux_install=("apt -y install" "apt -y install" "yum -y install" "yum -y install" "apk add -f")

n=0
for i in "${linux_os[@]}"; do
  if [[ "$i" == "$(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2 | awk '{print $1}')" ]]; then
    break
  else
    n=$((n+1))
  fi
done

if [[ "$n" == "5" ]]; then
  echo "当前系统$(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2)没有适配"
  echo "默认使用APT包管理器"
  n=0
fi

if ! command -v screen >/dev/null 2>&1; then
  ${linux_update[$n]} || true
  ${linux_install[$n]} screen
fi

if ! command -v curl >/dev/null 2>&1; then
  ${linux_update[$n]} || true
  ${linux_install[$n]} curl
fi

get_free_port() {
  while true; do
    PORT=$((RANDOM + 1024))
    if command -v ss >/dev/null 2>&1; then
      if ! ss -lnt | awk '{print $4}' | grep -qE ":${PORT}$"; then
        echo "$PORT"
        return
      fi
    else
      if ! lsof -i TCP:$PORT >/dev/null 2>&1; then
        echo "$PORT"
        return
      fi
    fi
  done
}

stop_screen() {
  local name="$1"
  screen -S "$name" -X quit >/dev/null 2>&1 || true
  # 等待退出（最多10秒）
  for _ in $(seq 1 10); do
    if ! screen -list 2>/dev/null | grep -q "\.${name}[[:space:]]"; then
      return
    fi
    sleep 1
  done
}

quicktunnel(){
  case "$(uname -m)" in
    x86_64|x64|amd64)
      [[ -f x-tunnel-linux ]] || curl -fsSL https://www.baipiao.eu.org/xtunnel/x-tunnel-linux-amd64 -o x-tunnel-linux
      [[ -f opera-linux ]] || curl -fsSL https://github.com/Snawoot/opera-proxy/releases/latest/download/opera-proxy.linux-amd64 -o opera-linux
      [[ -f cloudflared-linux ]] || curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o cloudflared-linux
      ;;
    i386|i686)
      [[ -f x-tunnel-linux ]] || curl -fsSL https://www.baipiao.eu.org/xtunnel/x-tunnel-linux-386 -o x-tunnel-linux
      [[ -f opera-linux ]] || curl -fsSL https://github.com/Snawoot/opera-proxy/releases/latest/download/opera-proxy.linux-386 -o opera-linux
      [[ -f cloudflared-linux ]] || curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-386 -o cloudflared-linux
      ;;
    armv8|arm64|aarch64)
      [[ -f x-tunnel-linux ]] || curl -fsSL https://www.baipiao.eu.org/xtunnel/x-tunnel-linux-arm64 -o x-tunnel-linux
      [[ -f opera-linux ]] || curl -fsSL https://github.com/Snawoot/opera-proxy/releases/latest/download/opera-proxy.linux-arm64 -o opera-linux
      [[ -f cloudflared-linux ]] || curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 -o cloudflared-linux
      ;;
    *)
      echo "当前架构$(uname -m)没有适配"
      exit 1
      ;;
  esac

  chmod +x cloudflared-linux x-tunnel-linux opera-linux

  # 可选：opera前置代理
  if [[ "${opera:-0}" == "1" ]]; then
    operaport="$(get_free_port)"
    screen -dmUS opera ./opera-linux -country "$country" -socks-mode -bind-address "127.0.0.1:$operaport"
  fi
  sleep 1

  # 关键：wsport建议固定，避免绑定域名的面板规则失配
  # 你也可以改成自定义输入
  wsport="${wsport:-}"
  if [[ -z "$wsport" ]]; then
    wsport="$(get_free_port)"
  fi

  if [[ -z "${token:-}" ]]; then
    if [[ "${opera:-0}" == "1" ]]; then
      screen -dmUS x-tunnel ./x-tunnel-linux -l "ws://127.0.0.1:$wsport" -f "socks5://127.0.0.1:$operaport"
    else
      screen -dmUS x-tunnel ./x-tunnel-linux -l "ws://127.0.0.1:$wsport"
    fi
  else
    if [[ "${opera:-0}" == "1" ]]; then
      screen -dmUS x-tunnel ./x-tunnel-linux -l "ws://127.0.0.1:$wsport" -token "$token" -f "socks5://127.0.0.1:$operaport"
    else
      screen -dmUS x-tunnel ./x-tunnel-linux -l "ws://127.0.0.1:$wsport" -token "$token"
    fi
  fi

  metricsport="$(get_free_port)"

  ./cloudflared-linux update >/dev/null 2>&1 || true

  # 1) Quick Tunnel 临时域名（保留）
  screen -dmUS argo ./cloudflared-linux --edge-ip-version "$ips" --protocol http2 tunnel \
    --url "127.0.0.1:$wsport" --metrics "0.0.0.0:$metricsport"

  # 2) Named Tunnel（绑定域名）— 仅启动，不影响临时域名
  # 注意：绑定域名是否生效取决于你在CF面板 Public Hostname 的配置
  if [[ "${bind_enable:-0}" == "1" && -n "${cf_tunnel_token:-}" ]]; then
    screen -dmUS cfbind ./cloudflared-linux --edge-ip-version "$ips" tunnel run --token "$cf_tunnel_token"
  fi

  # 解析临时域名
  DOMAIN=""
  for _ in $(seq 1 60); do
    RESP="$(curl -s "http://127.0.0.1:$metricsport/metrics" || true)"
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
  echo "本地监听 ws 端口: $wsport"
  if [[ -n "$DOMAIN" ]]; then
    if [[ -z "${token:-}" ]]; then
      echo "【临时域名 Quick Tunnel】$DOMAIN:443"
    else
      echo "【临时域名 Quick Tunnel】$DOMAIN:443  身份令牌: $token"
    fi
  else
    echo "【临时域名 Quick Tunnel】未解析到 userHostname（可稍后查看 metrics）"
  fi

  if [[ "${bind_enable:-0}" == "1" ]]; then
    echo "【绑定域名 Named Tunnel】已启动（需要你在CF面板将Public Hostname的Service设为TCP并指向 127.0.0.1:$wsport）"
    if [[ -n "${bind_domain:-}" ]]; then
      echo "绑定域名（展示用）: ${bind_domain}"
    fi
  else
    echo "【绑定域名 Named Tunnel】未启用"
  fi

  PUBIP="$(curl -4 -s https://www.cloudflare.com/cdn-cgi/trace | grep ip= | cut -d= -f2 || true)"
  if [[ -n "$PUBIP" ]]; then
    echo "metrics: http://${PUBIP}:${metricsport}/metrics"
  else
    echo "metrics: http://<你的公网IP>:${metricsport}/metrics"
  fi
  echo "=============================="
}

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

  # 新增：固定端口（用于绑定域名）
  read -r -p "是否固定ws端口用于绑定域名(0.不固定[默认],1.固定):" fixp
  fixp="${fixp:-0}"
  if [[ "$fixp" == "1" ]]; then
    read -r -p "请输入固定ws端口(默认 12345):" wsport
    wsport="${wsport:-12345}"
  else
    wsport=""
  fi

  # 新增：绑定域名（Named Tunnel）
  read -r -p "是否启用绑定自定义域名(Named Tunnel)(0.不启用[默认],1.启用):" bind_enable
  bind_enable="${bind_enable:-0}"
  cf_tunnel_token=""
  bind_domain=""
  if [[ "$bind_enable" == "1" ]]; then
    echo "提示：绑定域名需要你在Cloudflare Zero Trust创建Named Tunnel并配置Public Hostname"
    read -r -p "请输入Cloudflare Tunnel Token(必填):" cf_tunnel_token
    if [[ -z "${cf_tunnel_token:-}" ]]; then
      echo "未提供Tunnel Token，已取消绑定域名功能"
      bind_enable=0
    else
      read -r -p "请输入绑定域名(可留空，仅用于展示):" bind_domain
      bind_domain="${bind_domain:-}"
      echo "请在CF面板把 Public Hostname 的 Service 类型设为 TCP，并指向 127.0.0.1:${wsport:-<随机>}"
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
  stop_screen x-tunnel   # 修复原脚本 ech 拼写错误
  stop_screen opera
  stop_screen argo
  stop_screen cfbind
  clear

elif [[ "$mode" == "3" ]]; then
  screen -wipe >/dev/null 2>&1 || true
  stop_screen x-tunnel
  stop_screen opera
  stop_screen argo
  stop_screen cfbind
  clear
  rm -f cloudflared-linux x-tunnel-linux opera-linux

else
  echo "退出成功"
  exit 0
fi
