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
    echo "forward_url=${forward_url:-}"
    echo "wg_socks_port=${wg_socks_port:-}"
    echo "ips=${ips:-4}"
    echo "cf_tunnel_token=${cf_tunnel_token:-}"
    echo "guard_enabled=${guard_enabled:-0}"
    echo "guard_interval=${guard_interval:-15}"
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
