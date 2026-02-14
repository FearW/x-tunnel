#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${HOME}/.suoha_tunnel_config"
WG_PROFILE_DIR="${HOME}/.suoha_wg_profiles"
GUARD_LOG_FILE="${HOME}/.suoha_guard.log"

cf_protocol="quic"
cf_ha_connections="4"
cf_profile="2"
net_tuned="0"
landing_mode="0"
forward_url=""
wg_socks_port=""
guard_enabled="0"
guard_interval="15"

linux_os=("Debian" "Ubuntu" "CentOS" "Fedora" "Alpine")
linux_update=("apt update" "apt update" "yum -y update" "yum -y update" "apk update")
linux_install=("apt -y install" "apt -y install" "yum -y install" "yum -y install" "apk add -f")

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
REMOTE_LIB_BASE="https://raw.githubusercontent.com/FearW/x-tunnel/refs/heads/main/lib"

if [[ ! -d "${LIB_DIR}" ]]; then
  mkdir -p "${LIB_DIR}"
fi

for lib_file in common.sh net.sh config.sh wg.sh services.sh guard.sh cloudflare.sh; do
  if [[ ! -f "${LIB_DIR}/${lib_file}" ]]; then
    curl -fsSL "${REMOTE_LIB_BASE}/${lib_file}" -o "${LIB_DIR}/${lib_file}" || {
      echo "[ERROR] 缺少 ${lib_file} 且自动下载失败，请完整下载仓库后再运行。"
      exit 1
    }
  fi
done

# shellcheck source=/dev/null
source "${LIB_DIR}/common.sh"
# shellcheck source=/dev/null
source "${LIB_DIR}/net.sh"
# shellcheck source=/dev/null
source "${LIB_DIR}/config.sh"
# shellcheck source=/dev/null
source "${LIB_DIR}/wg.sh"
# shellcheck source=/dev/null
source "${LIB_DIR}/services.sh"
# shellcheck source=/dev/null
source "${LIB_DIR}/guard.sh"
# shellcheck source=/dev/null
source "${LIB_DIR}/cloudflare.sh"

idx="$(os_index)"
need_cmd screen "$idx"
need_cmd curl "$idx"
need_cmd sed "$idx"
need_cmd grep "$idx"
need_cmd awk "$idx"
need_cmd ss "$idx" || true
need_cmd openssl "$idx" || true
need_cmd nc "$idx" || true

print_install_plan(){
  say "------------------------------"
  say "安装向导步骤："
  say "  1) 选择 Cloudflared 网络与传输档位"
  say "  2) 选择落地模式（直连/HTTP/SOCKS5/WG）"
  say "  3) 设置 x-tunnel token 与端口策略"
  say "  4) 可选绑定 Named Tunnel 域名"
  say "  5) 可选系统优化与健康守护"
  say "------------------------------"
}

confirm_install_plan(){
  say "安装配置预览："
  say "  - 落地模式: $(landing_mode_text "${landing_mode:-0}")"
  if [[ -n "${forward_url:-}" ]]; then
    say "  - 落地地址: ${forward_url}"
  fi
  say "  - 传输协议: ${cf_protocol:-quic}"
  say "  - 并发连接: ${cf_ha_connections:-2}"
  say "  - 固定端口: ${fixp:-0}"
  read -r -p "确认以上配置并开始安装启动？(1.确认[默认],0.返回菜单):" confirm_start
  confirm_start="${confirm_start:-1}"
  [[ "$confirm_start" == "1" ]]
}

if [[ "${1:-}" == "--guard-loop" ]]; then
  load_config || exit 0
  guard_loop
  exit 0
fi

clear
say "梭哈模式不需要自己提供域名,使用CF ARGO QUICK TUNNEL创建快速链接"
say "梭哈模式在重启或者脚本再次运行后失效,如果需要使用需要再次运行创建"
printf "\n梭哈是一种智慧!!!梭哈!梭哈!梭哈!梭哈!梭哈!梭哈!梭哈...\n\n"
say "1.梭哈模式"
say "2.停止服务"
say "3.卸载(彻底清理)"
say "4.域名绑定查看"
say "5.热切换落地(直连/HTTP/SOCKS5/WG)"
say "6.健康守护开关"
printf "0.退出脚本\n\n"
read -r -p "请选择模式(默认1):" mode
mode="${mode:-1}"

