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

  say "------------------------------"
  verify_landing "${landing_mode:-0}" "${forward_url:-}"
  say "[OK] 热切换完成 -> $(landing_mode_text "${landing_mode:-0}")"
  say "------------------------------"
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
    if check_port_listening "${wsport}"; then
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

  if [[ -n "$TRY_DOMAIN" ]]; then
    say "【Quick Tunnel】 ${TRY_DOMAIN}:443"
  else
    say "【Quick Tunnel】 未解析到域名（可稍后用选项4查看）"
  fi

  if [[ "${bind_enable:-0}" == "1" && -n "${bind_domain:-}" ]]; then
    say "【Named Tunnel】 ${bind_domain}:443"
  fi

  if [[ -n "${token:-}" ]]; then
    say "【Token】 ${token}"
  fi

  say "=============================="

  verify_landing "${landing_mode:-0}" "${forward_url:-}"
}

view_domains(){
  clear
  if load_config; then
    say "=============================="
    say "域名绑定查看"
    say "------------------------------"

    if [[ -n "${try_domain:-}" ]]; then
      say "【Quick Tunnel】 ${try_domain}:443"
    else
      say "【Quick Tunnel】 无记录"
    fi

    if [[ "${bind_enable:-0}" == "1" && -n "${bind_domain:-}" ]]; then
      say "【Named Tunnel】 ${bind_domain}:443"
    fi

    if [[ -n "${token:-}" ]]; then
      say "【Token】 ${token}"
    fi

    say "------------------------------"
    say "落地模式: $(landing_mode_text "${landing_mode:-0}")"
    say "ws端口: ${wsport:-未知}"
    say "健康守护: ${guard_enabled:-0}"
    say "=============================="

    verify_landing "${landing_mode:-0}" "${forward_url:-}"
  else
    say "未找到配置记录，请先运行选项1启动服务"
  fi
}
