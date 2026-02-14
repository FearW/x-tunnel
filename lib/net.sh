http_head(){
  local host="$1"
  curl -I "https://${host}" 2>/dev/null | sed -n '1,8p' || true
}

tcp_check(){
  local host="$1"
  if command -v nc >/dev/null 2>&1; then
    nc -vz "$host" 443 || true
  fi
}

tls_check(){
  local host="$1"
  if command -v openssl >/dev/null 2>&1; then
    echo | openssl s_client -connect "${host}:443" -servername "${host}" 2>/dev/null | sed -n '1,12p' || true
  fi
}

self_check(){
  local bind_domain="${1:-}"
  local try_domain="${2:-}"
  local wsport="${3:-}"
  echo
  say "=============================="
  say "自检 / Debug"
  say "=============================="
  say "screen sessions:"
  screen -list 2>/dev/null || true
  echo
  if [[ -z "$wsport" ]]; then
    wsport="$(detect_ws_port || true)"
  fi
  if [[ -n "$wsport" ]]; then
    say "[OK] 本地监听: 127.0.0.1:${wsport}"
    ss -lntp 2>/dev/null | grep -E "127\.0\.0\.1:${wsport}\b" || true
  else
    say "[FAIL] 未检测到 x-tunnel 本地监听端口"
  fi
  echo
  if [[ -n "$bind_domain" ]]; then
    say "== 绑定域名检测: ${bind_domain} =="
    tcp_check "$bind_domain"
    tls_check "$bind_domain"
    http_head "$bind_domain"
    echo
  fi
  if [[ -n "$try_domain" ]]; then
    say "== 临时域名检测: ${try_domain} =="
    tcp_check "$try_domain"
    tls_check "$try_domain"
    http_head "$try_domain"
    echo
  fi
  cat <<EOH
解释：
- 401 Unauthorized：正常！说明已到达 x-tunnel，但需要 token（你设的 token）。
- 200 OK：也可能正常（HEAD/探测请求），请用客户端带 token 真正连接测试。
- 502 Bad Gateway：Cloudflare 连不到本地服务（端口/协议/路由类型不匹配）。
- 530：被 Cloudflare Access/应用策略拦截（到 Zero Trust → Access → Applications 处理）。
若绑定域名失败但临时域名可用：
- 优先检查 Cloudflare Public Hostname 指向是否是 http://127.0.0.1:${wsport}（强烈建议固定端口）
- 确认同一个 hostname 没有多条冲突路由
EOH
}

apply_system_net_tuning(){
  local conf_file="/etc/sysctl.d/99-suoha-tunnel.conf"

  if [[ "$(id -u)" != "0" ]]; then
    say "[WARN] 当前不是 root，跳过系统层网络优化（BBR+FQ）"
    return
  fi

  if command -v modprobe >/dev/null 2>&1; then
    modprobe tcp_bbr >/dev/null 2>&1 || true
  fi

  cat > "$conf_file" <<EOH
# managed by suoha-x.sh
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 33554432
net.ipv4.tcp_wmem=4096 65536 33554432
net.ipv4.tcp_fastopen=3
EOH

  sysctl --system >/dev/null 2>&1 || true

  local current_cc current_qdisc
  current_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  current_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"

  say "系统网络优化结果: tcp_congestion_control=${current_cc:-unknown}, default_qdisc=${current_qdisc:-unknown}"
  if [[ "$current_cc" == "bbr" && "$current_qdisc" == "fq" ]]; then
    say "[OK] 已启用 BBR + FQ"
  else
    say "[WARN] 内核可能不支持完整 BBR+FQ，请检查内核版本或宿主机限制"
  fi
}
