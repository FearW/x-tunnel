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
  cat > "$path" <<EOH
wg_private_key=${wg_private_key}
wg_address=${wg_address}
wg_dns=${wg_dns}
wg_peer_public_key=${wg_peer_public_key}
wg_preshared_key=${wg_preshared_key}
wg_endpoint=${wg_endpoint}
wg_allowed_ips=${wg_allowed_ips}
EOH
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
  cat > wireproxy.conf <<EOH
[Interface]
PrivateKey = ${wg_private_key}
Address = ${wg_address}
DNS = ${wg_dns}

[Peer]
PublicKey = ${wg_peer_public_key}
AllowedIPs = ${wg_allowed_ips}
Endpoint = ${wg_endpoint}
PersistentKeepalive = 25
EOH
  if [[ -n "${wg_preshared_key:-}" ]]; then
    printf 'PresharedKey = %s\n' "$wg_preshared_key" >> wireproxy.conf
  fi
  cat >> wireproxy.conf <<EOH

[Socks5]
BindAddress = 127.0.0.1:${wg_socks_port}
EOH

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

valid_hostport(){
  local value="$1"
  local host port

  if [[ "$value" != *:* ]]; then
    return 1
  fi

  host="${value%:*}"
  port="${value##*:}"

  if [[ -z "$host" || ! "$port" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  if (( port < 1 || port > 65535 )); then
    return 1
  fi

  return 0
}

configure_proxy_landing(){
  local mode="$1"
  local scheme="$2"
  local mode_name

  if [[ "$mode" == "1" ]]; then
    mode_name="HTTP"
  else
    mode_name="SOCKS5"
  fi

  read -r -p "请输入${mode_name}落地地址(host:port):" proxy_hostport
  if ! valid_hostport "${proxy_hostport:-}"; then
    say "${mode_name}落地地址格式不正确，已回退直连"
    landing_mode="0"
    forward_url=""
    return
  fi

  read -r -p "请输入${mode_name}用户名(可留空):" proxy_user
  if [[ -n "$proxy_user" ]]; then
    read -r -p "请输入${mode_name}密码:" proxy_pass
    forward_url="${scheme}://${proxy_user}:${proxy_pass}@${proxy_hostport}"
  else
    forward_url="${scheme}://${proxy_hostport}"
  fi
}

configure_landing(){
  local default_mode
  default_mode="${landing_mode:-0}"

  say "落地模式：0.直连[默认] 1.HTTP落地 2.SOCKS5落地 3.WG落地"
  say "当前选择: $(landing_mode_text "$default_mode")"
  read -r -p "请选择落地模式(默认${default_mode}):" landing_mode
  landing_mode="${landing_mode:-$default_mode}"
  forward_url=""

  case "$landing_mode" in
    0) ;;
    1)
      configure_proxy_landing "1" "http"
      ;;
    2)
      configure_proxy_landing "2" "socks5"
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

  say "落地设置完成: $(landing_mode_text "$landing_mode")"
}
