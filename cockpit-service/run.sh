#!/usr/bin/env bash
# =============================================================================
# cockpit-manager.sh - Cài đặt / cập nhật / gỡ / cấu hình Cockpit
#
# Dùng:
#   sudo ./cockpit-manager.sh                 # menu tương tác
#   sudo ./cockpit-manager.sh [-y] [-c FILE] <lệnh>
#
# Lệnh:   install | update | uninstall | restart | apply | status
# Tuỳ chọn:
#   -y, --yes        tự trả lời "yes" cho mọi câu hỏi (dùng cho CI/Ansible)
#   -c, --config F   đường dẫn file config (mặc định: cockpit.config.yaml cạnh script)
#   -h, --help       hiện hướng dẫn
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/cockpit.config.yaml}"
COCKPIT_CONF="${COCKPIT_CONF:-/etc/cockpit/cockpit.conf}"
DROPIN_DIR="${DROPIN_DIR:-/etc/systemd/system/cockpit.socket.d}"
DROPIN_FILE="$DROPIN_DIR/listen.conf"
DEFAULT_PORT=9090

ASSUME_YES=0
YQ=""
PKG_MGR="" OS_ID="" OS_NAME="" OS_CODENAME=""

# Giá trị đọc từ config
CFG_PORT="" CFG_PROXY="" CFG_PLUGIN_COUNT=0
CFG_DOMAINS=()

# ----------------------------------------------------------------------------- UI
if [[ -t 1 ]]; then
  C_R=$'\e[31m' C_G=$'\e[32m' C_Y=$'\e[33m' C_B=$'\e[1m' C_D=$'\e[2m' C_N=$'\e[0m'
else
  C_R="" C_G="" C_Y="" C_B="" C_D="" C_N=""
fi
ok()   { echo "${C_G}[OK]${C_N} $*"; }
fail() { echo "${C_R}[FAIL]${C_N} $*" >&2; }
warn() { echo "${C_Y}[!]${C_N} $*"; }
info() { echo "${C_D}-->${C_N} $*"; }
die()  { fail "$*"; exit 1; }
title(){ echo; echo "${C_B}== $* ==${C_N}"; }

# ask "Câu hỏi" Y|N  -> return 0 nếu đồng ý
ask() {
  local q=$1 def=$2 hint ans
  if [[ $def == Y ]]; then hint="[Y/n]"; else hint="[y/N]"; fi
  if (( ASSUME_YES )); then echo "$q $hint y (auto)"; return 0; fi
  read -r -p "$q $hint " ans </dev/tty || ans=""
  ans=${ans:-$def}
  [[ $ans =~ ^[Yy] ]]
}

pause() { (( ASSUME_YES )) || read -r -p "Nhấn Enter để tiếp tục..." _ </dev/tty || true; }

# ----------------------------------------------------------------------------- Hệ thống
require_root() { (( EUID == 0 )) || die "Cần chạy bằng root (sudo $0)"; }

detect_os() {
  [[ -r /etc/os-release ]] || die "Không tìm thấy /etc/os-release"
  OS_ID=$(. /etc/os-release; echo "${ID:-unknown}")
  OS_NAME=$(. /etc/os-release; echo "${PRETTY_NAME:-$OS_ID}")
  OS_CODENAME=$(. /etc/os-release; echo "${VERSION_CODENAME:-}")
  if command -v apt-get >/dev/null 2>&1; then PKG_MGR=apt
  elif command -v dnf >/dev/null 2>&1;   then PKG_MGR=dnf
  elif command -v yum >/dev/null 2>&1;   then PKG_MGR=yum
  else die "Distro không được hỗ trợ (cần apt hoặc dnf/yum)"; fi
  command -v systemctl >/dev/null 2>&1 || die "Cần systemd"
}

pkg_installed() {
  case $PKG_MGR in
    apt) dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed" ;;
    *)   rpm -q "$1" >/dev/null 2>&1 ;;
  esac
}

pkg_version() {
  case $PKG_MGR in
    apt) dpkg-query -W -f='${Version}' "$1" 2>/dev/null ;;
    *)   rpm -q --qf '%{VERSION}-%{RELEASE}' "$1" 2>/dev/null ;;
  esac
}

installed_cockpit_pkgs() {
  case $PKG_MGR in
    apt) dpkg-query -W -f='${Package} ${Status}\n' 'cockpit*' 2>/dev/null | awk '/install ok installed/{print $1}' ;;
    *)   rpm -qa --qf '%{NAME}\n' 'cockpit*' 2>/dev/null ;;
  esac
}