if [[ "$mode" == "1" ]]; then
  print_install_plan
  prev_ips="${ips:-4}"
  prev_cf_profile="${cf_profile:-2}"
  prev_token="${token:-}"

  if load_config; then
    say "检测到历史配置：可直接回车沿用上次参数（包括落地模式）"
    prev_ips="${ips:-4}"
    prev_cf_profile="${cf_profile:-2}"
    prev_token="${token:-}"
  fi

  say "安装向导说明：先选传输档位，再选落地渠道（直连/HTTP/SOCKS5/WG），最后再配置端口和域名。"

  read -r -p "请选择cloudflared连接模式IPV4或者IPV6(输入4或6,默认${prev_ips}):" ips
  ips="${ips:-$prev_ips}"
  if [[ "$ips" != "4" && "$ips" != "6" ]]; then
    say "请输入正确的cloudflared连接模式"
    exit 1
  fi

  say "传输优化档位：1.稳定优先(HTTP2) 2.速度优先(QUIC+2并发) 3.高吞吐优先(QUIC+4并发)"
  read -r -p "请选择传输优化档位(默认${prev_cf_profile}):" cf_profile
  cf_profile="${cf_profile:-$prev_cf_profile}"
  case "$cf_profile" in
    1) cf_protocol="http2"; cf_ha_connections="1" ;;
    2) cf_protocol="quic"; cf_ha_connections="2" ;;
    3) cf_protocol="quic"; cf_ha_connections="4" ;;
    *)
      say "未识别的档位，已使用默认速度优先(2)"
      cf_profile="2"; cf_protocol="quic"; cf_ha_connections="2"
      ;;
  esac

  configure_landing

  read -r -p "请设置x-tunnel的token(可留空，默认沿用上次):" token
  token="${token:-$prev_token}"

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

  read -r -p "是否启用健康守护(1.是[默认],0.否):" guard_enabled
  guard_enabled="${guard_enabled:-1}"
  if [[ "$guard_enabled" == "1" ]]; then
    read -r -p "请输入守护巡检间隔秒数(默认15):" guard_interval
    guard_interval="${guard_interval:-15}"
  fi

  if ! confirm_install_plan; then
    say "已取消本次安装启动，返回菜单"
    exit 0
  fi

  screen -wipe >/dev/null 2>&1 || true
  stop_screen x-tunnel
  stop_screen argo
  stop_screen cfbind
  stop_screen wg
  remove_config
  clear
  sleep 1
  quicktunnel

elif [[ "$mode" == "2" ]]; then
  screen -wipe >/dev/null 2>&1 || true
  stop_screen x-tunnel
  stop_screen argo
  stop_screen cfbind
  stop_screen wg
  stop_guard
  remove_config
  clear
  say "已停止服务（配置记录已清除）"

elif [[ "$mode" == "3" ]]; then
  screen -wipe >/dev/null 2>&1 || true
  stop_screen x-tunnel
  stop_screen argo
  stop_screen cfbind
  stop_screen wg
  stop_guard
  rm -f "${SCRIPT_DIR}/cloudflared-linux" "${SCRIPT_DIR}/x-tunnel-linux" "${SCRIPT_DIR}/wireproxy-linux" "${SCRIPT_DIR}/wireproxy.conf"
  rm -f "${HOME}/.suoha_wireproxy.log"
  rm -rf "${WG_PROFILE_DIR}"
  rm -rf "${LIB_DIR}"
  remove_config
  rm -f "${GUARD_LOG_FILE}"
  clear
  say "已卸载并彻底清理：服务、二进制、lib库、WG配置、日志与配置记录"

elif [[ "$mode" == "4" ]]; then
  view_domains

elif [[ "$mode" == "5" ]]; then
  hot_switch_landing

elif [[ "$mode" == "6" ]]; then
  if load_config; then
    if screen_exists guard; then
      stop_guard
      save_config
      say "已关闭健康守护"
    else
      read -r -p "请输入守护巡检间隔秒数(默认15):" guard_interval
      guard_interval="${guard_interval:-15}"
      start_guard
      save_config
    fi
  else
    say "未找到运行配置，请先启动(选项1)"
  fi

else
  say "退出成功"
  exit 0
fi
