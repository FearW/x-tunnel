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

  start_x_tunnel_service

  metricsport="$(get_free_port)"
  ./cloudflared-linux update >/dev/null 2>&1 || true

  start_argo_service

  if [[ "${bind_enable:-0}" == "1" && -n "${cf_tunnel_token:-}" ]]; then
    start_cfbind_service
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

  save_config

  if [[ "${guard_enabled:-0}" == "1" ]]; then
    start_guard
    save_config
  else
    stop_guard
  fi

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

    self_check "${bind_domain:-}" "${try_domain:-}" "${wsport:-}"
  else
    say "未找到上次启动的配置记录（可能未启动过或已清理）"
    say "请先运行选项1启动服务"
  fi
}
