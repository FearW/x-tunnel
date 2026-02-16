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
wg_private_key="${wg_private_key}"
wg_address="${wg_address}"
wg_dns="${wg_dns}"
wg_peer_public_key="${wg_peer_public_key}"
wg_preshared_key="${wg_preshared_key}"
wg_endpoint="${wg_endpoint}"
wg_allowed_ips="${wg_allowed_ips}"
EOH
  chmod 600 "$path" || true
  say "[OK] 已保存WG配置: $path"
}

list_wg_profiles(){
  if [[ -d "$WG_PROFILE_DIR" ]]; then
    for f in "${WG_PROFILE_DIR}"/*.conf; do
      [[ -f "$f" ]] || continue
      basename "$f" .conf
    done
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
  read -r -p "请输入AllowedIPs(默认0.0.0.0/0):" wg_allowed_ips
  wg_allowed_ips="${wg_allowed_ips:-0.0.0.0/0}"

  read -r -p "是否保存该WG配置供后续热切换使用(1.是,0.否,默认1):" save_wg
  save_wg="${save_wg:-1}"
  if [[ "$save_wg" == "1" ]]; then
    read -r -p "请输入WG配置名(如 hk-wg):" wg_profile_name
    if [[ -n "${wg_profile_name:-}" ]]; then
      save_wg_profile "$wg_profile_name"
    fi
  fi
}

check_port_listening(){
  local port="$1"
  if command -v ss &>/dev/null; then
    ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE ":${port}$"
  elif command -v netstat &>/dev/null; then
    netstat -lnt 2>/dev/null | awk '{print $4}' | grep -qE ":${port}$"
  else
    (echo >/dev/tcp/127.0.0.1/"${port}") 2>/dev/null
  fi
}

kill_wireproxy(){
  stop_screen wg
  pkill -f wireproxy-linux 2>/dev/null || true
  sleep 1
  if pgrep -f wireproxy-linux &>/dev/null; then
    pkill -9 -f wireproxy-linux 2>/dev/null || true
    sleep 1
  fi
}

verify_landing(){
  local mode="${1:-0}"
  local url="${2:-}"
  local timeout=8

  case "$mode" in
    1)
      if [[ -z "$url" ]]; then
        say "[CHECK] HTTP落地地址为空，跳过检测"
        return 1
      fi
      say "[CHECK] 正在检测HTTP代理可用性..."
      local http_code
      http_code="$(curl -4 -x "$url" -s --connect-timeout "$timeout" -o /dev/null -w '%{http_code}' "http://cp.cloudflare.com" 2>/dev/null || echo "000")"
      if [[ "$http_code" != "000" ]]; then
        say "[CHECK] HTTP代理可用 ✓ (HTTP ${http_code})"
        return 0
      else
        say "[CHECK] HTTP代理不可用 ✗ (地址: ${url})"
        return 1
      fi
      ;;
    2)
      if [[ -z "$url" ]]; then
        say "[CHECK] SOCKS5落地地址为空，跳过检测"
        return 1
      fi
      local check_url="${url/socks5:\/\//socks5h:\/\/}"
      say "[CHECK] 正在检测SOCKS5代理可用性..."
      local http_code
      http_code="$(curl -4 -x "$check_url" -s --connect-timeout "$timeout" -o /dev/null -w '%{http_code}' "http://cp.cloudflare.com" 2>/dev/null || echo "000")"
      if [[ "$http_code" != "000" ]]; then
        say "[CHECK] SOCKS5代理可用 ✓ (HTTP ${http_code})"
        return 0
      else
        say "[CHECK] SOCKS5代理不可用 ✗ (地址: ${url})"
        return 1
      fi
      ;;
    3)
      local wg_port="${wg_socks_port:-}"
      if [[ -z "$wg_port" ]]; then
        say "[CHECK] WG SOCKS端口未知，跳过检测"
        return 1
      fi
      say "[CHECK] 正在检测WG落地可用性..."
      if ! check_port_listening "$wg_port"; then
        say "[CHECK] WG SOCKS端口 ${wg_port} 未监听 ✗"
        return 1
      fi
      local http_code
      http_code="$(curl -4 -x "socks5h://127.0.0.1:${wg_port}" -s --connect-timeout "$timeout" -o /dev/null -w '%{http_code}' "http://cp.cloudflare.com" 2>/dev/null || echo "000")"
      if [[ "$http_code" != "000" ]]; then
        say "[CHECK] WG落地可用 ✓ (socks5://127.0.0.1:${wg_port}, HTTP ${http_code})"
        return 0
      else
        say "[CHECK] WG落地出口不通 ✗"
        return 1
      fi
      ;;
    0|*)
      say "[CHECK] 直连模式，无需落地检测 ✓"
      return 0
      ;;
  esac
}

start_wg_landing(){
  local arch download_bin_name
  arch="$(uname -m)"

  case "$arch" in
    x86_64|x64|amd64) download_bin_name="wireproxy_linux_amd64" ;;
    i386|i686) download_bin_name="wireproxy_linux_386" ;;
    armv8|arm64|aarch64) download_bin_name="wireproxy_linux_arm64" ;;
    *)
      say "当前架构${arch}不支持 wireguard 落地"
      return 1
      ;;
  esac

  local script_dir wireproxy_path wireproxy_conf
  script_dir="${SCRIPT_DIR:-$(pwd)}"
  wireproxy_path="${script_dir}/wireproxy-linux"
  wireproxy_conf="${script_dir}/wireproxy.conf"

  local download_url="https://github.com/pufferffish/wireproxy/releases/download/v1.0.6/${download_bin_name}.tar.gz"

  if [[ ! -s "${wireproxy_path}" ]]; then
    say "正在下载 Wireproxy (v1.0.6)..."
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    if curl -fsSL "${download_url}" -o "${tmp_dir}/wireproxy.tar.gz"; then
      say "下载成功，正在解压..."
      tar -xzf "${tmp_dir}/wireproxy.tar.gz" -C "${tmp_dir}" >/dev/null 2>&1
      local found_bin=""
      if [[ -f "${tmp_dir}/wireproxy" ]]; then
        found_bin="${tmp_dir}/wireproxy"
      else
        found_bin="$(find "${tmp_dir}" -type f -name 'wireproxy*' ! -name '*.tar.gz' | head -n1)"
      fi
      if [[ -n "$found_bin" && -f "$found_bin" ]]; then
        mv "$found_bin" "${wireproxy_path}"
      else
        say "[FAIL] 解压后未找到 wireproxy 二进制文件"
      fi
      rm -rf "${tmp_dir}"
    else
      rm -rf "${tmp_dir}"
      say "[FAIL] 下载失败，请检查网络连接。"
    fi
  fi

  if [[ ! -s "${wireproxy_path}" ]]; then
    say "[FAIL] wireproxy 二进制获取失败。"
    say "[INFO] 手动修复方法：请下载 ${download_url} 解压并将二进制文件命名为 ${wireproxy_path}"
    return 1
  fi
  chmod +x "${wireproxy_path}"

  local use_saved wg_profile_name existing_profiles wg_log_file

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

  if [[ -z "${wg_private_key:-}" || -z "${wg_address:-}" || -z "${wg_peer_public_key:-}" ]]; then
    say "[FAIL] WG参数不完整：PrivateKey/Address/Peer PublicKey 不能为空"
    return 1
  fi

  if ! valid_hostport "${wg_endpoint:-}"; then
    say "[FAIL] WG Endpoint 格式错误，请使用 host:port 或 [ipv6]:port"
    return 1
  fi

  kill_wireproxy

  wg_log_file="${HOME}/.suoha_wireproxy.log"

  local wg_start_ok=0
  local wg_try
  for wg_try in 1 2 3; do
    wg_socks_port="$(get_free_port)"

    {
      cat <<EOH
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
        printf 'PresharedKey = %s\n' "$wg_preshared_key"
      fi
      cat <<EOH

[Socks5]
BindAddress = 127.0.0.1:${wg_socks_port}
EOH
    } > "${wireproxy_conf}"

    : > "${wg_log_file}"

    screen -dmUS wg sh -c "exec \"${wireproxy_path}\" -c \"${wireproxy_conf}\" >> \"${wg_log_file}\" 2>&1"

    local wg_ready=0
    for _ in $(seq 1 10); do
      if check_port_listening "${wg_socks_port}"; then
        wg_ready=1
        break
      fi
      if [[ -s "${wg_log_file}" ]] && grep -q "address already in use" "${wg_log_file}"; then
        say "[WARN] 端口 ${wg_socks_port} 被占用，重试第 ${wg_try} 次..."
        kill_wireproxy
        break
      fi
      sleep 1
    done

    if [[ "$wg_ready" == "1" ]]; then
      wg_start_ok=1
      break
    fi
  done

  if [[ "$wg_start_ok" == "1" ]]; then
    forward_url="socks5://127.0.0.1:${wg_socks_port}"
    say "[OK] WG落地已启动，本地Socks5: 127.0.0.1:${wg_socks_port}"
    verify_landing "3" "$forward_url"
    return 0
  fi

  say "[FAIL] WG落地启动失败（重试3次均失败）"
  if [[ -s "${wg_log_file:-}" ]]; then
    say "[INFO] wireproxy 最近日志："
    tail -n 20 "${wg_log_file}"
  else
    say "[INFO] 未捕获到 wireproxy 日志，可检查 screen 会话: screen -r wg"
  fi
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

  if [[ -z "$value" || "$value" != *:* ]]; then
    return 1
  fi

  if [[ "$value" == \[*\]:* ]]; then
    host="${value%]:*}]"
    port="${value##*]:}"
  else
    host="${value%:*}"
    port="${value##*:}"
  fi

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

  verify_landing "$mode" "$forward_url"
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
