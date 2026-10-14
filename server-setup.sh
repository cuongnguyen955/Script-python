#!/usr/bin/env bash
#===============================================================================
# server-setup.sh - Menu cai dat moi truong may chu Ubuntu 22.04 / 24.04 / 26.04
#
# Cach dung:
#   chmod +x server-setup.sh
#   sudo ./server-setup.sh
#
# Log:          /var/log/server-setup.log
# Mat khau DB:  /root/server-setup-credentials.txt (chmod 600)
#===============================================================================
set -u
set -o pipefail

SCRIPT_VERSION="1.0.0"
LOG_FILE="/var/log/server-setup.log"
STATE_DIR="/var/lib/server-setup"
PORTS_FILE="$STATE_DIR/ports.list"
CRED_FILE="/root/server-setup-credentials.txt"
SYSDBA_DEFAULT="sysdba"
WAZUH_SERIES="${WAZUH_SERIES:-4.x}"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

# ---------- mau sac ----------
if [[ -t 1 ]]; then
  RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; BLU=$'\e[34m'; BLD=$'\e[1m'; NC=$'\e[0m'
else
  RED=""; GRN=""; YEL=""; BLU=""; BLD=""; NC=""
fi

# ---------- yeu cau root ----------
if [[ $EUID -ne 0 ]]; then
  echo "Can quyen root, dang chay lai bang sudo..."
  exec sudo -E bash "$0" "$@"
fi

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  sed -n '2,12p' "$0"
  exit 0
fi

mkdir -p "$STATE_DIR"
touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1
trap 'sleep 0.3' EXIT

# ---------- bien toan cuc ----------
OS_ID=""; OS_VER=""; OS_CODENAME=""; UB_MAJOR=""; ARCH="$(dpkg --print-architecture)"
TARGET_USER="${SUDO_USER:-}"
if [[ -z $TARGET_USER || $TARGET_USER == root ]]; then
  TARGET_USER="$(logname 2>/dev/null || echo root)"
fi
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -z $TARGET_HOME ]] && TARGET_HOME="/root"
CHOICE=0
CHOICES=()
REPLY_VAL=""
SECRET=""

# ---------- log helpers ----------
log()     { printf '%s[+]%s %s\n' "$GRN" "$NC" "$*"; }
warn()    { printf '%s[!]%s %s\n' "$YEL" "$NC" "$*" >&2; }
err()     { printf '%s[x]%s %s\n' "$RED" "$NC" "$*" >&2; }
section() { printf '\n%s========== %s ==========%s\n' "$BLD$BLU" "$*" "$NC"; }

# ---------- UI helpers (doc/ghi truc tiep tren tty) ----------
ask() { # ask "prompt" [default] -> REPLY_VAL
  local p="$1" d="${2:-}" v=""
  if [[ -n $d ]]; then printf '%s [%s]: ' "$p" "$d" >/dev/tty; else printf '%s: ' "$p" >/dev/tty; fi
  read -r v </dev/tty || v=""
  REPLY_VAL="${v:-$d}"
}

confirm() { # confirm "prompt" [y|n]
  local d="${2:-y}" v="" hint
  [[ $d == y ]] && hint="Y/n" || hint="y/N"
  printf '%s [%s]: ' "$1" "$hint" >/dev/tty
  read -r v </dev/tty || v=""
  v="${v:-$d}"
  [[ $v =~ ^[Yy] ]]
}

pause() { printf '\nNhan Enter de tiep tuc...' >/dev/tty; read -r _ </dev/tty || true; }

