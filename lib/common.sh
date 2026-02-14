say(){ printf "%s\n" "$*"; }

os_index(){
  local n=0
  local pretty
  pretty="$(grep -i PRETTY_NAME /etc/os-release | cut -d '"' -f2 | awk '{print $1}' || true)"
  for i in "${linux_os[@]}"; do
    if [[ "$i" == "$pretty" ]]; then
      echo "$n"
      return
    fi
    n=$((n+1))
  done
  echo "当前系统$(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2)没有适配"
  echo "默认使用APT包管理器"
  echo 0
}

need_cmd(){
  local cmd="$1" idx="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    ${linux_update[$idx]} >/dev/null 2>&1 || true
    ${linux_install[$idx]} "$cmd" >/dev/null 2>&1 || true
  fi
}

get_free_port() {
  while true; do
    local PORT=$((RANDOM % 64512 + 1024))
    if command -v ss >/dev/null 2>&1; then
      if ! ss -lnt | awk '{print $4}' | grep -qE ":${PORT}$"; then
        echo "$PORT"; return
      fi
    else
      if command -v lsof >/dev/null 2>&1; then
        if ! lsof -i TCP:"$PORT" >/dev/null 2>&1; then
          echo "$PORT"; return
        fi
      else
        echo "$PORT"; return
      fi
    fi
  done
}

stop_screen(){
  local name="$1"
  screen -S "$name" -X quit >/dev/null 2>&1 || true
  for _ in $(seq 1 10); do
    if ! screen -list 2>/dev/null | grep -q "\.${name}[[:space:]]"; then
      return
    fi
    sleep 1
  done
}

screen_exists(){
  local name="$1"
  screen -list 2>/dev/null | grep -q "\.${name}[[:space:]]"
}

download_bin(){
  local url="$1" out="$2"
  if [[ ! -f "$out" ]]; then
    curl -fsSL "$url" -o "$out"
  fi
}

detect_ws_port(){
  ss -lntp 2>/dev/null | awk '/x-tunnel-linux/ && /127\.0\.0\.1:/ {print $4}' | sed -E 's/.*:([0-9]+)$/\1/' | head -n1
}

ws_listening(){
  local p="$1"
  [[ -n "$p" ]] && ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE ":${p}$"
}
