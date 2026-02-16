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

start_argo_service(){
  if [[ -z "${wsport:-}" ]]; then
    return 1
  fi

  if [[ -z "${metricsport:-}" ]]; then
    metricsport="$(get_free_port)"
  fi

  screen -dmUS argo ./cloudflared-linux --edge-ip-version "${ips:-4}" --protocol "${cf_protocol:-quic}" tunnel \
    --url "127.0.0.1:${wsport}" --metrics "0.0.0.0:${metricsport}"
}

start_cfbind_service(){
  if [[ "${bind_enable:-0}" != "1" || -z "${cf_tunnel_token:-}" ]]; then
    return 0
  fi
  screen -dmUS cfbind ./cloudflared-linux --edge-ip-version "${ips:-4}" --protocol "${cf_protocol:-quic}" \
    --ha-connections "${cf_ha_connections:-2}" tunnel run --token "${cf_tunnel_token}"
}

start_wg_service_from_local_conf(){
  local script_dir wireproxy_path wireproxy_conf
  script_dir="${SCRIPT_DIR:-$(pwd)}"
  wireproxy_path="${script_dir}/wireproxy-linux"
  wireproxy_conf="${script_dir}/wireproxy.conf"

  if [[ ! -f "${wireproxy_conf}" || ! -x "${wireproxy_path}" ]]; then
    say "[WARN] wireproxy 配置或二进制缺失，无法自动恢复 WG"
    return 1
  fi
  # 彻底清理旧进程再启动
  kill_wireproxy
  screen -dmUS wg "${wireproxy_path}" -c "${wireproxy_conf}"
  sleep 2
  if [[ -n "${wg_socks_port:-}" ]] && check_port_listening "${wg_socks_port}"; then
    return 0
  fi
  say "[WARN] WG 自动恢复失败"
  return 1
}