pkg_install() {
  case $PKG_MGR in
    apt) DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    *)   "$PKG_MGR" install -y "$@" ;;
  esac
}

APT_UPDATED=0
apt_update_once() {
  [[ $PKG_MGR == apt ]] || return 0
  (( APT_UPDATED )) && return 0
  info "apt-get update ..."
  apt-get update -qq && APT_UPDATED=1
}

# Ubuntu/Debian: dùng backports nếu có (bản cockpit mới hơn, plugin như cockpit-compose cần >= 300)
apt_target_args() {
  [[ $PKG_MGR == apt && -n $OS_CODENAME ]] || return 0
  if apt-cache policy cockpit 2>/dev/null | grep -q "${OS_CODENAME}-backports"; then
    echo "-t ${OS_CODENAME}-backports"
  fi
}

ensure_cmd() { # ensure_cmd <lệnh> <gói>
  command -v "$1" >/dev/null 2>&1 && return 0
  info "Cài $2 ..."
  apt_update_once
  pkg_install "$2" >/dev/null || die "Không cài được $2"
}

ensure_yq() {
  [[ -n $YQ ]] && return 0
  local c
  for c in yq /usr/local/bin/yq /usr/local/bin/yq-go; do
    if command -v "$c" >/dev/null 2>&1 && "$c" --version 2>&1 | grep -qi mikefarah; then
      YQ=$(command -v "$c"); return 0
    fi
  done
  local arch
  case $(uname -m) in
    x86_64|amd64)  arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    armv7l|armv6l) arch=arm ;;
    *) die "Không hỗ trợ kiến trúc $(uname -m) để tải yq" ;;
  esac
  # Tránh ghi đè một bản yq khác (python yq) đã có sẵn
  local dest=/usr/local/bin/yq
  [[ -e $dest ]] && dest=/usr/local/bin/yq-go
  ensure_cmd curl curl
  info "Tải yq (mikefarah) vào $dest ..."
  curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${arch}" -o "$dest.tmp" \
    && chmod +x "$dest.tmp" && mv "$dest.tmp" "$dest" || { rm -f "$dest.tmp"; die "Tải yq thất bại"; }
  YQ=$dest
  ok "Đã cài $("$YQ" --version)"
}

# ----------------------------------------------------------------------------- Config YAML
load_config() {
  [[ -f $CONFIG_FILE ]] || { fail "Không tìm thấy file config: $CONFIG_FILE"; return 1; }
  ensure_yq
  "$YQ" -e '.' "$CONFIG_FILE" >/dev/null 2>&1 || { fail "File YAML không hợp lệ: $CONFIG_FILE"; return 1; }

  CFG_PORT=$("$YQ" ".port // $DEFAULT_PORT" "$CONFIG_FILE")
  CFG_PROXY=$("$YQ" '.reverse_proxy // false' "$CONFIG_FILE")
  mapfile -t CFG_DOMAINS < <("$YQ" '(.domains // [])[]' "$CONFIG_FILE")
  CFG_PLUGIN_COUNT=$("$YQ" '(.plugins // []) | length' "$CONFIG_FILE")

  if ! [[ $CFG_PORT =~ ^[0-9]+$ ]] || (( CFG_PORT < 1 || CFG_PORT > 65535 )); then
    fail "port không hợp lệ: $CFG_PORT"; return 1
  fi
  [[ $CFG_PROXY == true ]] || CFG_PROXY=false
  return 0
}

plugin_field() { # plugin_field <index> <field>
  "$YQ" ".plugins[$1].$2 // \"\"" "$CONFIG_FILE"
}

