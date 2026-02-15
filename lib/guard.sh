health_check_once(){
  load_config || return 0

  if [[ -z "${wsport:-}" ]]; then
    wsport="$(detect_ws_port || true)"
  fi

  if [[ ! -x ./x-tunnel-linux || ! -x ./cloudflared-linux ]]; then
    say "[WARN] 二进制缺失，跳过守护自愈"
    return 0
  fi

  if [[ "${landing_mode:-0}" == "3" ]]; then
    if [[ -n "${wg_socks_port:-}" ]] && ! check_port_listening "${wg_socks_port}"; then
      say "[GUARD] 检测到 WG socks 失效，尝试恢复"
      start_wg_service_from_local_conf || true
    fi
  fi

  if [[ -z "${wsport:-}" ]] || ! ws_listening "${wsport}"; then
    say "[GUARD] 检测到 x-tunnel 监听异常，尝试重启"
    stop_screen x-tunnel
    start_x_tunnel_service || true
  elif ! screen_exists x-tunnel; then
    say "[GUARD] 检测到 x-tunnel 会话丢失，尝试重启"
    start_x_tunnel_service || true
  fi

  if ! screen_exists argo; then
    say "[GUARD] 检测到 argo 会话丢失，尝试重启"
    stop_screen argo
    start_argo_service || true
  fi

  if [[ "${bind_enable:-0}" == "1" && -n "${cf_tunnel_token:-}" ]] && ! screen_exists cfbind; then
    say "[GUARD] 检测到 cfbind 会话丢失，尝试重启"
    stop_screen cfbind
    start_cfbind_service || true
  fi
}

guard_loop(){
  say "[GUARD] 健康守护已启动，巡检间隔: ${guard_interval:-15}s"
  while true; do
    health_check_once || true
    sleep "${guard_interval:-15}"
  done
}

start_guard(){
  guard_enabled="1"
  if screen_exists guard; then
    say "[OK] 健康守护已在运行"
    return
  fi
  screen -dmUS guard bash -c "./suoha-x.sh --guard-loop >> '${GUARD_LOG_FILE}' 2>&1"
  say "[OK] 健康守护已开启，日志: ${GUARD_LOG_FILE}"
}

stop_guard(){
  guard_enabled="0"
  stop_screen guard
}