choose() { # choose "title" default item... -> CHOICE (1-based)
  local title="$1" def="$2"; shift 2
  local items=("$@") n=${#items[@]} i v=""
  {
    printf '\n%s%s%s\n' "$BLD" "$title" "$NC"
    for i in "${!items[@]}"; do printf '  %d) %s\n' $((i + 1)) "${items[$i]}"; done
  } >/dev/tty
  while true; do
    printf 'Chon [%s]: ' "$def" >/dev/tty
    read -r v </dev/tty || v=""
    v="${v:-$def}"
    if [[ $v =~ ^[0-9]+$ ]] && ((v >= 1 && v <= n)); then CHOICE=$v; return 0; fi
    echo "Lua chon khong hop le." >/dev/tty
  done
}

choose_multi() { # choose_multi "title" "default" item... -> CHOICES (mang chi so)
  local title="$1" def="$2"; shift 2
  local items=("$@") n=${#items[@]} i tok ok v=""
  {
    printf '\n%s%s%s\n' "$BLD" "$title" "$NC"
    for i in "${!items[@]}"; do printf '  %d) %s\n' $((i + 1)) "${items[$i]}"; done
    echo "  a) Tat ca"
  } >/dev/tty
  while true; do
    printf 'Chon (vd: 1 3 | a = tat ca | Enter = %s): ' "${def:-bo qua}" >/dev/tty
    read -r v </dev/tty || v=""
    v="${v:-$def}"; v="${v//,/ }"
    CHOICES=()
    [[ -z $v ]] && return 0
    if [[ $v == a || $v == A ]]; then
      for ((i = 1; i <= n; i++)); do CHOICES+=("$i"); done
      return 0
    fi
    ok=1
    for tok in $v; do
      if [[ $tok =~ ^[0-9]+$ ]] && ((tok >= 1 && tok <= n)); then CHOICES+=("$tok"); else ok=0; fi
    done
    ((ok)) && return 0
    echo "Lua chon khong hop le." >/dev/tty
  done
}

has_choice() { local x; for x in "${CHOICES[@]}"; do [[ $x == "$1" ]] && return 0; done; return 1; }

gen_pass() { openssl rand -base64 32 | tr -d '/+=\n' | cut -c1-20; }

ask_secret() { # ask_secret "label" -> SECRET
  local p1="" p2=""
  while true; do
    printf '%s (Enter = tu sinh ngau nhien): ' "$1" >/dev/tty
    read -rs p1 </dev/tty || p1=""; echo >/dev/tty
    if [[ -z $p1 ]]; then SECRET="$(gen_pass)"; log "Da sinh mat khau ngau nhien cho: $1"; return 0; fi
    if [[ $p1 == *"'"* || $p1 == *'\'* ]]; then warn "Khong dung ky tu ' hoac \\ trong mat khau"; continue; fi
    if ((${#p1} < 8)); then warn "Mat khau toi thieu 8 ky tu"; continue; fi
    printf 'Nhap lai: ' >/dev/tty
    read -rs p2 </dev/tty || p2=""; echo >/dev/tty
    if [[ $p1 == "$p2" ]]; then SECRET="$p1"; return 0; fi
    warn "Hai lan nhap khong khop."
  done
}

save_cred() { # save_cred "service" "account" "password"
  touch "$CRED_FILE"; chmod 600 "$CRED_FILE"
  printf '%s | %-28s | %-28s | %s\n' "$(date '+%F %T')" "$1" "$2" "$3" >>"$CRED_FILE"
}

# ---------- apt helpers ----------
apt_update()  { apt-get update -y -qq || apt-get update -y; }
apt_install() { apt-get install -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"; }
pkg_available() { apt-cache show "$1" >/dev/null 2>&1; }
is_installed()  { [[ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" == "install ok installed" ]]; }

apt_install_avail() {
  local ok=() p
  for p in "$@"; do
    if pkg_available "$p"; then ok+=("$p"); else warn "Bo qua (khong co trong repo): $p"; fi
  done
  if ((${#ok[@]} > 0)); then apt_install "${ok[@]}"; fi
}

block_autostart()   { printf '#!/bin/sh\nexit 101\n' >/usr/sbin/policy-rc.d; chmod +x /usr/sbin/policy-rc.d; }
unblock_autostart() { rm -f /usr/sbin/policy-rc.d; }

pick_codename() { # pick_codename "https://.../dists/@CN@/Release" -> in ra codename dung duoc
  local tpl="$1" cn url
  for cn in "$OS_CODENAME" noble jammy; do
    url="${tpl//@CN@/$cn}"
    if curl -fsIL --max-time 15 "$url" >/dev/null 2>&1; then
      [[ $cn != "$OS_CODENAME" ]] && warn "Repo chua ho tro '$OS_CODENAME', dung ban '$cn'" 
      echo "$cn"; return 0
    fi
  done
  return 1
}

# ---------- firewall registry ----------
fw_allow() { # fw_allow 80/tcp [source|any] [comment]
  local pp="$1" src="${2:-any}" cm="${3:-}"
  printf '%s|%s|%s\n' "$pp" "$src" "$cm" >>"$PORTS_FILE"
  sort -u -o "$PORTS_FILE" "$PORTS_FILE"
  if command -v ufw >/dev/null 2>&1 && [[ "$(ufw status 2>/dev/null)" == *"Status: active"* ]]; then
    ufw_apply "$pp" "$src"
  fi
}

ufw_apply() {
  local pp="$1" src="$2" port proto
  port="${pp%/*}"; proto="${pp#*/}"
  if [[ $src == any ]]; then ufw allow "$pp" >/dev/null
  else ufw allow from "$src" to any port "$port" proto "$proto" >/dev/null; fi
}

#===============================================================================
# PHAT HIEN HE DIEU HANH
#===============================================================================
detect_os() {
  section "Phat hien he dieu hanh"
  if [[ ! -r /etc/os-release ]]; then err "Khong tim thay /etc/os-release"; exit 1; fi
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-}"; OS_VER="${VERSION_ID:-}"; OS_CODENAME="${VERSION_CODENAME:-}"
  [[ -z $OS_CODENAME ]] && OS_CODENAME="$(lsb_release -cs 2>/dev/null || true)"
  if [[ $OS_ID != ubuntu ]]; then
    err "Script chi ho tro Ubuntu (phat hien: $OS_ID $OS_VER)"; exit 1
  fi
  case "$OS_VER" in
    22.04) UB_MAJOR=22 ;;
    24.04) UB_MAJOR=24 ;;
    26.04) UB_MAJOR=26 ;;
    *) UB_MAJOR="" ;;
  esac
  log "Phat hien: Ubuntu $OS_VER ($OS_CODENAME), kien truc $ARCH, user thuc thi: $TARGET_USER"
  local virt; virt="$(systemd-detect-virt 2>/dev/null || true)"
  [[ -n $virt && $virt != none ]] && log "May ao hoa: $virt"

  if [[ -n $UB_MAJOR ]] && confirm "Dung phien ban Ubuntu $UB_MAJOR.04 da phat hien?" y; then
    :
  else
    [[ -z $UB_MAJOR ]] && warn "Phien ban $OS_VER nam ngoai danh sach ho tro (22/24/26)."
    choose "Chon phien ban Ubuntu LTS de ap dung cau hinh" 2 "Ubuntu 22.04 LTS" "Ubuntu 24.04 LTS" "Ubuntu 26.04 LTS"
    case "$CHOICE" in 1) UB_MAJOR=22 ;; 2) UB_MAJOR=24 ;; 3) UB_MAJOR=26 ;; esac
  fi
  log "Ap dung cau hinh cho Ubuntu ${UB_MAJOR}.04"
}

setup_vim_ubuntu26() {
  [[ $UB_MAJOR == 26 ]] || return 0
  section "Ubuntu 26: cau hinh VIM nhu cac phien ban truoc"
  local homes=("/root") h rc
  [[ $TARGET_HOME != /root && -d $TARGET_HOME ]] && homes+=("$TARGET_HOME")
  for h in "${homes[@]}"; do
    rc="$h/.vimrc"
    if [[ -f $rc ]] && grep -q 'defaults.vim' "$rc" && grep -q '^set mouse=' "$rc"; then
      log "$rc da duoc cau hinh, bo qua"; continue
    fi
    [[ -f $rc ]] && cp -a "$rc" "$rc.bak.$(date +%s)"
    echo 'source $VIMRUNTIME/defaults.vim' >"$rc"
    echo 'set mouse=' >>"$rc"
    chown --reference="$h" "$rc"
    log "Da ghi $rc"
  done
}

#===============================================================================
# 0) CHUAN BI HE THONG
#===============================================================================
mod_base() {
  section "Chuan bi he thong"
  apt_update
  if confirm "Chay apt full-upgrade ngay bay gio?" y; then
    apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade
  fi
  apt_install_avail ca-certificates curl wget gnupg lsb-release software-properties-common apt-transport-https \
    git vim nano tmux htop iotop ncdu net-tools dnsutils iputils-ping traceroute mtr-tiny tcpdump lsof strace sysstat \
    rsync unzip zip tar jq tree bash-completion bc openssl ufw cron logrotate ethtool socat telnet psmisc locales

  ask "Hostname cua may chu" "$(hostname)"
  local new="$REPLY_VAL"
  if [[ $new != "$(hostname)" ]]; then
    if [[ $new =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
      hostnamectl set-hostname "$new"
      if grep -q '^127.0.1.1' /etc/hosts; then sed -i "s/^127.0.1.1.*/127.0.1.1 $new/" /etc/hosts
      else echo "127.0.1.1 $new" >>/etc/hosts; fi
      log "Da dat hostname: $new"
    else
      warn "Hostname khong hop le, giu nguyen."
    fi
  fi

  if confirm "Gioi han dung luong journald (500M) de tranh day dia?" y; then
    mkdir -p /etc/systemd/journald.conf.d
    printf '[Journal]\nSystemMaxUse=500M\nMaxRetentionSec=1month\n' >/etc/systemd/journald.conf.d/99-size.conf
    systemctl restart systemd-journald
  fi

  if confirm "Tao locale en_US.UTF-8?" y; then
    locale-gen en_US.UTF-8 >/dev/null 2>&1 && update-locale LANG=en_US.UTF-8
  fi
  log "Hoan tat chuan bi he thong."
}

#===============================================================================
# 1) NTP
#===============================================================================
mod_ntp() {
  section "NTP & Mui gio"
  local tz=""
  choose "Chon mui gio" 1 "Asia/Ho_Chi_Minh (Viet Nam)" "Asia/Bangkok" "Asia/Singapore" "Asia/Tokyo" "UTC" "Nhap mui gio khac"
  case "$CHOICE" in
    1) tz="Asia/Ho_Chi_Minh" ;;
    2) tz="Asia/Bangkok" ;;
    3) tz="Asia/Singapore" ;;
    4) tz="Asia/Tokyo" ;;
    5) tz="UTC" ;;
    6)
      while true; do
        ask "Nhap mui gio (vd Europe/Paris)" ""
        if [[ -n $REPLY_VAL && -f /usr/share/zoneinfo/$REPLY_VAL ]]; then tz="$REPLY_VAL"; break; fi
        warn "Mui gio khong ton tai."
      done ;;
  esac
  timedatectl set-timezone "$tz" && log "Mui gio: $tz"

  local lines=()
  choose "Chon nguon NTP upstream" 1 \
    "Viet Nam - vn.pool.ntp.org (+ asia.pool.ntp.org du phong)" \
    "Chau A - asia.pool.ntp.org" \
    "Google - time.google.com" \
    "Cloudflare - time.cloudflare.com" \
    "Ubuntu - ntp.ubuntu.com" \
    "Tu nhap danh sach server"
  case "$CHOICE" in
    1) lines=("pool vn.pool.ntp.org iburst maxsources 4" "pool asia.pool.ntp.org iburst maxsources 2") ;;
    2) lines=("pool asia.pool.ntp.org iburst maxsources 4") ;;
    3) lines=("server time.google.com iburst") ;;
    4) lines=("server time.cloudflare.com iburst") ;;
    5) lines=("server ntp.ubuntu.com iburst") ;;
    6)
      ask "Nhap server (cach nhau bang khoang trang)" ""
      local s
      for s in $REPLY_VAL; do lines+=("server $s iburst"); done
      if ((${#lines[@]} == 0)); then warn "Khong nhap server, dung vn.pool.ntp.org"; lines=("pool vn.pool.ntp.org iburst maxsources 4"); fi ;;
  esac

  local as_server=0 subnets=""
  if confirm "Dung may chu nay lam NTP Server cho mang noi bo?" n; then
    as_server=1
    ask "Dai mang duoc phep (cach nhau bang khoang trang)" "10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"
    subnets="$REPLY_VAL"
  fi

  log "Cai dat chrony..."
  apt_install chrony
  systemctl disable --now systemd-timesyncd >/dev/null 2>&1 || true
  systemctl disable --now ntpd-rs ntpsec >/dev/null 2>&1 || true

  [[ -f /etc/chrony/chrony.conf && ! -f /etc/chrony/chrony.conf.orig ]] && cp -a /etc/chrony/chrony.conf /etc/chrony/chrony.conf.orig
  {
    echo "# Tao boi server-setup.sh $(date -Is)"
    printf '%s\n' "${lines[@]}"
    cat <<'EOF'
keyfile /etc/chrony/chrony.keys
driftfile /var/lib/chrony/chrony.drift
ntsdumpdir /var/lib/chrony
logdir /var/log/chrony
maxupdateskew 100.0
rtcsync
makestep 1 3
leapsectz right/UTC
EOF
    if ((as_server)); then
      echo "# NTP server noi bo"
      local n
      for n in $subnets; do echo "allow $n"; done
      echo "local stratum 10"
    fi
  } >/etc/chrony/chrony.conf

  systemctl enable chrony >/dev/null 2>&1
  systemctl restart chrony
  if ((as_server)); then
    local n
    for n in $subnets; do fw_allow "123/udp" "$n" "NTP noi bo"; done
  fi
  sleep 3
  chronyc tracking || true
  chronyc sources || true
  log "NTP hoan tat."
}

#===============================================================================
# 2) PHP
#===============================================================================
php_install_version() {
  local v="$1" e pkgs=()
  local exts=(fpm cli common mysql pgsql sqlite3 curl gd mbstring xml zip bcmath intl soap readline gmp ldap opcache)
  if ! pkg_available "php${v}-fpm"; then
    warn "PHP $v khong co cho Ubuntu $OS_VER ($OS_CODENAME), bo qua."
    return 1
  fi
  for e in "${exts[@]}"; do
    [[ $e == opcache ]] && dpkg --compare-versions "$v" ge 8.5 && continue   # 8.5+ tich hop san opcache
    pkg_available "php${v}-${e}" && pkgs+=("php${v}-${e}")
  done
  apt_install "${pkgs[@]}"
}

php_tune() {
  local v="$1" d tz up="$2"
  tz="$(cat /etc/timezone 2>/dev/null || timedatectl show -p Timezone --value 2>/dev/null || echo UTC)"
  for d in fpm cli; do
    [[ -d /etc/php/$v/$d/conf.d ]] || continue
    cat >"/etc/php/$v/$d/conf.d/99-custom.ini" <<EOF
; server-setup.sh
date.timezone = ${tz}
memory_limit = 256M
upload_max_filesize = ${up}
post_max_size = ${up}
max_execution_time = 300
max_input_vars = 5000
expose_php = Off
EOF
  done
}

mod_php() {
  section "PHP-FPM (7.2 -> moi nhat)"
  local versions=(7.2 7.3 7.4 8.0 8.1 8.2 8.3 8.4 8.5)
  choose_multi "Chon phien ban PHP-FPM can cai" "" "${versions[@]}"
  if ((${#CHOICES[@]} == 0)); then log "Khong chon phien ban nao."; return 0; fi
  local sel=() c
  for c in "${CHOICES[@]}"; do sel+=("${versions[$((c - 1))]}"); done

  local repo_ok=1
  if ! compgen -G "/etc/apt/sources.list.d/*ondrej*" >/dev/null; then
    log "Them PPA ondrej/php..."
    if add-apt-repository -y ppa:ondrej/php >/dev/null 2>&1 && apt_update; then
      :
    else
      repo_ok=0
      add-apt-repository -y -r ppa:ondrej/php >/dev/null 2>&1 || true
      apt_update
    fi
  fi

  local installed=() v
  if ((repo_ok)); then
    for v in "${sel[@]}"; do
      log "Cai PHP $v ..."
      php_install_version "$v" && installed+=("$v")
    done
  else
    warn "Khong dung duoc PPA ondrej/php tren Ubuntu $OS_VER ($OS_CODENAME)."
    warn "Chi cai duoc phien ban PHP mac dinh cua Ubuntu."
    if confirm "Cai PHP mac dinh cua Ubuntu?" y; then
      apt_install_avail php-fpm php-cli php-common php-mysql php-pgsql php-sqlite3 php-curl php-gd php-mbstring php-xml php-zip php-bcmath php-intl php-soap php-readline php-gmp php-ldap
      v="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)"
      [[ -n $v ]] && installed+=("$v")
    fi
  fi
  if ((${#installed[@]} == 0)); then warn "Khong cai duoc phien ban PHP nao."; return 0; fi

  local up="64M"
  if confirm "Ap dung php.ini khuyen nghi (memory 256M, timezone he thong, upload/post size)?" y; then
    ask "upload_max_filesize / post_max_size" "64M"; up="$REPLY_VAL"
    for v in "${installed[@]}"; do php_tune "$v" "$up"; done
  fi

  for v in "${installed[@]}"; do
    systemctl enable --now "php${v}-fpm" >/dev/null 2>&1 || warn "Khong khoi dong duoc php${v}-fpm"
  done

  if ((${#installed[@]} > 1)); then
    choose "Chon phien ban PHP CLI mac dinh" "${#installed[@]}" "${installed[@]/#/PHP }"
    update-alternatives --set php "/usr/bin/php${installed[$((CHOICE - 1))]}" >/dev/null 2>&1 || true
  fi

  if confirm "Cai Composer?" y; then
    if curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php; then
      php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer && log "Da cai Composer"
      rm -f /tmp/composer-setup.php
    else
      warn "Khong tai duoc Composer."
    fi
  fi

  log "PHP-FPM da cai:"
  for v in "${installed[@]}"; do echo "   PHP $v  ->  socket /run/php/php${v}-fpm.sock"; done
}

#===============================================================================
# 3) DATABASE
#===============================================================================
SYSDBA=""

mysqlfam_setup() { # label service client confdir
  local label="$1" svc="$2" cli="$3" confdir="$4" rootpw syspw i
  ask_secret "Mat khau root ($label)"; rootpw="$SECRET"
  ask_secret "Mat khau $SYSDBA ($label)"; syspw="$SECRET"

  mkdir -p "$confdir"
  printf '[mysqld]\nbind-address = 0.0.0.0\n' >"$confdir/zz-remote-admin.cnf"
  systemctl enable --now "$svc" >/dev/null 2>&1
  systemctl restart "$svc"
  for i in $(seq 1 30); do "$cli" -uroot -e 'SELECT 1' >/dev/null 2>&1 && break; sleep 2; done

  # Tao sysdba truoc (qua socket), sau do moi dat mat khau root
  "$cli" -uroot <<SQL
CREATE USER IF NOT EXISTS '${SYSDBA}'@'%' IDENTIFIED BY '${syspw}';
ALTER USER '${SYSDBA}'@'%' IDENTIFIED BY '${syspw}';
GRANT ALL PRIVILEGES ON *.* TO '${SYSDBA}'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
  if [[ $label == MariaDB* ]]; then
    "$cli" -uroot <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket OR mysql_native_password USING PASSWORD('${rootpw}');
DROP DATABASE IF EXISTS test;
FLUSH PRIVILEGES;
SQL
  else
    "$cli" -uroot <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY '${rootpw}';
FLUSH PRIVILEGES;
SQL
  fi

  if MYSQL_PWD="$syspw" "$cli" -u"$SYSDBA" -h127.0.0.1 -e 'SELECT CURRENT_USER();' >/dev/null 2>&1; then
    log "$label: dang nhap $SYSDBA qua TCP thanh cong."
  else
    warn "$label: khong dang nhap duoc $SYSDBA qua TCP, hay kiem tra lai."
  fi
  save_cred "$label" "root@localhost" "$rootpw"
  save_cred "$label" "${SYSDBA}@% (remote)" "$syspw"
  fw_allow "3306/tcp" "any" "$label"
}

db_mysql() {
  section "MySQL"
  apt_install mysql-server mysql-client
  mysqlfam_setup "MySQL" mysql mysql /etc/mysql/mysql.conf.d
}

db_mariadb() {
  section "MariaDB"
  choose "Phien ban MariaDB" 1 "Repo Ubuntu (mac dinh)" "10.11 LTS (repo chinh thuc MariaDB)" "11.4 LTS (repo chinh thuc MariaDB)" "11.8 LTS (repo chinh thuc MariaDB)"
  local ver=""
  case "$CHOICE" in 2) ver="10.11" ;; 3) ver="11.4" ;; 4) ver="11.8" ;; esac
  if [[ -n $ver ]]; then
    if curl -fsSL https://r.mariadb.com/downloads/mariadb_repo_setup -o /tmp/mariadb_repo_setup \
       && bash /tmp/mariadb_repo_setup --mariadb-server-version="mariadb-$ver" --skip-maxscale; then
      apt_update
    else
      warn "Khong them duoc repo MariaDB $ver cho $OS_CODENAME, dung ban trong repo Ubuntu."
    fi
    rm -f /tmp/mariadb_repo_setup
  fi
  apt_install mariadb-server mariadb-client
  mysqlfam_setup "MariaDB" mariadb mariadb /etc/mysql/mariadb.conf.d
}

db_postgres() {
  section "PostgreSQL"
  choose "Phien ban PostgreSQL" 1 "Repo Ubuntu (mac dinh)" "18 (PGDG)" "17 (PGDG)" "16 (PGDG)" "15 (PGDG)" "14 (PGDG)"
  local ver=""
  case "$CHOICE" in 2) ver=18 ;; 3) ver=17 ;; 4) ver=16 ;; 5) ver=15 ;; 6) ver=14 ;; esac
  if [[ -n $ver ]]; then
    apt_install postgresql-common ca-certificates
    if /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y && apt_install "postgresql-$ver"; then
      :
    else
      warn "Khong cai duoc PostgreSQL $ver tu PGDG, dung ban trong repo Ubuntu."
      apt_install postgresql postgresql-client
    fi
  else
    apt_install postgresql postgresql-client
  fi
  local pgver conf rootpw syspw
  pgver="$(ls /etc/postgresql 2>/dev/null | sort -V | tail -n1)"
  if [[ -z $pgver ]]; then err "Khong tim thay cau hinh PostgreSQL."; return 1; fi
  conf="/etc/postgresql/$pgver/main"
  ask_secret "Mat khau postgres (root)"; rootpw="$SECRET"
  ask_secret "Mat khau $SYSDBA (PostgreSQL)"; syspw="$SECRET"

  mkdir -p "$conf/conf.d"
  printf "listen_addresses = '*'\n" >"$conf/conf.d/99-remote.conf"
  local l
  for l in "host    all    all    0.0.0.0/0    scram-sha-256" "host    all    all    ::/0         scram-sha-256"; do
    grep -qF "$l" "$conf/pg_hba.conf" || echo "$l" >>"$conf/pg_hba.conf"
  done
  systemctl enable --now postgresql >/dev/null 2>&1
  systemctl restart postgresql
  sleep 3
  runuser -u postgres -- psql -v ON_ERROR_STOP=1 <<SQL
ALTER USER postgres WITH PASSWORD '${rootpw}';
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${SYSDBA}') THEN
    CREATE ROLE "${SYSDBA}" WITH LOGIN SUPERUSER PASSWORD '${syspw}';
  ELSE
    ALTER ROLE "${SYSDBA}" WITH LOGIN SUPERUSER PASSWORD '${syspw}';
  END IF;
END
\$\$;
SQL
  if PGPASSWORD="$syspw" psql -h 127.0.0.1 -U "$SYSDBA" -d postgres -c 'SELECT 1' >/dev/null 2>&1; then
    log "PostgreSQL: dang nhap $SYSDBA qua TCP thanh cong."
  else
    warn "PostgreSQL: khong dang nhap duoc $SYSDBA qua TCP."
  fi
  save_cred "PostgreSQL $pgver" "postgres@localhost" "$rootpw"
  save_cred "PostgreSQL $pgver" "${SYSDBA} (remote)" "$syspw"
  fw_allow "5432/tcp" "any" "PostgreSQL"
}

mongo_upsert() { # mongo_upsert user password
  SU="$1" SP="$2" mongosh --quiet --eval '
    const a = db.getSiblingDB("admin"); const u = process.env.SU, p = process.env.SP;
    const roles = [{role: "root", db: "admin"}];
    if (a.getUser(u)) { a.updateUser(u, {pwd: p, roles: roles}); } else { a.createUser({user: u, pwd: p, roles: roles}); }'
}

db_mongo() {
  section "MongoDB"
  choose "Phien ban MongoDB" 1 "8.0 (khuyen nghi)" "7.0"
  local ver="8.0"; [[ $CHOICE == 2 ]] && ver="7.0"
  apt_install gnupg curl
  local cn
  cn="$(pick_codename "https://repo.mongodb.org/apt/ubuntu/dists/@CN@/mongodb-org/${ver}/Release")" || { err "Khong tim thay repo MongoDB $ver phu hop."; return 1; }
  curl -fsSL "https://pgp.mongodb.com/server-${ver}.asc" | gpg --dearmor --yes -o "/usr/share/keyrings/mongodb-server-${ver}.gpg"
  echo "deb [arch=${ARCH} signed-by=/usr/share/keyrings/mongodb-server-${ver}.gpg] https://repo.mongodb.org/apt/ubuntu ${cn}/mongodb-org/${ver} multiverse" >"/etc/apt/sources.list.d/mongodb-org-${ver}.list"
  apt_update
  apt_install mongodb-org || { err "Cai MongoDB that bai."; return 1; }

  local rootpw syspw
  ask_secret "Mat khau root (MongoDB)"; rootpw="$SECRET"
  ask_secret "Mat khau $SYSDBA (MongoDB)"; syspw="$SECRET"

  systemctl enable --now mongod >/dev/null 2>&1
  local i ok=0
  for i in $(seq 1 30); do
    mongosh --quiet --eval 'db.runCommand({ping:1}).ok' >/dev/null 2>&1 && { ok=1; break; }
    sleep 2
  done
  ((ok)) || { err "mongod khong san sang."; return 1; }

  mongo_upsert root "$rootpw"
  mongo_upsert "$SYSDBA" "$syspw"

  sed -i -E 's/^(\s*bindIp:).*/\1 0.0.0.0/' /etc/mongod.conf
  if ! grep -q '^security:' /etc/mongod.conf; then
    if grep -q '^#security:' /etc/mongod.conf; then
      sed -i 's/^#security:.*/security:\n  authorization: enabled/' /etc/mongod.conf
    else
      printf '\nsecurity:\n  authorization: enabled\n' >>/etc/mongod.conf
    fi
  fi
  systemctl restart mongod
  sleep 3
  if mongosh --quiet -u "$SYSDBA" -p "$syspw" --authenticationDatabase admin --eval 'db.runCommand({ping:1}).ok' >/dev/null 2>&1; then
    log "MongoDB: dang nhap $SYSDBA thanh cong (authorization da bat)."
  else
    warn "MongoDB: khong dang nhap duoc $SYSDBA."
  fi
  save_cred "MongoDB $ver" "root (authDb=admin)" "$rootpw"
  save_cred "MongoDB $ver" "${SYSDBA} (authDb=admin)" "$syspw"
  fw_allow "27017/tcp" "any" "MongoDB"
}

mod_db() {
  section "Database"
  choose_multi "Chon database can cai" "" "MySQL" "MariaDB" "PostgreSQL" "MongoDB"
  if ((${#CHOICES[@]} == 0)); then log "Khong chon database nao."; return 0; fi
  if has_choice 1 && has_choice 2; then
    err "MySQL va MariaDB xung dot goi/cong 3306, chi chon mot trong hai."; return 1
  fi
  if has_choice 1 && is_installed mariadb-server; then err "May da co MariaDB, khong cai MySQL cung."; return 1; fi
  if has_choice 2 && is_installed mysql-server; then err "May da co MySQL, khong cai MariaDB cung."; return 1; fi

  ask "Ten tai khoan quan tri DB (ngang quyen root, remote moi dia chi)" "$SYSDBA_DEFAULT"
  SYSDBA="$REPLY_VAL"
  [[ $SYSDBA =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { err "Ten tai khoan khong hop le."; return 1; }
  apt_update
  has_choice 1 && db_mysql
  has_choice 2 && db_mariadb
  has_choice 3 && db_postgres
  has_choice 4 && db_mongo
  warn "Tai khoan $SYSDBA cho phep ket noi tu MOI dia chi. Hay gioi han nguon o muc Bao mat > UFW."
  log "Mat khau da luu tai $CRED_FILE"
}

#===============================================================================
# 4) WEB SERVER
#===============================================================================
nginx_install() {
  choose "Nguon Nginx" 1 "Repo Ubuntu (mac dinh)" "nginx.org stable" "nginx.org mainline"
  if [[ $CHOICE == 1 ]]; then apt_install nginx; return; fi
  local path="ubuntu" cn
  [[ $CHOICE == 3 ]] && path="mainline/ubuntu"
  if cn="$(pick_codename "http://nginx.org/packages/${path}/dists/@CN@/Release")"; then
    curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor --yes -o /usr/share/keyrings/nginx-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/${path} ${cn} nginx" >/etc/apt/sources.list.d/nginx.list
    printf 'Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n' >/etc/apt/preferences.d/99nginx
    apt_update
  else
    warn "Khong co repo nginx.org phu hop, dung ban trong repo Ubuntu."
  fi
  apt_install nginx
}

apache_move_ports() {
  warn "Nginx va Apache cung co mat: chuyen Apache sang cong 8080/8443."
  sed -i -E 's/^Listen 80$/Listen 8080/; s/^(\s*)Listen 443$/\1Listen 8443/' /etc/apache2/ports.conf
  [[ -f /etc/apache2/sites-available/000-default.conf ]] && sed -i -E 's/<VirtualHost \*:80>/<VirtualHost *:8080>/' /etc/apache2/sites-available/000-default.conf
  [[ -f /etc/apache2/sites-available/default-ssl.conf ]] && sed -i -E 's/<VirtualHost _default_:443>/<VirtualHost _default_:8443>/' /etc/apache2/sites-available/default-ssl.conf
  APACHE_MOVED=1
}

mod_web() {
  section "Web server"
  choose_multi "Chon thanh phan can cai" "" "Nginx" "Apache2" "Certbot (Let's Encrypt)"
  if ((${#CHOICES[@]} == 0)); then log "Khong chon gi."; return 0; fi
  apt_update
  APACHE_MOVED=0
  block_autostart
  if has_choice 1; then nginx_install; fi
  if has_choice 2; then
    apt_install apache2
    a2enmod rewrite ssl headers proxy proxy_http proxy_fcgi setenvif http2 expires deflate >/dev/null 2>&1
    printf 'ServerTokens Prod\nServerSignature Off\nTraceEnable Off\n' >/etc/apache2/conf-available/zz-hardening.conf
    a2enconf zz-hardening >/dev/null 2>&1
  fi
  unblock_autostart

  if is_installed nginx && is_installed apache2; then apache_move_ports; fi

  if is_installed nginx; then
    printf 'server_tokens off;\n' >/etc/nginx/conf.d/00-security.conf
    if nginx -t; then systemctl enable --now nginx >/dev/null 2>&1; systemctl restart nginx; else warn "nginx -t loi, kiem tra cau hinh."; fi
    fw_allow "80/tcp" "any" "HTTP"; fw_allow "443/tcp" "any" "HTTPS"
    log "Nginx: $(nginx -v 2>&1)"
  fi
  if is_installed apache2; then
    if apache2ctl configtest; then systemctl enable --now apache2 >/dev/null 2>&1; systemctl restart apache2; else warn "apache2ctl configtest loi."; fi
    if [[ ${APACHE_MOVED:-0} == 1 ]]; then fw_allow "8080/tcp" "any" "Apache"; fw_allow "8443/tcp" "any" "Apache SSL"
    else fw_allow "80/tcp" "any" "HTTP"; fw_allow "443/tcp" "any" "HTTPS"; fi
    log "Apache: $(apache2 -v | head -n1)"
  fi

  if has_choice 3; then
    apt_install certbot
    is_installed nginx && apt_install_avail python3-certbot-nginx
    is_installed apache2 && apt_install_avail python3-certbot-apache
    systemctl list-timers 2>/dev/null | grep -i certbot || true
    log "Certbot: dung 'certbot --nginx -d domain' hoac 'certbot --apache -d domain'."
  fi
}

#===============================================================================
# 5) NODEJS
#===============================================================================
mod_node() {
  section "NodeJS"
  choose "Cach cai NodeJS" 1 "NodeSource 24.x" "NodeSource 22.x" "NodeSource 26.x" "Repo Ubuntu (mac dinh)" "nvm (cho user $TARGET_USER)"
  case "$CHOICE" in
    1 | 2 | 3)
      local v=24; [[ $CHOICE == 2 ]] && v=22; [[ $CHOICE == 3 ]] && v=26
      if curl -fsSL "https://deb.nodesource.com/setup_${v}.x" | bash -; then
        apt_install nodejs
      else
        warn "NodeSource ${v}.x khong kha dung, dung ban trong repo Ubuntu."
        apt_install nodejs npm
      fi ;;
    4) apt_install nodejs npm ;;
    5)
      if [[ $TARGET_USER == root ]]; then warn "Dang chay voi root, nvm se cai cho root."; fi
      runuser -u "$TARGET_USER" -- bash -lc 'curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash && export NVM_DIR="$HOME/.nvm" && . "$NVM_DIR/nvm.sh" && nvm install --lts'
      log "Mo shell moi de dung nvm."
      return 0 ;;
  esac
  command -v node >/dev/null 2>&1 && log "node $(node -v), npm $(npm -v 2>/dev/null)"
  if confirm "Cai pm2 (process manager)?" n; then npm install -g pm2 && log "Da cai pm2"; fi
}

#===============================================================================
# 6) DOCKER
#===============================================================================
mod_docker() {
  section "Docker"
  apt-get -y remove docker docker-engine docker.io containerd runc >/dev/null 2>&1 || true
  apt_update
  apt_install ca-certificates curl gnupg lsb-release
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  local cn
  cn="$(pick_codename "https://download.docker.com/linux/ubuntu/dists/@CN@/Release")" || { err "Khong tim thay repo Docker phu hop."; return 1; }
  echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${cn} stable" >/etc/apt/sources.list.d/docker.list
  apt_update
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || { err "Cai Docker that bai."; return 1; }

  if [[ $TARGET_USER != root ]]; then
    usermod -aG docker "$TARGET_USER" && log "Da them $TARGET_USER vao nhom docker (dang nhap lai de co hieu luc)."
  fi
  if [[ ! -f /etc/docker/daemon.json ]] && confirm "Gioi han log container (10MB x 3 file) de tranh day dia?" y; then
    mkdir -p /etc/docker
    cat >/etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
  fi
  systemctl enable --now docker >/dev/null 2>&1
  systemctl restart docker
  docker --version; docker compose version || true
  warn "Luu y: cong Docker publish (-p) di vong qua UFW. Dung DOCKER-USER chain hoac bind 127.0.0.1 neu can han che."
}

#===============================================================================
# 7) TIEN ICH HE THONG
#===============================================================================
setup_swap() {
  if [[ -n "$(swapon --show 2>/dev/null)" ]]; then
    warn "May da co swap:"; swapon --show
    confirm "Van tao them /swapfile?" n || return 0
  fi
  [[ -f /swapfile ]] && { warn "/swapfile da ton tai."; return 0; }
  ask "Dung luong swap (vd 2G, 4G)" "2G"
  local size="$REPLY_VAL"
  fallocate -l "$size" /swapfile || { err "Khong tao duoc swapfile"; rm -f /swapfile; return 1; }
  chmod 600 /swapfile; mkswap /swapfile >/dev/null; swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
  log "Da tao swap $size"
}

setup_sysctl() {
  cat >/etc/sysctl.d/99-server-tuning.conf <<'EOF'
vm.swappiness = 10
vm.max_map_count = 262144
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_syncookies = 1
net.ipv4.ip_local_port_range = 10240 65000
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 600
EOF
  sysctl --system >/dev/null
  printf '* soft nofile 65535\n* hard nofile 65535\nroot soft nofile 65535\nroot hard nofile 65535\n' >/etc/security/limits.d/99-nofile.conf
  mkdir -p /etc/systemd/system.conf.d
  printf '[Manager]\nDefaultLimitNOFILE=65535\n' >/etc/systemd/system.conf.d/99-nofile.conf
  systemctl daemon-reload
  log "Da ap dung sysctl + ulimit (nofile 65535). Can reboot de ulimit moi cho moi dich vu."
}

install_qemu_agent() {
  apt_install qemu-guest-agent
  systemctl enable --now qemu-guest-agent >/dev/null 2>&1 || warn "qemu-guest-agent chua chay duoc (can bat 'QEMU Guest Agent' trong VM tren Proxmox va reboot VM)."
  log "Da cai qemu-guest-agent."
}

install_node_exporter() {
  local ver arch tmp
  case "$ARCH" in amd64) arch=amd64 ;; arm64) arch=arm64 ;; *) warn "Kien truc $ARCH chua ho tro"; return 1 ;; esac
  apt_install_avail jq curl
  ver="$(curl -fsSL --max-time 15 https://api.github.com/repos/prometheus/node_exporter/releases/latest 2>/dev/null | jq -r '.tag_name // empty' | sed 's/^v//')"
  if [[ ! $ver =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then ver="1.9.1"; warn "Khong lay duoc ban moi nhat, dung $ver"; fi
  tmp="$(mktemp -d)"
  if ! curl -fsSL -o "$tmp/ne.tgz" "https://github.com/prometheus/node_exporter/releases/download/v${ver}/node_exporter-${ver}.linux-${arch}.tar.gz"; then
    err "Tai node_exporter that bai"; rm -rf "$tmp"; return 1
  fi
  tar -xzf "$tmp/ne.tgz" -C "$tmp"
  install -m 0755 "$tmp/node_exporter-${ver}.linux-${arch}/node_exporter" /usr/local/bin/node_exporter
  rm -rf "$tmp"
  id node_exporter >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin node_exporter
  cat >/etc/systemd/system/node_exporter.service <<'EOF'
[Unit]
Description=Prometheus Node Exporter
After=network-online.target
Wants=network-online.target

[Service]
User=node_exporter
ExecStart=/usr/local/bin/node_exporter --web.listen-address=:9100
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now node_exporter >/dev/null 2>&1
  ask "Chi cho phep IP/CIDR Prometheus truy cap cong 9100 (Enter = any)" "any"
  fw_allow "9100/tcp" "$REPLY_VAL" "node_exporter"
  log "node_exporter $ver dang chay tren cong 9100."
}

install_wazuh_agent() {
  ask "Dia chi Wazuh Manager (IP/FQDN, de trong = bo qua)" ""
  local mgr="$REPLY_VAL"
  [[ -z $mgr ]] && { warn "Bo qua Wazuh agent."; return 0; }
  ask "Ten agent" "$(hostname)"
  local name="$REPLY_VAL"
  curl -fsSL https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --dearmor --yes -o /usr/share/keyrings/wazuh.gpg
  chmod 644 /usr/share/keyrings/wazuh.gpg
  echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/${WAZUH_SERIES}/apt/ stable main" >/etc/apt/sources.list.d/wazuh.list
  apt_update
  WAZUH_MANAGER="$mgr" WAZUH_AGENT_NAME="$name" apt_install wazuh-agent || { err "Cai wazuh-agent that bai (kiem tra WAZUH_SERIES=${WAZUH_SERIES})."; return 1; }
  systemctl daemon-reload
  systemctl enable --now wazuh-agent >/dev/null 2>&1
  log "Wazuh agent '$name' tro toi manager $mgr (cong 1514/1515 tren manager)."
}

mod_extras() {
  section "Tien ich he thong"
  choose_multi "Chon tien ich" "" \
    "Swap file" \
    "Toi uu sysctl + ulimit" \
    "qemu-guest-agent (VM Proxmox/KVM)" \
    "Prometheus node_exporter" \
    "Wazuh agent (SIEM)"
  has_choice 1 && setup_swap
  has_choice 2 && setup_sysctl
  has_choice 3 && install_qemu_agent
  has_choice 4 && install_node_exporter
  has_choice 5 && install_wazuh_agent
  return 0
}

#===============================================================================
# 8) BAO MAT
#===============================================================================
ssh_port() {
  local p
  p="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}')"
  echo "${p:-22}"
}

setup_ufw() {
  apt_install ufw
  local sshp cur="" l pp src cm ans
  sshp="$(ssh_port)"
  [[ -n ${SSH_CONNECTION:-} ]] && cur="${SSH_CONNECTION##* }"
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw limit "${sshp}/tcp" >/dev/null && log "Cho phep SSH cong $sshp (co gioi han toc do)"
  [[ -n $cur && $cur != "$sshp" ]] && { ufw limit "${cur}/tcp" >/dev/null; log "Cho phep cong SSH hien tai $cur"; }

  if [[ -s $PORTS_FILE ]]; then
    while IFS='|' read -r pp src cm; do
      [[ -z $pp ]] && continue
      if [[ $src == any ]]; then
        case "$pp" in
          3306/tcp | 5432/tcp | 27017/tcp | 9100/tcp)
            ask "Nguon duoc phep toi $pp ($cm) - CIDR hoac 'any'" "any"
            src="$REPLY_VAL" ;;
        esac
      fi
      ufw_apply "$pp" "$src"
      log "Mo $pp tu $src ($cm)"
    done <"$PORTS_FILE"
  fi
  ask "Cong bo sung can mo (vd 8443/tcp 51820/udp, de trong = khong)" ""
  for ans in $REPLY_VAL; do
    [[ $ans == */* ]] || ans="${ans}/tcp"
    ufw allow "$ans" >/dev/null && log "Mo $ans"
  done
  warn "Se bat UFW. Cong SSH $sshp da duoc cho phep; hay giu phien SSH hien tai den khi kiem tra xong."
  if confirm "Bat UFW ngay bay gio?" y; then
    ufw --force enable
    ufw status verbose
  fi
}

setup_fail2ban() {
  apt_install fail2ban
  apt_install_avail python3-systemd python3-pyinotify python3-pyasyncore
  ask "IP/CIDR quan tri can whitelist (cach nhau bang khoang trang, de trong = khong)" ""
  cat >/etc/fail2ban/jail.d/99-local.conf <<EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd
ignoreip = 127.0.0.1/8 ::1 ${REPLY_VAL}

[sshd]
enabled = true
port    = $(ssh_port)
EOF
  systemctl enable fail2ban >/dev/null 2>&1
  systemctl restart fail2ban
  sleep 2
  fail2ban-client status sshd 2>/dev/null || warn "Jail sshd chua chay, kiem tra: journalctl -u fail2ban"
}

setup_unattended() {
  apt_install unattended-upgrades
  printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' >/etc/apt/apt.conf.d/20auto-upgrades
  if confirm "Tu dong reboot khi can (luc 02:30)?" n; then
    printf 'Unattended-Upgrade::Automatic-Reboot "true";\nUnattended-Upgrade::Automatic-Reboot-Time "02:30";\n' >/etc/apt/apt.conf.d/52server-setup
  fi
  log "Da bat tu dong cap nhat ban va bao mat."
}

ssh_harden() {
  local dir=/etc/ssh/sshd_config.d f=/etc/ssh/sshd_config.d/00-hardening.conf prl="prohibit-password" key_ok=0 nopw=0
  [[ -d $dir ]] || { warn "Khong co $dir, bo qua."; return 0; }
  choose "PermitRootLogin" 1 "prohibit-password (chi cho phep key)" "no (cam hoan toan)" "giu nguyen"
  case "$CHOICE" in 1) prl="prohibit-password" ;; 2) prl="no" ;; 3) prl="" ;; esac
  [[ -s "$TARGET_HOME/.ssh/authorized_keys" || -s /root/.ssh/authorized_keys ]] && key_ok=1
  if ((key_ok)); then
    confirm "Tat dang nhap bang mat khau (chi dung SSH key)?" n && nopw=1
  else
    warn "Chua thay authorized_keys cua $TARGET_USER hoac root, khong de xuat tat mat khau."
  fi
  {
    echo "# server-setup.sh - file ten 00- de uu tien hon cac file khac (sshd lay gia tri dau tien)"
    [[ -n $prl ]] && echo "PermitRootLogin $prl"
    if ((nopw)); then echo "PasswordAuthentication no"; echo "KbdInteractiveAuthentication no"; fi
    cat <<'EOF'
MaxAuthTries 4
LoginGraceTime 30
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
  } >"$f"
  if sshd -t; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null
    log "Da ap dung $f. Mo phien SSH moi de kiem tra truoc khi dong phien hien tai."
  else
    rm -f "$f"; err "sshd -t bao loi, da go bo cau hinh moi."
  fi
}

mod_security() {
  section "Bao mat"
  choose_multi "Chon hang muc" "" \
    "UFW firewall (mo cong theo dich vu da cai)" \
    "Fail2ban (chong brute-force SSH)" \
    "SSH hardening" \
    "Tu dong cap nhat bao mat (unattended-upgrades)"
  # Thu tu an toan: ssh/fail2ban/auto-update truoc, UFW sau cung
  has_choice 3 && ssh_harden
  has_choice 2 && setup_fail2ban
  has_choice 4 && setup_unattended
  has_choice 1 && setup_ufw
  return 0
}

#===============================================================================
# 9) SSL / TLS
#   1. Tao SSL local (self-signed hoac Local CA), mac dinh 10 nam
#   2. Tao/lay SSL tu Let's Encrypt (certbot)
#   3. Gop cert nha cung cap (leaf + intermediate + root) -> bundle.crt
#   4. Kiem tra cert (file hoac host dang chay)
# Ket qua luon nam o $SSL_BASE/<ten>/ gom: <ten>.key + bundle.crt
#===============================================================================
SSL_BASE="${SSL_BASE:-/etc/ssl/server-setup}"
SSL_SYSTEM_CA="/etc/ssl/certs/ca-certificates.crt"
OUT_DIR=""; POOL=""; WORKDIR=""; KEYTYPE="rsa2048"; CA_CRT=""; CA_KEY=""
declare -A SUBJ=() ISS=() SKI=() AKI=()
export SSL_KEY_PASS=""

ask_hidden() { # ask_hidden "prompt" -> REPLY_VAL
  local v=""
  printf '%s: ' "$1" >/dev/tty
  read -rs v </dev/tty || v=""; echo >/dev/tty
  REPLY_VAL="$v"
}

ssl_valid_name() { [[ $1 =~ ^(\*\.)?[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]]; }
ssl_safe_name()  { local n="$1"; n="${n//\*/wildcard}"; n="${n//[^A-Za-z0-9._-]/_}"; echo "$n"; }

ssl_prepare_outdir() { # name -> OUT_DIR (backup file cu neu co)
  local name="$1" f bk
  OUT_DIR="$SSL_BASE/$name"
  mkdir -p "$OUT_DIR"; chmod 755 "$SSL_BASE" "$OUT_DIR"
  bk="$OUT_DIR/.bak-$(date +%Y%m%d%H%M%S)"
  for f in "$OUT_DIR/bundle.crt" "$OUT_DIR/chain.crt" "$OUT_DIR/$name.key" "$OUT_DIR/$name.crt" "$OUT_DIR/$name.pfx" "$OUT_DIR/ca.crt"; do
    if [[ -L $f ]]; then rm -f "$f"
    elif [[ -f $f ]]; then mkdir -p "$bk"; chmod 700 "$bk"; mv "$f" "$bk/"; fi
  done
}

ssl_gen_key() { # rsa2048|rsa4096|ec  file
  case "$1" in
    rsa2048) openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$2" 2>/dev/null || return 1 ;;
    rsa4096) openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out "$2" 2>/dev/null || return 1 ;;
    ec)      openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$2" 2>/dev/null || return 1 ;;
    *) return 1 ;;
  esac
  chmod 600 "$2"
}

ssl_pick_keytype() {
  choose "Loai khoa" 1 "RSA 2048 (tuong thich rong nhat)" "RSA 4096" "ECDSA P-256 (nhanh, nho)"
  case "$CHOICE" in 1) KEYTYPE=rsa2048 ;; 2) KEYTYPE=rsa4096 ;; 3) KEYTYPE=ec ;; esac
}

ssl_build_san() { # cn extra... -> chuoi subjectAltName
  local out="" t seen=" "
  for t in "$@"; do
    [[ $seen == *" $t "* ]] && continue
    seen+="$t "
    if [[ $t =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ || $t == *:* ]]; then out+="IP:$t,"; else out+="DNS:$t,"; fi
  done
  echo "${out%,}"
}

# ---------- doc thong tin cert ----------
ssl_dn() { openssl x509 -noout -nameopt RFC2253 -"$2" -in "$1" 2>/dev/null | sed -E 's/^(subject|issuer)= ?//'; }
ssl_cn() { local c; c="$(sed -n 's/.*CN=\([^,]*\).*/\1/p' <<<"$1")"; echo "${c:-$1}"; }
ssl_ids() { # file -> "SKI|AKI"
  openssl x509 -noout -ext subjectKeyIdentifier,authorityKeyIdentifier -in "$1" 2>/dev/null | awk '
    /Subject Key Identifier/ {k="s"; next}
    /Authority Key Identifier/ {k="a"; next}
    k != "" {
      v=$0; gsub(/keyid:/, "", v); gsub(/[ \t\r]/, "", v)
      if (v ~ /^[0-9A-Fa-f:]+$/ && length(v) > 10) { if (k=="s") s=v; else if (a=="") a=v; k="" }
    }
    END {print toupper(s) "|" toupper(a)}'
}
ssl_cert_pubhash() { openssl x509 -noout -pubkey -in "$1" 2>/dev/null | openssl sha256 2>/dev/null | awk '{print $NF}'; }
ssl_key_pubhash()  { openssl pkey -in "$1" -passin env:SSL_KEY_PASS -pubout 2>/dev/null | openssl sha256 2>/dev/null | awk '{print $NF}'; }

ssl_split_pem() { # doc stdin, tach tung cert PEM vao thu muc $1
  awk -v d="$1" '
    /-----BEGIN CERTIFICATE-----/ {inb=1; n++; f=sprintf("%s/c%03d.pem", d, n)}
    inb {print > f}
    /-----END CERTIFICATE-----/ {inb=0; close(f)}'
}

ssl_register_cert() { # file -> dang ky vao POOL, tra 1 neu da co/khong hop le
  local f="$1" fp ids
  fp="$(openssl x509 -noout -fingerprint -sha256 -in "$f" 2>/dev/null | cut -d= -f2 | tr -d ':')" || return 1
  [[ -n $fp ]] || return 1
  [[ -n ${SUBJ[$fp]:-} ]] && return 1
  openssl x509 -in "$f" -out "$POOL/$fp.pem" 2>/dev/null || return 1
  SUBJ[$fp]="$(ssl_dn "$POOL/$fp.pem" subject)"
  ISS[$fp]="$(ssl_dn "$POOL/$fp.pem" issuer)"
  ids="$(ssl_ids "$POOL/$fp.pem")"
  SKI[$fp]="${ids%%|*}"; AKI[$fp]="${ids##*|}"
  return 0
}

ssl_import_file() { # nhap moi cert tim thay trong file (PEM / DER / p7b); tra 0 neu co cert moi
  local f="$1" tmpd c n=0
  tmpd="$(mktemp -d)"
  if grep -aq 'BEGIN CERTIFICATE' "$f"; then
    tr -d '\r' <"$f" | ssl_split_pem "$tmpd"
  elif grep -aq 'BEGIN PKCS7' "$f"; then
    openssl pkcs7 -print_certs -in "$f" 2>/dev/null | ssl_split_pem "$tmpd"
  elif openssl x509 -inform DER -in "$f" -out "$tmpd/der.pem" 2>/dev/null; then
    :
  else
    openssl pkcs7 -inform DER -print_certs -in "$f" 2>/dev/null | ssl_split_pem "$tmpd"
  fi
  for c in "$tmpd"/*.pem; do
    [[ -f $c ]] || continue
    ssl_register_cert "$c" && n=$((n + 1))
  done
  rm -rf "$tmpd"
  ((n > 0))
}

ssl_load_key() { # src dest -> giai ma neu can, kiem tra doc duoc
  local src="$1" dest="$2"
  if grep -aq 'ENCRYPTED' "$src"; then
    ask_hidden "Passphrase cua private key $(basename "$src") (Enter = bo qua key nay)"
    [[ -n $REPLY_VAL ]] || return 1
    SSL_KEY_PASS="$REPLY_VAL"
    if ! openssl pkey -in "$src" -passin env:SSL_KEY_PASS -out "$dest" 2>/dev/null; then
      warn "Sai passphrase hoac khong doc duoc key."; rm -f "$dest"; return 1
    fi
  else
    cp "$src" "$dest"
    if ! openssl pkey -in "$dest" -noout 2>/dev/null; then rm -f "$dest"; return 1; fi
  fi
  chmod 600 "$dest"
}

ssl_find_issuer() { # fp -> in ra fp cua cert cap phat (neu co trong POOL)
  local fp="$1" o cands=()
  for o in "${!SUBJ[@]}"; do
    [[ $o == "$fp" ]] && continue
    [[ ${SUBJ[$o]} == "${ISS[$fp]}" ]] && cands+=("$o")
  done
  if ((${#cands[@]} == 0)) && [[ -n ${AKI[$fp]} ]]; then
    for o in "${!SUBJ[@]}"; do
      [[ $o != "$fp" && ${SKI[$o]} == "${AKI[$fp]}" ]] && cands+=("$o")
    done
  fi
  ((${#cands[@]} == 0)) && return 1
  if [[ -n ${AKI[$fp]} ]]; then
    for o in "${cands[@]}"; do
      if [[ ${SKI[$o]} == "${AKI[$fp]}" ]]; then echo "$o"; return 0; fi
    done
  fi
  echo "${cands[0]}"
}

ssl_fetch_aia() { # fp -> tai cert cap phat tu AIA (Authority Information Access)
  local fp="$1" uri tmp
  uri="$(openssl x509 -noout -ext authorityInfoAccess -in "$POOL/$fp.pem" 2>/dev/null | awk -F'URI:' '/CA Issuers/{print $2; exit}')"
  uri="${uri//[$'\r ']/}"
  [[ -n $uri ]] || return 1
  tmp="$(mktemp)"
  if ! curl -fsSL --max-time 20 -o "$tmp" "$uri"; then rm -f "$tmp"; return 1; fi
  ssl_import_file "$tmp"; local rc=$?
  rm -f "$tmp"
  return $rc
}

# ---------- bao cao / kiem tra ----------
ssl_report() { # bundle [key]
  local b="$1" k="${2:-}" cnt end days san tmp i ok=1 last ch kh perm
  local files=() vargs=() v2=()
  [[ -f $b ]] || { err "Khong thay file $b"; return 1; }
  cnt="$(grep -c 'BEGIN CERTIFICATE' "$b" || true)"
  echo "  So chung chi trong file : $cnt"
  openssl x509 -noout -subject -issuer -startdate -enddate -in "$b" 2>/dev/null | sed 's/^/  /'
  san="$(openssl x509 -noout -ext subjectAltName -in "$b" 2>/dev/null | tail -n +2 | sed 's/^ *//' | tr -d '\n')"
  [[ -n $san ]] && echo "  SAN                     : $san"
  end="$(openssl x509 -noout -enddate -in "$b" 2>/dev/null | cut -d= -f2)"
  if [[ -n $end ]]; then
    days=$(( ($(date -d "$end" +%s) - $(date +%s)) / 86400 ))
    if ((days < 0)); then err "Chung chi DA HET HAN ($((-days)) ngay truoc)"
    elif ((days < 30)); then warn "Chi con $days ngay la het han"
    else log "Con $days ngay het han"; fi
  fi

  tmp="$(mktemp -d)"
  tr -d '\r' <"$b" | ssl_split_pem "$tmp"
  mapfile -t files < <(find "$tmp" -name 'c*.pem' | sort)
  if ((${#files[@]} == 0)); then err "Khong doc duoc chung chi nao trong $b"; rm -rf "$tmp"; return 1; fi
  for ((i = 0; i < ${#files[@]} - 1; i++)); do
    [[ "$(ssl_dn "${files[i]}" issuer)" == "$(ssl_dn "${files[i + 1]}" subject)" ]] || ok=0
  done
  if ((ok)); then log "Thu tu chain dung (leaf -> intermediate -> root)"; else warn "Thu tu chain bat thuong: cert sau khong phai issuer cua cert truoc"; fi

  : >"$tmp/untrusted.pem"
  for ((i = 1; i < ${#files[@]}; i++)); do cat "${files[i]}" >>"$tmp/untrusted.pem"; done
  vargs=(-CAfile "$SSL_SYSTEM_CA")
  ((${#files[@]} > 1)) && vargs+=(-untrusted "$tmp/untrusted.pem")
  last="${files[-1]}"
  v2=(-CAfile "$last")
  ((${#files[@]} > 2)) && v2+=(-untrusted "$tmp/untrusted.pem")
  if openssl verify "${vargs[@]}" "${files[0]}" >/dev/null 2>&1; then
    log "Chain hop le theo trust store he thong (CA cong cong)"
  elif [[ "$(ssl_dn "$last" subject)" == "$(ssl_dn "$last" issuer)" ]] && openssl verify "${v2[@]}" "${files[0]}" >/dev/null 2>&1; then
    warn "Chain hop le toi root trong bundle, nhung root KHONG nam trong trust store he thong (binh thuong voi CA noi bo/self-signed): client can import root nay."
  else
    err "Khong xac thuc duoc chain theo trust store he thong: THIEU intermediate, cert het han, hoac root la CA noi bo (khong nam trong trust store)."
  fi

  if [[ -n $k ]]; then
    if [[ ! -f $k ]]; then
      warn "Khong thay private key: $k"
    else
      ch="$(ssl_cert_pubhash "${files[0]}")"; kh="$(ssl_key_pubhash "$k")"
      if [[ -z $kh ]]; then warn "Khong doc duoc key (co the dang ma hoa bang passphrase)."
      elif [[ $ch == "$kh" ]]; then log "Private key KHOP voi chung chi"
      else err "Private key KHONG khop voi chung chi!"; fi
      perm="$(stat -c %a "$k" 2>/dev/null || true)"
      [[ -n $perm && $perm != 600 && $perm != 400 ]] && warn "Quyen file key la $perm, nen chmod 600 $k"
    fi
  fi
  rm -rf "$tmp"
}

ssl_check_live() {
  local h p out cnt
  ask "Host (domain hoac IP)" ""; h="$REPLY_VAL"
  [[ -n $h ]] || return 0
  ask "Cong" "443"; p="$REPLY_VAL"
  out="$(timeout 20 openssl s_client -connect "$h:$p" -servername "$h" -showcerts </dev/null 2>/dev/null || true)"
  if [[ $out != *"BEGIN CERTIFICATE"* ]]; then err "Khong ket noi duoc $h:$p"; return 1; fi
  cnt="$(grep -c 'BEGIN CERTIFICATE' <<<"$out" || true)"
  echo "  So chung chi server gui ve: $cnt (chi 1 chung chi = co the THIEU intermediate trong cau hinh web server)"
  awk '/BEGIN CERTIFICATE/{f=1} f{print} /END CERTIFICATE/{exit}' <<<"$out" | openssl x509 -noout -subject -issuer -dates | sed 's/^/  /'
  grep 'Verify return code' <<<"$out" | tail -n1 | sed 's/^ */  /'
}

ssl_check() {
  section "Kiem tra chung chi"
  choose "Kiem tra" 1 "File bundle + private key tren may nay" "Host dang chay (host:port)"
  if [[ $CHOICE == 2 ]]; then ssl_check_live; return; fi
  if compgen -G "$SSL_BASE/*/bundle.crt" >/dev/null; then
    echo "Cac bundle da tao:" >/dev/tty
    local f; for f in "$SSL_BASE"/*/bundle.crt; do echo "  $f" >/dev/tty; done
  fi
  local b k
  ask "Duong dan file bundle/cert" ""; b="$REPLY_VAL"
  [[ -n $b ]] || return 0
  k="$(dirname "$b")/$(basename "$(dirname "$b")").key"
  ask "Duong dan private key (Enter = bo qua kiem tra khop key)" "$([[ -f $k ]] && echo "$k")"
  ssl_report "$b" "$REPLY_VAL"
}

# ---------- thong tin sau khi tao ----------
ssl_print_usage() { # name
  local n="$1" d="$OUT_DIR"
  cat <<EOF

${BLD}Chi can 2 file nay cho web server:${NC}
  Private key : $d/$n.key
  Bundle      : $d/bundle.crt   (leaf + chain)

${BLD}Nginx:${NC}
  ssl_certificate     $d/bundle.crt;
  ssl_certificate_key $d/$n.key;

${BLD}Apache (>= 2.4.8, khong can SSLCertificateChainFile):${NC}
  SSLCertificateFile    $d/bundle.crt
  SSLCertificateKeyFile $d/$n.key

Sau khi gan: nginx -t && systemctl reload nginx  |  apache2ctl configtest && systemctl reload apache2
EOF
}

ssl_offer_pfx() { # name
  local n="$1" pw
  confirm "Xuat them file .pfx (PKCS12) cho IIS/FortiGate/Java?" n || return 0
  ask_secret "Mat khau cho file .pfx"; pw="$SECRET"
  if PFX_PASS="$pw" openssl pkcs12 -export -inkey "$OUT_DIR/$n.key" -in "$OUT_DIR/bundle.crt" -out "$OUT_DIR/$n.pfx" -passout env:PFX_PASS 2>/dev/null; then
    chmod 600 "$OUT_DIR/$n.pfx"
    save_cred "PFX $n" "$OUT_DIR/$n.pfx" "$pw"
    log "Da tao $OUT_DIR/$n.pfx (mat khau luu tai $CRED_FILE)"
  else
    err "Xuat .pfx that bai."
  fi
}

# ---------- 1) SSL local ----------
ssl_ensure_ca() {
  local d="$SSL_BASE/ca" cn tmp
  CA_CRT="$d/ca.crt"; CA_KEY="$d/ca.key"
  if [[ -f $CA_CRT && -f $CA_KEY ]]; then log "Dung Local CA co san: $CA_CRT"; return 0; fi
  mkdir -p "$d"; chmod 700 "$d"
  ask "Ten Local CA" "Local CA - $(hostname)"; cn="$REPLY_VAL"
  ssl_gen_key rsa4096 "$CA_KEY" || { err "Khong tao duoc khoa CA"; return 1; }
  tmp="$(mktemp -d)"
  cat >"$tmp/ca.cnf" <<EOF
[req]
distinguished_name=dn
prompt=no
x509_extensions=v3_ca
[dn]
CN=$cn
[v3_ca]
basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=hash
EOF
  if ! openssl req -x509 -new -key "$CA_KEY" -config "$tmp/ca.cnf" -days 7300 -sha256 -out "$CA_CRT"; then
    rm -rf "$tmp"; err "Tao CA that bai"; return 1
  fi
  rm -rf "$tmp"; chmod 644 "$CA_CRT"
  log "Da tao Local CA (20 nam): $CA_CRT  (giu kin $CA_KEY)"
}

ssl_selfsigned() {
  section "Tao SSL local cho ten mien"
  local cn extra days mode name san key crt tmp
  while true; do
    ask "Ten mien chinh (CN), vd app.ued.local hoac *.ued.local" ""
    cn="${REPLY_VAL,,}"
    ssl_valid_name "$cn" && break
    warn "Ten mien khong hop le."
  done
  ask "Ten mien/IP bo sung cho SAN (cach nhau bang khoang trang, de trong = khong)" ""
  extra="$REPLY_VAL"
  [[ $cn == \*.* ]] && extra+=" ${cn#\*.}"
  while true; do
    ask "So ngay hieu luc" "3650"
    days="$REPLY_VAL"
    [[ $days =~ ^[0-9]+$ ]] && ((days >= 1)) && break
    warn "Nhap so ngay hop le."
  done
  ssl_pick_keytype
  choose "Kieu chung chi" 1 \
    "Self-signed truc tiep (don gian, moi client tin tung cert)" \
    "Ky bang Local CA (import CA mot lan vao client, dung chung nhieu domain)"
  mode="$CHOICE"
  name="$(ssl_safe_name "$cn")"
  # shellcheck disable=SC2086
  san="$(ssl_build_san "$cn" $extra)"

  ssl_prepare_outdir "$name"
  key="$OUT_DIR/$name.key"; crt="$OUT_DIR/$name.crt"
  ssl_gen_key "$KEYTYPE" "$key" || { err "Khong tao duoc private key"; return 1; }
  tmp="$(mktemp -d)"
  cat >"$tmp/openssl.cnf" <<EOF
[req]
distinguished_name=dn
prompt=no
x509_extensions=ext
req_extensions=ext
[dn]
CN=$cn
[ext]
subjectAltName=$san
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectKeyIdentifier=hash
EOF
  if [[ $mode == 1 ]]; then
    openssl req -x509 -new -key "$key" -config "$tmp/openssl.cnf" -days "$days" -sha256 -out "$crt" \
      || { err "Tao chung chi that bai"; rm -rf "$tmp"; return 1; }
    cp "$crt" "$OUT_DIR/bundle.crt"
  else
    ssl_ensure_ca || { rm -rf "$tmp"; return 1; }
    if ! openssl x509 -checkend $((days * 86400)) -noout -in "$CA_CRT" >/dev/null; then
      warn "Local CA se het han truoc cert ($days ngay). Nen giam so ngay hoac tao lai CA."
    fi
    cp "$tmp/openssl.cnf" "$tmp/sign.cnf"
    echo 'authorityKeyIdentifier=keyid,issuer' >>"$tmp/sign.cnf"
    openssl req -new -key "$key" -config "$tmp/openssl.cnf" -out "$tmp/req.csr" \
      && openssl x509 -req -in "$tmp/req.csr" -CA "$CA_CRT" -CAkey "$CA_KEY" -CAcreateserial \
           -days "$days" -sha256 -extfile "$tmp/sign.cnf" -extensions ext -out "$crt" \
      || { err "Ky chung chi that bai"; rm -rf "$tmp"; return 1; }
    cat "$crt" "$CA_CRT" >"$OUT_DIR/bundle.crt"
    cp "$CA_CRT" "$OUT_DIR/ca.crt"
  fi
  rm -rf "$tmp"
  chmod 644 "$crt" "$OUT_DIR/bundle.crt"
  log "Da tao SSL cho $cn (SAN: $san), hieu luc $days ngay"
  ssl_report "$OUT_DIR/bundle.crt" "$key"
  ssl_print_usage "$name"
  if [[ $mode == 2 ]]; then
    cat <<EOF

${BLD}Local CA:${NC} import $OUT_DIR/ca.crt vao Trusted Root cua client (Windows: certmgr.msc, Linux: cp ca.crt /usr/local/share/ca-certificates/xxx.crt && update-ca-certificates).
EOF
    if confirm "Cai Local CA vao trust store cua chinh may chu nay?" n; then
      install -m 644 "$CA_CRT" /usr/local/share/ca-certificates/server-setup-local-ca.crt && update-ca-certificates
    fi
  fi
  ssl_offer_pfx "$name"
}

# ---------- 2) Let's Encrypt ----------
ssl_letsencrypt() {
  section "Let's Encrypt (certbot)"
  if ! command -v certbot >/dev/null 2>&1; then
    apt_update
    apt_install certbot || { err "Cai certbot that bai"; return 1; }
  fi
  is_installed nginx && apt_install_avail python3-certbot-nginx
  is_installed apache2 && apt_install_avail python3-certbot-apache

  local doms=() d ok wildcard=0 email method lename webroot pre="" post="" s rc live
  local args=()
  while true; do
    ask "Ten mien (cach nhau bang khoang trang, ten dau la ten chinh; ho tro *.domain)" ""
    doms=(); ok=1
    for d in $REPLY_VAL; do
      if [[ $d =~ ^(\*\.)?([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]; then doms+=("${d,,}")
      else warn "Ten mien khong hop le: $d"; ok=0; fi
    done
    ((ok && ${#doms[@]} > 0)) && break
  done
  for d in "${doms[@]}"; do [[ $d == \*.* ]] && wildcard=1; done
  ask "Email nhan thong bao het han (de trong = khong dang ky email)" ""
  email="$REPLY_VAL"

  if ((wildcard)); then
    warn "Co ten mien wildcard: bat buoc dung xac thuc DNS-01."
    method=5
  else
    choose "Phuong thuc xac thuc" 1 \
      "webroot (web server dang chay, khong gian doan)" \
      "standalone (tam dung web server, can cong 80 trong)" \
      "plugin Nginx" \
      "plugin Apache" \
      "DNS thu cong (them TXT record, KHONG tu gia han)"
    method="$CHOICE"
  fi

  lename="${doms[0]#\*.}"
  args=(certonly --cert-name "$lename" --agree-tos --keep-until-expiring)
  if [[ -n $email ]]; then args+=(--email "$email"); else args+=(--register-unsafely-without-email); fi
  for d in "${doms[@]}"; do args+=(-d "$d"); done
  confirm "Dung staging de thu (khong tinh gioi han ty le, cert KHONG duoc tin)?" n && args+=(--staging)

  case "$method" in
    1)
      ask "Duong dan webroot" "/var/www/html"; webroot="$REPLY_VAL"
      [[ -d $webroot ]] || { err "Khong ton tai thu muc $webroot"; return 1; }
      args+=(--webroot -w "$webroot") ;;
    2)
      for s in nginx apache2; do
        if systemctl is-active --quiet "$s" 2>/dev/null; then pre+="systemctl stop $s; "; post+="systemctl start $s; "; fi
      done
      args+=(--standalone --preferred-challenges http)
      if [[ -n $pre ]]; then
        args+=(--pre-hook "$pre" --post-hook "$post")
        warn "Web server dang chay se bi dung ngan han luc cap va moi lan gia han."
      fi ;;
    3)
      is_installed nginx || { err "Nginx chua duoc cai (muc 4)."; return 1; }
      args+=(--nginx) ;;
    4)
      is_installed apache2 || { err "Apache chua duoc cai (muc 4)."; return 1; }
      args+=(--apache) ;;
    5)
      args+=(--manual --preferred-challenges dns)
      warn "Certbot se hien huong dan tao TXT record _acme-challenge; them record, cho vai phut roi nhan Enter."
      warn "Che do nay khong tu gia han duoc; dung plugin DNS (vd python3-certbot-dns-cloudflare) neu can tu dong." ;;
  esac

  fw_allow "80/tcp" "any" "HTTP / ACME"; fw_allow "443/tcp" "any" "HTTPS"
  if [[ $method == 5 ]]; then
    certbot "${args[@]}" </dev/tty >/dev/tty 2>&1; rc=$?
  else
    certbot "${args[@]}" --non-interactive; rc=$?
  fi
  if ((rc != 0)); then err "certbot that bai (ma $rc). Xem /var/log/letsencrypt/letsencrypt.log"; return 1; fi

  live="/etc/letsencrypt/live/$lename"
  [[ -d $live ]] || { err "Khong thay $live"; return 1; }
  ssl_prepare_outdir "$lename"
  ln -sf "$live/privkey.pem"   "$OUT_DIR/$lename.key"
  ln -sf "$live/fullchain.pem" "$OUT_DIR/bundle.crt"
  ln -sf "$live/chain.pem"     "$OUT_DIR/chain.crt"
  ln -sf "$live/cert.pem"      "$OUT_DIR/$lename.crt"
  log "Da cap chung chi. Cac file ben duoi la symlink toi $live (tu cap nhat khi gia han)."

  if [[ $method != 5 ]]; then
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    cat >/etc/letsencrypt/renewal-hooks/deploy/99-reload-webservers.sh <<'EOF'
#!/bin/sh
# server-setup.sh: reload web server sau khi gia han chung chi
if systemctl is-active --quiet nginx && nginx -t >/dev/null 2>&1; then systemctl reload nginx; fi
if systemctl is-active --quiet apache2 && apache2ctl configtest >/dev/null 2>&1; then systemctl reload apache2; fi
exit 0
EOF
    chmod +x /etc/letsencrypt/renewal-hooks/deploy/99-reload-webservers.sh
    systemctl enable --now certbot.timer >/dev/null 2>&1 || warn "Khong bat duoc certbot.timer, kiem tra: systemctl list-timers | grep certbot"
    log "Da bat tu dong gia han (certbot.timer) va hook reload Nginx/Apache."
    confirm "Chay thu gia han (certbot renew --dry-run)?" n && certbot renew --dry-run
  fi
  ssl_report "$OUT_DIR/bundle.crt" "$OUT_DIR/$lename.key"
  ssl_print_usage "$lename"
}

# ---------- 3) Gop cert nha cung cap -> bundle.crt ----------
ssl_bundle_run() {
  local src roots=() zi=0 z r f flist=() nk=0 k plain keyfiles=() fp kf ch kh
  local leaf="" key="" cands=() o is_issuer items=() chain=() cur nxt depth=0 x dup
  local name last has_root=0 incl_root=1 i total used
  SUBJ=(); ISS=(); SKI=(); AKI=()
  POOL="$WORKDIR/pool"; mkdir -p "$POOL" "$WORKDIR/keys" "$WORKDIR/unz"

  ask "Thu muc (hoac file .zip) chua file tu nha cung cap" "$PWD"
  src="$REPLY_VAL"
  [[ -e $src ]] || { err "Khong ton tai: $src"; return 1; }

  if [[ -d $src ]]; then
    roots+=("$src")
    while IFS= read -r -d '' z; do
      command -v unzip >/dev/null 2>&1 || apt_install unzip
      zi=$((zi + 1))
      unzip -qq -o "$z" -d "$WORKDIR/unz/$zi" 2>/dev/null && roots+=("$WORKDIR/unz/$zi")
    done < <(find "$src" -maxdepth 2 -type f -iname '*.zip' -print0)
  else
    case "${src,,}" in
      *.zip)
        command -v unzip >/dev/null 2>&1 || apt_install unzip
        unzip -qq -o "$src" -d "$WORKDIR/unz/1" && roots+=("$WORKDIR/unz/1") ;;
      *) roots+=("$src") ;;
    esac
  fi
  for r in "${roots[@]}"; do
    while IFS= read -r -d '' f; do flist+=("$f"); done < <(find "$r" -maxdepth 3 -type f -size -2048k ! -iname 'bundle.crt' ! -iname '*.zip' -print0 2>/dev/null)
  done
  ((${#flist[@]} > 0)) || { err "Khong co file nao trong $src"; return 1; }

  for f in "${flist[@]}"; do
    if grep -aqE 'BEGIN (RSA |EC |ENCRYPTED |DSA )?PRIVATE KEY' "$f"; then
      nk=$((nk + 1)); cp "$f" "$WORKDIR/keys/k$nk.raw"
    fi
    ssl_import_file "$f" >/dev/null || true
  done
  total=${#SUBJ[@]}
  if ((total == 0)); then
    err "Khong tim thay chung chi nao trong $src (ho tro .crt .cer .pem .ca-bundle .p7b .zip)."; return 1
  fi
  log "Tim thay $total chung chi (da loai trung):"
  for fp in "${!SUBJ[@]}"; do
    printf '   - %s   (cap boi: %s)\n' "$(ssl_cn "${SUBJ[$fp]}")" "$(ssl_cn "${ISS[$fp]}")"
  done

  # private key
  for k in "$WORKDIR"/keys/k*.raw; do
    [[ -f $k ]] || continue
    plain="${k%.raw}.key"
    ssl_load_key "$k" "$plain" && keyfiles+=("$plain")
  done
  ((${#keyfiles[@]} > 0)) && log "Tim thay ${#keyfiles[@]} private key trong thu muc"

  # xac dinh leaf: cert khop private key
  for fp in "${!SUBJ[@]}"; do
    ch="$(ssl_cert_pubhash "$POOL/$fp.pem")"
    for kf in "${keyfiles[@]}"; do
      kh="$(ssl_key_pubhash "$kf")"
      if [[ -n $ch && $ch == "$kh" ]]; then leaf="$fp"; key="$kf"; break 2; fi
    done
  done

  if [[ -z $leaf ]]; then
    ((${#keyfiles[@]} > 0)) && warn "Co private key nhung khong khop chung chi nao; xac dinh leaf theo cau truc chain."
    for fp in "${!SUBJ[@]}"; do
      is_issuer=0
      for o in "${!SUBJ[@]}"; do
        [[ $o != "$fp" && ${ISS[$o]} == "${SUBJ[$fp]}" ]] && is_issuer=1
      done
      ((is_issuer == 0)) && cands+=("$fp")
    done
    if ((${#cands[@]} == 0)); then err "Khong xac dinh duoc chung chi server (leaf)."; return 1; fi
    if ((${#cands[@]} == 1)); then
      leaf="${cands[0]}"
    else
      for fp in "${cands[@]}"; do items+=("$(ssl_cn "${SUBJ[$fp]}")"); done
      choose "Co nhieu chung chi server, chon cai can gop" 1 "${items[@]}"
      leaf="${cands[$((CHOICE - 1))]}"
    fi
    ask "Duong dan private key cua $(ssl_cn "${SUBJ[$leaf]}") (Enter = bo qua, chi tao bundle)" ""
    if [[ -n $REPLY_VAL ]]; then
      if [[ -f $REPLY_VAL ]] && ssl_load_key "$REPLY_VAL" "$WORKDIR/keys/manual.key"; then
        ch="$(ssl_cert_pubhash "$POOL/$leaf.pem")"; kh="$(ssl_key_pubhash "$WORKDIR/keys/manual.key")"
        if [[ -n $ch && $ch == "$kh" ]]; then key="$WORKDIR/keys/manual.key"
        else
          err "Private key KHONG khop chung chi."
          confirm "Van tiep tuc tao bundle (khong kem key)?" n || return 1
        fi
      else
        warn "Khong doc duoc key, chi tao bundle."
      fi
    fi
  fi
  log "Chung chi server (leaf): $(ssl_cn "${SUBJ[$leaf]}")"

  # dung chain: leaf -> intermediate -> (root)
  chain=("$leaf"); cur="$leaf"
  while ((depth < 8)); do
    depth=$((depth + 1))
    [[ ${SUBJ[$cur]} == "${ISS[$cur]}" ]] && break
    nxt="$(ssl_find_issuer "$cur")" || nxt=""
    if [[ -z $nxt ]]; then
      if ssl_fetch_aia "$cur"; then
        log "Da tai them chung chi cap phat tu AIA cho: $(ssl_cn "${SUBJ[$cur]}")"
        nxt="$(ssl_find_issuer "$cur")" || nxt=""
      fi
    fi
    if [[ -z $nxt ]]; then
      warn "Khong tim thay chung chi cap phat cho: $(ssl_cn "${SUBJ[$cur]}") (co the root da co san trong trust store cua client)"
      break
    fi
    dup=0; for x in "${chain[@]}"; do [[ $x == "$nxt" ]] && dup=1; done
    ((dup)) && break
    chain+=("$nxt"); cur="$nxt"
  done
  used=${#chain[@]}
  ((total > used)) && warn "Bo qua $((total - used)) chung chi khong thuoc chain cua $(ssl_cn "${SUBJ[$leaf]}")."
  log "Chain xac dinh:"
  for i in "${!chain[@]}"; do printf '   %d) %s\n' $((i + 1)) "$(ssl_cn "${SUBJ[${chain[$i]}]}")"; done
  if ((used == 1)) && [[ ${SUBJ[$leaf]} != "${ISS[$leaf]}" ]]; then
    warn "Bundle chi co 1 chung chi (thieu intermediate). Hay them file intermediate cua nha cung cap vao thu muc roi chay lai."
  fi

  last="${chain[-1]}"
  [[ ${SUBJ[$last]} == "${ISS[$last]}" ]] && ((used > 1)) && has_root=1
  if ((has_root)); then
    confirm "Gom ca Root CA vao bundle? (khong bat buoc, nhung 'du bo' cho client/thiet bi cu)" y || incl_root=0
  fi

  name="$(ssl_safe_name "$(ssl_cn "${SUBJ[$leaf]}")")"
  ask "Ten thu muc/ten file dau ra" "$name"
  name="$(ssl_safe_name "$REPLY_VAL")"
  [[ -n $name ]] || { err "Ten khong hop le"; return 1; }
  ssl_prepare_outdir "$name"
  : >"$OUT_DIR/bundle.crt"; : >"$OUT_DIR/chain.crt"
  for i in "${!chain[@]}"; do
    fp="${chain[$i]}"
    if ((has_root && !incl_root && i == used - 1)); then continue; fi
    cat "$POOL/$fp.pem" >>"$OUT_DIR/bundle.crt"
    ((i > 0)) && cat "$POOL/$fp.pem" >>"$OUT_DIR/chain.crt"
  done
  cp "$POOL/$leaf.pem" "$OUT_DIR/$name.crt"
  [[ -s $OUT_DIR/chain.crt ]] || rm -f "$OUT_DIR/chain.crt"
  chmod 644 "$OUT_DIR/bundle.crt" "$OUT_DIR/$name.crt"
  if [[ -n $key ]]; then install -m 600 "$key" "$OUT_DIR/$name.key"; fi
  log "Da tao: $OUT_DIR/bundle.crt"
  if [[ -n $key ]]; then ssl_report "$OUT_DIR/bundle.crt" "$OUT_DIR/$name.key"; else ssl_report "$OUT_DIR/bundle.crt"; fi
  if [[ -n $key ]]; then
    ssl_print_usage "$name"
    ssl_offer_pfx "$name"
  else
    warn "Chua co private key trong $OUT_DIR; hay copy key cua ban thanh $OUT_DIR/$name.key (chmod 600)."
  fi
}

ssl_bundle() {
  section "Gop chung chi nha cung cap thanh bundle.crt"
  WORKDIR="$(mktemp -d)"
  ssl_bundle_run; local rc=$?
  rm -rf "$WORKDIR"; WORKDIR=""; SSL_KEY_PASS=""
  return $rc
}

mod_ssl() {
  section "SSL / TLS"
  command -v openssl >/dev/null 2>&1 || apt_install openssl
  local def=1
  while true; do
    choose "Chuc nang SSL" "$def" \
      "Tao SSL local cho ten mien (mac dinh 10 nam)" \
      "Tao va lay SSL tu Let's Encrypt" \
      "Gop chung chi nha cung cap thanh bundle.crt (key + bundle.crt la du cho Nginx/Apache)" \
      "Kiem tra chung chi (file bundle/key hoac host dang chay)" \
      "Quay lai menu chinh"
    case "$CHOICE" in
      1) ssl_selfsigned ;;
      2) ssl_letsencrypt ;;
      3) ssl_bundle ;;
      4) ssl_check ;;
      5) return 0 ;;
    esac
    def=5
  done
}

#===============================================================================
# MENU CHINH
#===============================================================================
run_module() {
  case "$1" in
    0) mod_base ;;
    1) mod_ntp ;;
    2) mod_php ;;
    3) mod_db ;;
    4) mod_web ;;
    5) mod_node ;;
    6) mod_docker ;;
    7) mod_extras ;;
    8) mod_security ;;
    9) mod_ssl ;;
  esac
}

main_menu() {
  local sel t list
  while true; do
    {
      printf '\n%s================================================================%s\n' "$BLD" "$NC"
      printf '%s  SERVER SETUP v%s - Ubuntu %s (%s) - %s%s\n' "$BLD" "$SCRIPT_VERSION" "$OS_VER" "$OS_CODENAME" "$(hostname)" "$NC"
      printf '%s================================================================%s\n' "$BLD" "$NC"
      echo "  0) Chuan bi he thong: cap nhat, goi co ban, hostname"
      echo "  1) NTP & mui gio (tuy chon lam NTP server noi bo)"
      echo "  2) PHP-FPM 7.2 -> moi nhat"
      echo "  3) Database: MySQL / MariaDB / PostgreSQL / MongoDB"
      echo "  4) Web server: Nginx / Apache / Certbot"
      echo "  5) NodeJS"
      echo "  6) Docker"
      echo "  7) Tien ich: swap, sysctl, qemu-guest-agent, node_exporter, Wazuh agent"
      echo "  8) Bao mat: UFW, Fail2ban, SSH hardening, auto-update"
      echo "  9) SSL/TLS: tao SSL local, Let's Encrypt, gop bundle.crt tu nha cung cap, kiem tra"
      echo "  a) Chay muc 0-8 theo thu tu (SSL chay rieng bang muc 9)"
      echo "  q) Thoat"
      printf 'Chon (co the nhap nhieu muc, vd: 0 1 6): '
    } >/dev/tty
    read -r sel </dev/tty || break
    sel="${sel,,}"; sel="${sel//,/ }"
    [[ $sel == q* ]] && break
    [[ $sel == a ]] && sel="0 1 2 3 4 5 6 7 8"
    list=""
    for t in $sel; do
      if [[ $t =~ ^[0-9]$ ]]; then list+="$t"$'\n'; else warn "Bo qua lua chon khong hop le: $t"; fi
    done
    [[ -z $list ]] && continue
    for t in $(printf '%s' "$list" | sort -un); do
      run_module "$t" || warn "Muc $t ket thuc voi loi, xem log: $LOG_FILE"
    done
    pause
  done
  section "Hoan tat"
  log "Log:       $LOG_FILE"
  [[ -s $CRED_FILE ]] && log "Mat khau:  $CRED_FILE (chi root doc duoc)"
  log "Nen reboot neu da cap nhat kernel hoac thay doi ulimit: sudo reboot"
}

# Chi chay menu khi thuc thi truc tiep (cho phep `source` file de test tung ham)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  detect_os
  setup_vim_ubuntu26
  main_menu
fi