# Danh sách Origins mong muốn (cách nhau bởi dấu cách)
desired_origins() {
  local d out=()
  for d in "${CFG_DOMAINS[@]}"; do
    d="${d#"${d%%[![:space:]]*}"}"; d="${d%"${d##*[![:space:]]}"}"   # trim
    [[ -z $d || $d == null ]] && continue
    if [[ $d =~ ^https?:// ]]; then
      out+=("${d%/}")
    else
      # IPv6 trần -> bọc []
      [[ $d =~ ^[0-9a-fA-F:]+$ && $d == *:*:* ]] && d="[$d]"
      out+=("https://$d:$CFG_PORT")
      [[ $CFG_PROXY == true ]] && out+=("https://$d")
    fi
  done
  (( ${#out[@]} )) || return 0
  printf '%s\n' "${out[@]}" | awk '!seen[$0]++' | paste -sd' ' -
}

# ----------------------------------------------------------------------------- cockpit.conf (INI)
ini_get() { # ini_get <key>  (trong [WebService])
  [[ -f $COCKPIT_CONF ]] || return 0
  awk -v k="$1" '
    /^[[:space:]]*\[/ { sec = ($0 ~ /^[[:space:]]*\[WebService\]/); next }
    sec {
      l = $0; sub(/^[[:space:]]+/, "", l)
      if (index(l, k) == 1) {
        r = substr(l, length(k) + 1)
        if (r ~ /^[[:space:]]*=/) { sub(/^[[:space:]]*=[[:space:]]*/, "", r); print r; exit }
      }
    }' "$COCKPIT_CONF"
}

ini_set() { # ini_set <key> <value>   (value rỗng = xoá key)
  local k=$1 v=$2 tmp
  if [[ -z $v && ! -f $COCKPIT_CONF ]]; then return 0; fi
  mkdir -p "$(dirname "$COCKPIT_CONF")"; touch "$COCKPIT_CONF"
  tmp=$(mktemp)
  awk -v k="$k" -v v="$v" '
    function iskey(l,  r) {
      sub(/^[[:space:]]+/, "", l)
      if (index(l, k) != 1) return 0
      r = substr(l, length(k) + 1); return (r ~ /^[[:space:]]*=/)
    }
    function flush() { while (blanks > 0) { print ""; blanks-- } }
    /^[[:space:]]*\[/ {
      if (sec && !done && v != "") { print k " = " v; done = 1 }
      flush()
      sec = ($0 ~ /^[[:space:]]*\[WebService\]/); if (sec) found = 1
      print; next
    }
    sec && /^[[:space:]]*$/ { blanks++; next }
    sec && iskey($0) { flush(); if (!done && v != "") { print k " = " v; done = 1 }; next }
    { flush(); print }
    END {
      if (sec && v != "" && !done) { print k " = " v; done = 1 }
      flush()
      if (v != "" && !done) {
        if (!found) { if (NR > 0) print ""; print "[WebService]" }
        print k " = " v
      }
    }' "$COCKPIT_CONF" > "$tmp" && cat "$tmp" > "$COCKPIT_CONF"
  rm -f "$tmp"
}

backup_conf() {
  [[ -f $COCKPIT_CONF ]] || return 0
  local b; b="$COCKPIT_CONF.bak.$(date +%Y%m%d-%H%M%S)"
  cp -p "$COCKPIT_CONF" "$b" && info "Backup: $b"
}

# ----------------------------------------------------------------------------- Port / firewall / SELinux
current_port() {
  local l
  l=$(systemctl show cockpit.socket -p Listen --value 2>/dev/null | head -n1)
  if [[ $l =~ :([0-9]+)[[:space:]] ]]; then echo "${BASH_REMATCH[1]}"; return; fi
  if [[ -f $DROPIN_FILE ]]; then
    awk -F= '/^ListenStream=[^[:space:]]/{p=$2} END{gsub(/.*:/,"",p); if(p!="") print p}' "$DROPIN_FILE"; return
  fi
  echo "$DEFAULT_PORT"
}

firewall_open() {
  local p=$1
  if systemctl is-active -q firewalld 2>/dev/null; then
    firewall-cmd -q --permanent --add-port="$p/tcp" && firewall-cmd -q --reload \
      && ok "firewalld: mở $p/tcp" || warn "firewalld: không mở được $p/tcp"
  elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$p/tcp" >/dev/null && ok "ufw: mở $p/tcp" || warn "ufw: không mở được $p/tcp"
  else
    info "Không có firewalld/ufw đang chạy, bỏ qua bước mở port"
  fi
}

firewall_close() {
  local p=$1
  if systemctl is-active -q firewalld 2>/dev/null; then
    firewall-cmd -q --permanent --remove-port="$p/tcp" 2>/dev/null && firewall-cmd -q --reload && info "firewalld: đóng $p/tcp"
  elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw delete allow "$p/tcp" >/dev/null 2>&1 && info "ufw: đóng $p/tcp"
  fi
  return 0
}

selinux_port() {
  local p=$1
  [[ $p == "$DEFAULT_PORT" ]] && return 0
  command -v getenforce >/dev/null 2>&1 || return 0
  [[ $(getenforce 2>/dev/null) == Disabled ]] && return 0
  if ! command -v semanage >/dev/null 2>&1; then
    pkg_install policycoreutils-python-utils >/dev/null 2>&1 \
      || { warn "Thiếu semanage, hãy tự chạy: semanage port -a -t websm_port_t -p tcp $p"; return 0; }
  fi
  if semanage port -l 2>/dev/null | awk '$1=="websm_port_t"' | grep -qw "$p"; then return 0; fi
  if semanage port -a -t websm_port_t -p tcp "$p" 2>/dev/null || semanage port -m -t websm_port_t -p tcp "$p" 2>/dev/null; then
    ok "SELinux: gán port $p cho websm_port_t"
  else
    warn "SELinux: không gán được port $p"
  fi
}

apply_port() { # apply_port <mới> <cũ>
  local new=$1 old=$2
  if [[ $new == "$DEFAULT_PORT" ]]; then
    rm -f "$DROPIN_FILE"; rmdir "$DROPIN_DIR" 2>/dev/null || true
  else
    mkdir -p "$DROPIN_DIR"
    printf '[Socket]\nListenStream=\nListenStream=%s\n' "$new" > "$DROPIN_FILE"
  fi
  ok "Port: $new"
  selinux_port "$new"
  firewall_open "$new"
  [[ -n $old && $old != "$new" && $old != "$DEFAULT_PORT" ]] && firewall_close "$old"
  systemctl daemon-reload
}

# ----------------------------------------------------------------------------- Plugins
plugin_check() { # 0 = đã cài, 1 = chưa, 2 = không có lệnh check
  [[ -z $1 ]] && return 2
  PKG_MGR=$PKG_MGR OS_ID=$OS_ID bash -c "$1" >/dev/null 2>&1
}

plugin_install() { # plugin_install <name> <install> <check>
  local name=$1 cmd=$2 check=$3 wd rc
  if [[ -z $cmd ]]; then fail "$name: không có lệnh install"; return 1; fi
  info "Cài plugin $name ..."
  wd=$(mktemp -d)
  ( cd "$wd" && PKG_MGR=$PKG_MGR OS_ID=$OS_ID bash -eo pipefail -c "$cmd" ) 2>&1 | sed 's/^/    /'
  rc=${PIPESTATUS[0]}
  rm -rf "$wd"
  if (( rc != 0 )); then fail "$name: lệnh install lỗi (exit $rc)"; return 1; fi
  if [[ -n $check ]] && ! plugin_check "$check"; then
    fail "$name: install chạy xong nhưng check vẫn báo chưa cài"; return 1
  fi
  ok "$name: đã cài"
}

# ----------------------------------------------------------------------------- Service
restart_cockpit() {
  systemctl daemon-reload
  systemctl stop cockpit.service 2>/dev/null || true
  if systemctl restart cockpit.socket; then
    sleep 1
    ok "Đã restart Cockpit, đang lắng nghe port $(current_port)"
  else
    fail "Restart cockpit.socket thất bại, xem: journalctl -u cockpit.socket -n 50"; return 1
  fi
}

require_installed() {
  pkg_installed cockpit && return 0
  warn "Cockpit chưa được cài. Chọn Install trước."; return 1
}

# ----------------------------------------------------------------------------- Lệnh
show_status() {
  title "Trạng thái"
  echo "  OS        : $OS_NAME ($PKG_MGR)"
  if pkg_installed cockpit; then
    local st; st=$(systemctl is-active cockpit.socket 2>/dev/null)
    echo "  Cockpit   : ${C_G}đã cài${C_N} $(pkg_version cockpit)"
    echo "  Socket    : $st, port $(current_port)"
  else
    echo "  Cockpit   : ${C_Y}chưa cài${C_N}"
  fi
  if [[ -f $CONFIG_FILE ]]; then echo "  Config    : $CONFIG_FILE"
  else echo "  Config    : ${C_Y}không thấy $CONFIG_FILE${C_N}"; fi
}

do_install() {
  title "Install Cockpit"
  local targ
  if [[ $PKG_MGR == apt ]]; then
    apt_update_once
    targ=$(apt_target_args)
    [[ -n $targ ]] && info "Dùng backports: $targ"
    # shellcheck disable=SC2086
    DEBIAN_FRONTEND=noninteractive apt-get install -y $targ cockpit || { fail "Cài cockpit thất bại"; return 1; }
  else
    "$PKG_MGR" install -y cockpit || { fail "Cài cockpit thất bại"; return 1; }
  fi
  systemctl enable --now cockpit.socket && ok "Đã bật cockpit.socket" || { fail "Không bật được cockpit.socket"; return 1; }
  ok "Cockpit $(pkg_version cockpit)"

  if [[ -f $CONFIG_FILE ]] && load_config; then
    info "Áp dụng config $CONFIG_FILE"
    firewall_open "$CFG_PORT"
    cmd_apply 1
  else
    warn "Không đọc được $CONFIG_FILE, dùng cấu hình mặc định (port $DEFAULT_PORT)"
    firewall_open "$DEFAULT_PORT"
  fi
}

do_update() {
  title "Update Cockpit"
  local pkgs; mapfile -t pkgs < <(installed_cockpit_pkgs)
  (( ${#pkgs[@]} )) || { warn "Không tìm thấy gói cockpit nào"; return 1; }
  info "Các gói: ${pkgs[*]}"
  local before; before=$(pkg_version cockpit)
  if [[ $PKG_MGR == apt ]]; then
    apt_update_once
    local targ; targ=$(apt_target_args)
    # shellcheck disable=SC2086
    DEBIAN_FRONTEND=noninteractive apt-get install --only-upgrade -y $targ "${pkgs[@]}" || { fail "Update thất bại"; return 1; }
  else
    "$PKG_MGR" upgrade -y "${pkgs[@]}" || { fail "Update thất bại"; return 1; }
  fi
  local after; after=$(pkg_version cockpit)
  if [[ $before == "$after" ]]; then ok "Đã là bản mới nhất ($after)"
  else ok "Cockpit $before -> $after"; systemctl try-restart cockpit.service 2>/dev/null || true; fi
}

cmd_install_update() {
  if pkg_installed cockpit; then
    ok "Cockpit đã cài ($(pkg_version cockpit))"
    if ask "Có update không?" N; then do_update; fi
  else
    warn "Cockpit chưa được cài"
    if ask "Có install không?" Y; then do_install; fi
  fi
}

cmd_uninstall() {
  title "Uninstall Cockpit"
  if ! pkg_installed cockpit; then warn "Cockpit chưa được cài"; return 0; fi
  ask "Chắc chắn gỡ Cockpit?" N || { info "Huỷ"; return 0; }
  local port; port=$(current_port)
  local pkgs; mapfile -t pkgs < <(installed_cockpit_pkgs)
  systemctl disable --now cockpit.socket cockpit.service >/dev/null 2>&1 || true
  info "Gỡ: ${pkgs[*]}"
  if [[ $PKG_MGR == apt ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get purge -y "${pkgs[@]}" || { fail "Gỡ thất bại"; return 1; }
  else
    "$PKG_MGR" remove -y "${pkgs[@]}" || { fail "Gỡ thất bại"; return 1; }
  fi
  ok "Đã gỡ các gói Cockpit"
  if ask "Xoá luôn /etc/cockpit, port override và plugin tự cài trong /usr/local/share/cockpit?" N; then
    rm -rf /etc/cockpit "$DROPIN_DIR" /usr/local/share/cockpit
    systemctl daemon-reload
    [[ $port != "$DEFAULT_PORT" ]] && firewall_close "$port"
    ok "Đã xoá config và plugin tự cài"
  fi
}

cmd_restart() {
  title "Restart Cockpit"
  require_installed || return 1
  restart_cockpit
}

# cmd_apply [auto]   auto=1: không hỏi (dùng khi install)
cmd_apply() {
  local auto=${1:-0}
  title "Check config"
  require_installed || return 1
  load_config || return 1

  local cur_port cur_origins cur_proxy new_origins changed=0
  cur_port=$(current_port)
  cur_origins=$(ini_get Origins)
  [[ -n $(ini_get ProtocolHeader) ]] && cur_proxy=true || cur_proxy=false
  new_origins=$(desired_origins)

  local mark_same="${C_D}(không đổi)${C_N}" mark_diff="${C_Y}[THAY ĐỔI]${C_N}"
  local m

  [[ $cur_port == "$CFG_PORT" ]] && m=$mark_same || { m=$mark_diff; changed=1; }
  printf '  %-14s %s -> %s  %s\n' "Port" "$cur_port" "$CFG_PORT" "$m"

  [[ $cur_proxy == "$CFG_PROXY" ]] && m=$mark_same || { m=$mark_diff; changed=1; }
  printf '  %-14s %s -> %s  %s\n' "Reverse proxy" "$cur_proxy" "$CFG_PROXY" "$m"

  [[ $cur_origins == "$new_origins" ]] && m=$mark_same || { m=$mark_diff; changed=1; }
  printf '  %-14s %s\n' "Origins" "$m"
  echo   "    hiện tại : ${cur_origins:-(trống)}" | sed 's/ https/\n               https/g; s/ http:/\n               http:/g'
  echo   "    trong file:${new_origins:+ }${new_origins:-(trống)}" | sed 's/ https/\n               https/g; s/ http:/\n               http:/g'

  title "Plugins (${CFG_PLUGIN_COUNT})"
  local i name check rc missing=()
  for (( i = 0; i < CFG_PLUGIN_COUNT; i++ )); do
    name=$(plugin_field "$i" name); [[ -z $name ]] && name="plugin#$i"
    check=$(plugin_field "$i" check)
    plugin_check "$check"; rc=$?
    case $rc in
      0) printf '  %s[x]%s %-25s đã cài\n' "$C_G" "$C_N" "$name" ;;
      2) printf '  %s[?]%s %-25s không có lệnh check, sẽ chạy install\n' "$C_Y" "$C_N" "$name"; missing+=("$i") ;;
      *) printf '  %s[ ]%s %-25s chưa cài\n' "$C_Y" "$C_N" "$name"; missing+=("$i") ;;
    esac
  done
  (( CFG_PLUGIN_COUNT )) || echo "  (không có plugin nào)"
  echo

  if (( changed )); then
    if (( auto )) || ask "Apply config và restart Cockpit?" Y; then
      backup_conf
      apply_port "$CFG_PORT" "$cur_port"
      ini_set Origins "$new_origins"
      if [[ $CFG_PROXY == true ]]; then
        ini_set ProtocolHeader X-Forwarded-Proto
        ini_set ForwardedForHeader X-Forwarded-For
      else
        ini_set ProtocolHeader ""
        ini_set ForwardedForHeader ""
      fi
      ok "Đã ghi $COCKPIT_CONF"
      restart_cockpit
    else
      info "Bỏ qua phần port/domain"
    fi
  fi

  if (( ${#missing[@]} )); then
    if (( auto )) || ask "Cài ${#missing[@]} plugin còn thiếu? (không cần restart)" Y; then
      local failed=0
      for i in "${missing[@]}"; do
        plugin_install "$(plugin_field "$i" name)" "$(plugin_field "$i" install)" "$(plugin_field "$i" check)" || failed=$((failed + 1))
      done
      (( failed )) && warn "$failed plugin cài lỗi" || ok "Xong. Tải lại trang Cockpit (F5) để thấy plugin mới"
    fi
  fi

  (( changed == 0 && ${#missing[@]} == 0 )) && ok "Mọi thứ đã khớp với config, không có gì thay đổi"
  return 0
}

# ----------------------------------------------------------------------------- Menu / main
menu() {
  while true; do
    show_status
    echo
    echo "  1) Install / Update"
    echo "  2) Uninstall"
    echo "  3) Restart service"
    echo "  4) Check & apply config"
    echo "  0) Exit"
    local c; read -r -p "Chọn: " c </dev/tty || exit 0
    case $c in
      1) cmd_install_update ;;
      2) cmd_uninstall ;;
      3) cmd_restart ;;
      4) cmd_apply ;;
      0|q|exit) exit 0 ;;
      *) warn "Lựa chọn không hợp lệ"; continue ;;
    esac
    pause
  done
}

usage() { sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'; }

main() {
  local cmd=""
  while (( $# )); do
    case $1 in
      -y|--yes)    ASSUME_YES=1 ;;
      -c|--config) shift; CONFIG_FILE=${1:-}; [[ -n $CONFIG_FILE ]] || die "Thiếu đường dẫn cho --config" ;;
      -h|--help)   usage; exit 0 ;;
      install|update|uninstall|restart|apply|status) cmd=$1 ;;
      *) usage; die "Tham số không hợp lệ: $1" ;;
    esac
    shift
  done

  require_root
  detect_os

  case $cmd in
    "")        menu ;;
    status)    show_status ;;
    install)   if pkg_installed cockpit; then ok "Cockpit đã cài ($(pkg_version cockpit))"; else ask "Install Cockpit?" Y && do_install; fi ;;
    update)    require_installed && do_update ;;
    uninstall) cmd_uninstall ;;
    restart)   cmd_restart ;;
    apply)     cmd_apply ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi