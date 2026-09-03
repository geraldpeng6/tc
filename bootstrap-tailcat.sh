#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly INSTALLER_VERSION="1.1.1"
readonly TAILCAT_VERSION="0.4.0"
readonly DOWNLOAD_BASE="https://github.com/tailscale/tailcat/releases/download/v${TAILCAT_VERSION}"
readonly TAILCAT_BIN="/usr/bin/tailcat"
readonly DEFAULT_ALLOWED_CLIENTS="nodekey:6381fe8fa9c2b67c7d25ded51bde5e39d8c29b55dcd9411a44ba1525ac2f543f"
readonly DEFAULT_DERP_HOSTS="derp1d.tailscale.com"

readonly LEGACY_SUPPORT_USER="tailcat-support"
readonly LEGACY_SUPPORT_GROUP="tailcat-support"
readonly STATE_DIR="/var/lib/tailcat"
readonly LEGACY_SUPPORT_HOME="${STATE_DIR}/home"
readonly WORK_DIR="${STATE_DIR}/work"
readonly KEY_FILE="${STATE_DIR}/server.private.json"
readonly TOKEN_FILE="${STATE_DIR}/token"
readonly ALLOW_FILE="${STATE_DIR}/allowed-clients"
readonly RELAY_FILE="${STATE_DIR}/relay"
readonly MANAGED_USER_FILE="${STATE_DIR}/managed-user"
readonly LEGACY_KEY_FILE="/root/.config/tailcat/keys/default.private.json"

readonly SERVICE_NAME="tailcat-ssh"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
readonly RUNTIME_TOKEN="/run/tailcat-support/token"
readonly LOCK_FILE="/run/tailcat-bootstrap.lock"

readonly -a DOWNLOAD_PROXIES=(
    ""
    "https://gh-proxy.com"
    "https://ghfast.top"
)

MODE="install"
ALLOWED_CLIENTS=""
DERP_HOSTS=""
USE_PUBLIC_DERP=0
DURATION_MINUTES=0
SERVICE_USER=""
SERVICE_GROUP=""
SERVICE_HOME=""
SERVICE_SHELL=""
TMP_DIR=""
ASSET_NAME=""
PACKAGE_ARCH=""
EXPECTED_SHA256=""
TOKEN=""
MIGRATED_LEGACY_KEY=0
SERVICE_STARTED=0
INSTALL_COMPLETE=0

log()  { printf '[bootstrap] %s\n' "$*"; }
warn() { printf '[bootstrap] WARNING: %s\n' "$*" >&2; }
die()  { printf '[bootstrap] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: sudo bash bootstrap-tailcat.sh [--allow KEY[,KEY...]] [--derp HOST[,HOST...]]
       sudo bash bootstrap-tailcat.sh --duration-minutes N
       sudo bash bootstrap-tailcat.sh --uninstall

Mode: install (default) | --uninstall

Install modes:
  Default (recommended): persistent service. Enabled at boot, always
  running, and survives machine restarts with a stable token.
  --duration-minutes N: instead run a temporary support window that
  auto-stops after N minutes (5-1440) and stays disabled at boot.

Options:
  --allow KEYS       Allowed tailcat client public keys. A bundled key is used by default.
                     Re-run with a new list to revoke or rotate support clients.
  --derp HOSTS       DERP hostname(s), comma-separated. A bundled host is used by default.
  --public-derp      Explicitly use Tailcat's best-effort public relay service.
  --duration-minutes N
                     Temporary support window in minutes, 5-1440.
                     Omit for a persistent service (default).
  --uninstall        Remove the service, device identity, and token.
  -h, --help         Show this help.

In the default persistent mode the service runs as the user who invoked
sudo, inherits that user's existing sudo policy, and restarts
automatically after failures or reboots.
EOF
}

parse_args() {
    while (($# > 0)); do
        case "$1" in
            --allow=*) ALLOWED_CLIENTS="${1#*=}"; shift ;;
            --allow)
                (($# >= 2)) || die "--allow requires a value"
                ALLOWED_CLIENTS="$2"; shift 2
                ;;
            --derp=*) DERP_HOSTS="${1#*=}"; shift ;;
            --derp)
                (($# >= 2)) || die "--derp requires a value"
                DERP_HOSTS="$2"; shift 2
                ;;
            --public-derp) USE_PUBLIC_DERP=1; shift ;;
            --duration-minutes=*) DURATION_MINUTES="${1#*=}"; shift ;;
            --duration-minutes)
                (($# >= 2)) || die "--duration-minutes requires a value"
                DURATION_MINUTES="$2"; shift 2
                ;;
            --uninstall) MODE="uninstall"; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "unknown argument: $1" ;;
        esac
    done

    if [[ "$MODE" == "uninstall" ]]; then
        [[ -z "$ALLOWED_CLIENTS" && -z "$DERP_HOSTS" && "$USE_PUBLIC_DERP" -eq 0 && "$DURATION_MINUTES" -eq 0 ]] \
            || die "--uninstall cannot be combined with install options"
        return 0
    fi

    [[ "$DURATION_MINUTES" -eq 0 ]] || {
        [[ "$DURATION_MINUTES" =~ ^[0-9]+$ ]] || die "duration must be an integer"
        ((DURATION_MINUTES >= 5 && DURATION_MINUTES <= 1440)) \
            || die "duration must be between 5 and 1440 minutes"
    }
    [[ -z "$DERP_HOSTS" || "$USE_PUBLIC_DERP" -eq 0 ]] \
        || die "use either --derp or --public-derp, not both"
    [[ -z "$ALLOWED_CLIENTS" ]] || validate_allowed_clients "$ALLOWED_CLIENTS"
    [[ -z "$DERP_HOSTS" ]] || validate_derp_hosts "$DERP_HOSTS"
}

validate_allowed_clients() {
    local keys="$1"
    [[ "$keys" =~ ^nodekey:[0-9a-f]{64}(,nodekey:[0-9a-f]{64})*$ ]] \
        || die "--allow must contain comma-separated nodekey:<64 lowercase hex> values"
}

validate_derp_hosts() {
    local value="$1" host
    local hostname_re='^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'
    local -a hosts

    ((${#value} <= 1024)) || die "--derp is too long"
    [[ "$value" != ,* && "$value" != *, && "$value" != *,,* ]] \
        || die "--derp contains an empty hostname"
    IFS=',' read -r -a hosts <<<"$value"
    ((${#hosts[@]} > 0)) || die "--derp requires at least one hostname"
    for host in "${hosts[@]}"; do
        if ((${#host} > 253)) || [[ ! "$host" =~ $hostname_re ]]; then
            die "invalid DERP hostname: $host"
        fi
    done
}

probe_derp_hosts() {
    local host status
    local -a hosts

    IFS=',' read -r -a hosts <<<"$DERP_HOSTS"
    for host in "${hosts[@]}"; do
        status="$(curl --fail --show-error --silent --output /dev/null --write-out '%{http_code}' \
            --proto '=https' --connect-timeout 8 --max-time 15 \
            "https://${host}/derp/probe")" || die "DERP health check failed: $host"
        [[ "$status" == "200" ]] || die "DERP probe returned HTTP $status: $host"
    done
}

need_root() {
    [[ "$EUID" -eq 0 ]] || die "run with sudo"
}

need_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

preflight() {
    local command_name
    local os_id="" os_id_like=""

    need_root
    [[ "$(uname -s)" == "Linux" ]] || die "only Linux is supported"
    [[ -d /run/systemd/system ]] || die "systemd is not running"
    for command_name in flock getent groupdel id systemctl userdel; do
        need_command "$command_name"
    done
    [[ "$MODE" == "install" ]] || return 0

    [[ -r /etc/os-release ]] || die "/etc/os-release is missing"
    # shellcheck disable=SC1091
    source /etc/os-release
    os_id="${ID:-}"
    os_id_like=" ${ID_LIKE:-} "
    [[ "$os_id" == "debian" || "$os_id" == "ubuntu" || "$os_id_like" == *" debian "* ]] \
        || die "only Debian/Ubuntu-family systems are supported"
    for command_name in cmp curl dpkg dpkg-deb dpkg-query install mktemp sha256sum; do
        need_command "$command_name"
    done
}

acquire_lock() {
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "another bootstrap process is running"
}

select_package() {
    local architecture="$1"
    local machine="$2"

    case "$architecture" in
        amd64)
            ASSET_NAME="tailcat_${TAILCAT_VERSION}_linux_amd64.deb"
            PACKAGE_ARCH="amd64"
            EXPECTED_SHA256="38ff4b45fe56b32c75738c10dfed4f0b68d33bee49a19695f4bb9f9ec5d6e3c0"
            ;;
        arm64)
            ASSET_NAME="tailcat_${TAILCAT_VERSION}_linux_arm64.deb"
            PACKAGE_ARCH="arm64"
            EXPECTED_SHA256="8f1835a3522ecfc855c9f4ece51c2266781fd03ce76da48036b08c4b86193899"
            ;;
        armhf)
            [[ "$machine" != "armv6l" ]] || die "armv6 is not supported by Tailcat's GOARM=7 build"
            [[ "$machine" == "armv7l" || "$machine" == "armv8l" || "$machine" == "aarch64" ]] \
                || die "unsupported armhf CPU: $machine"
            ASSET_NAME="tailcat_${TAILCAT_VERSION}_linux_armv7.deb"
            PACKAGE_ARCH="armhf"
            EXPECTED_SHA256="e98c18862ee1c72ad85db6653b64fdda4fbf6d14980b96f4ada63e09e2456187"
            ;;
        *) die "unsupported Debian architecture: $architecture" ;;
    esac
}

cleanup() {
    if [[ "$SERVICE_STARTED" -eq 1 && "$INSTALL_COMPLETE" -eq 0 ]]; then
        systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    fi
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        rm -rf -- "$TMP_DIR"
    fi
}

download_package() {
    local origin="${DOWNLOAD_BASE}/${ASSET_NAME}"
    local proxy url
    local deb="${TMP_DIR}/${ASSET_NAME}"

    for proxy in "${DOWNLOAD_PROXIES[@]}"; do
        if [[ -n "$proxy" ]]; then
            url="${proxy}/${origin}"
            log "direct download failed; trying proxy: $proxy" >&2
        else
            url="$origin"
        fi
        if curl --fail --show-error --silent --location \
            --proto '=https' --proto-redir '=https' \
            --connect-timeout 8 --max-time 180 --retry 2 --retry-delay 1 \
            --output "$deb" "$url"; then
            printf '%s  %s\n' "$EXPECTED_SHA256" "$deb" | sha256sum --check --status - \
                || die "SHA256 mismatch for $ASSET_NAME"
            [[ "$(dpkg-deb --field "$deb" Package)" == "tailcat" ]] || die "unexpected package name"
            [[ "$(dpkg-deb --field "$deb" Version)" == "$TAILCAT_VERSION" ]] || die "unexpected package version"
            [[ "$(dpkg-deb --field "$deb" Architecture)" == "$PACKAGE_ARCH" ]] || die "unexpected package architecture"
            printf '%s\n' "$deb"
            return
        fi
    done
    die "failed to download $ASSET_NAME"
}

install_tailcat() {
    local installed_version="" binary_version="" deb

    installed_version="$(dpkg-query --show --showformat='${Version}' tailcat 2>/dev/null || true)"
    if [[ -x "$TAILCAT_BIN" ]]; then
        binary_version="$($TAILCAT_BIN version 2>/dev/null || true)"
    fi
    if [[ "$installed_version" == "$TAILCAT_VERSION" && "$binary_version" == "v${TAILCAT_VERSION}" ]]; then
        log "tailcat v${TAILCAT_VERSION} is already installed"
        return
    fi
    if [[ -n "$installed_version" ]] && dpkg --compare-versions "$installed_version" gt "$TAILCAT_VERSION"; then
        die "refusing to downgrade installed tailcat $installed_version to $TAILCAT_VERSION"
    fi

    deb="$(download_package)"
    dpkg --install "$deb"
    [[ "$(dpkg-query --show --showformat='${Version}' tailcat)" == "$TAILCAT_VERSION" ]] \
        || die "installed package version does not match $TAILCAT_VERSION"
    [[ "$($TAILCAT_BIN version)" == "v${TAILCAT_VERSION}" ]] \
        || die "installed binary version does not match v${TAILCAT_VERSION}"
}

remove_legacy_support_user() {
    [[ -e "$MANAGED_USER_FILE" ]] || return 0
    if getent passwd "$LEGACY_SUPPORT_USER" >/dev/null; then
        userdel "$LEGACY_SUPPORT_USER" || die "could not remove $LEGACY_SUPPORT_USER"
    fi
    if getent group "$LEGACY_SUPPORT_GROUP" >/dev/null; then
        groupdel "$LEGACY_SUPPORT_GROUP" || die "could not remove $LEGACY_SUPPORT_GROUP"
    fi
    rm -f -- "$MANAGED_USER_FILE"
    rmdir "$LEGACY_SUPPORT_HOME" >/dev/null 2>&1 || true
}

select_service_user() {
    local passwd_entry uid

    SERVICE_USER="${SUDO_USER:-}"
    [[ -n "$SERVICE_USER" && "$SERVICE_USER" != "root" ]] \
        || die "run this installer from the intended login user with sudo, not from a root shell"
    [[ "$SERVICE_USER" =~ ^[A-Za-z_][A-Za-z0-9_.-]*[$]?$ ]] \
        || die "unsupported login user name: $SERVICE_USER"
    passwd_entry="$(getent passwd "$SERVICE_USER")" \
        || die "login user does not exist: $SERVICE_USER"
    IFS=: read -r _ _ uid _ _ SERVICE_HOME SERVICE_SHELL <<<"$passwd_entry"
    [[ "$uid" =~ ^[0-9]+$ && "$uid" != "0" ]] \
        || die "service user must not have UID 0"
    [[ -d "$SERVICE_HOME" ]] || die "login user home does not exist: $SERVICE_HOME"
    [[ "$SERVICE_HOME" == /* && "$SERVICE_HOME" != *['"'\\%]* ]] \
        || die "login user home cannot be written safely to a systemd unit"
    [[ "$SERVICE_SHELL" == /* && -x "$SERVICE_SHELL" && "$SERVICE_SHELL" != *['"'\\%]* ]] \
        || die "login user has an unusable shell: $SERVICE_SHELL"
    SERVICE_GROUP="$(id -gn "$SERVICE_USER")"
    [[ "$SERVICE_GROUP" =~ ^[A-Za-z_][A-Za-z0-9_.-]*[$]?$ ]] \
        || die "unsupported primary group name: $SERVICE_GROUP"

}

configure_allowed_clients() {
    if [[ -n "$ALLOWED_CLIENTS" ]]; then
        validate_allowed_clients "$ALLOWED_CLIENTS"
        printf '%s\n' "$ALLOWED_CLIENTS" >"$ALLOW_FILE"
        chown root:root "$ALLOW_FILE"
        chmod 0600 "$ALLOW_FILE"
    elif [[ -s "$ALLOW_FILE" ]]; then
        ALLOWED_CLIENTS="$(<"$ALLOW_FILE")"
        validate_allowed_clients "$ALLOWED_CLIENTS"
    else
        ALLOWED_CLIENTS="$DEFAULT_ALLOWED_CLIENTS"
        printf '%s\n' "$ALLOWED_CLIENTS" >"$ALLOW_FILE"
        chown root:root "$ALLOW_FILE"
        chmod 0600 "$ALLOW_FILE"
        log "using bundled support client key"
    fi
}

validate_token() {
    [[ "$1" =~ ^tc[A-Za-z0-9_-]+$ ]] || die "invalid tailcat token"
    "$TAILCAT_BIN" parse "$1" >/dev/null || die "tailcat rejected its persisted token"
}

requested_relay() {
    if [[ -n "$DERP_HOSTS" ]]; then
        printf 'custom:%s\n' "$DERP_HOSTS"
    elif [[ "$USE_PUBLIC_DERP" -eq 1 ]]; then
        printf 'public\n'
    fi
    return 0
}

load_saved_relay() {
    local saved

    [[ -z "$DERP_HOSTS" && "$USE_PUBLIC_DERP" -eq 0 ]] || return 0
    if [[ -s "$RELAY_FILE" ]]; then
        saved="$(<"$RELAY_FILE")"
        case "$saved" in
            custom:*)
                DERP_HOSTS="${saved#custom:}"
                validate_derp_hosts "$DERP_HOSTS"
                ;;
            public) USE_PUBLIC_DERP=1 ;;
            legacy) ;;
            *) die "invalid saved relay metadata" ;;
        esac
    elif [[ ! -e "$KEY_FILE" && ! -e "$TOKEN_FILE" && ! -e "$LEGACY_KEY_FILE" ]]; then
        DERP_HOSTS="$DEFAULT_DERP_HOSTS"
        log "using bundled DERP host: $DERP_HOSTS"
    fi
}

prepare_identity() {
    local requested existing tmp_key
    local -a genkey_args

    requested="$(requested_relay)"
    if [[ ! -s "$KEY_FILE" && -s "$TOKEN_FILE" && -s "$LEGACY_KEY_FILE" ]]; then
        [[ -z "$requested" ]] || die "omit relay options while migrating a legacy identity"
        log "migrating legacy server identity"
        printf 'legacy\n' >"$RELAY_FILE"
        chown root:root "$RELAY_FILE"
        chmod 0600 "$RELAY_FILE"
        install -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 0600 "$LEGACY_KEY_FILE" "$KEY_FILE"
        MIGRATED_LEGACY_KEY=1
    fi
    [[ ! -e "$KEY_FILE" || -s "$KEY_FILE" ]] || die "server key is empty"
    if [[ -s "$KEY_FILE" && -s "$LEGACY_KEY_FILE" ]]; then
        cmp --silent "$KEY_FILE" "$LEGACY_KEY_FILE" || die "new and legacy server keys conflict"
        MIGRATED_LEGACY_KEY=1
    fi

    if [[ -s "$KEY_FILE" ]]; then
        [[ -s "$RELAY_FILE" ]] || die "server identity is missing relay metadata"
        if [[ -n "$requested" ]]; then
            existing="$(<"$RELAY_FILE")"
            [[ "$existing" == "$requested" ]] \
                || die "changing relay requires a new server identity and token"
        fi
        if [[ -s "$TOKEN_FILE" ]]; then
            TOKEN="$(<"$TOKEN_FILE")"
            validate_token "$TOKEN"
        fi
    else
        [[ ! -e "$TOKEN_FILE" ]] || die "token exists but its server private key is missing"
        [[ -n "$requested" ]] \
            || die "first install requires --derp; use --public-derp only for best-effort/test deployments"

        tmp_key="${TMP_DIR}/server.private.json"
        genkey_args=(genkey "--key=${tmp_key}")
        if [[ "$requested" == "public" ]]; then
            genkey_args+=(--fixed-region)
        else
            genkey_args+=("--region=${DERP_HOSTS}")
        fi
        TOKEN="$($TAILCAT_BIN "${genkey_args[@]}")"
        validate_token "$TOKEN"
        printf '%s\n' "$requested" >"$RELAY_FILE"
        chown root:root "$RELAY_FILE"
        chmod 0600 "$RELAY_FILE"
        install -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 0600 "$tmp_key" "$KEY_FILE"
    fi

    chown "$SERVICE_USER:$SERVICE_GROUP" "$KEY_FILE"
    chmod 0600 "$KEY_FILE"
}

write_service() {
    cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=On-demand Tailcat hardware support
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
WorkingDirectory=${SERVICE_HOME}
Environment="HOME=${SERVICE_HOME}"
Environment="SHELL=${SERVICE_SHELL}"
Environment=XDG_CONFIG_HOME=/run/tailcat-support/config
Environment=XDG_CACHE_HOME=/run/tailcat-support/cache
Environment=TAILCAT_ADDR_FILE=${RUNTIME_TOKEN}
ExecStart=${TAILCAT_BIN} serve --key=${KEY_FILE} --verbose --allow=${ALLOWED_CLIENTS} no-auth-ssh
EOF
    if [[ "$DURATION_MINUTES" -gt 0 ]]; then
        # Temporary support window: no auto-restart, no boot enable.
        cat >>"$SERVICE_FILE" <<EOF
Restart=no
RuntimeMaxSec=${DURATION_MINUTES}min
EOF
    else
        # Persistent mode: stay up, recover from failures, run at boot.
        cat >>"$SERVICE_FILE" <<'EOF'
Restart=on-failure
RestartSec=3
EOF
    fi
    cat >>"$SERVICE_FILE" <<'EOF'
RuntimeDirectory=tailcat-support
RuntimeDirectoryMode=0700

# The remote shell intentionally inherits this user's normal sudo policy.
EOF
    chmod 0644 "$SERVICE_FILE"
}

service_failure() {
    journalctl --unit "$SERVICE_NAME" --lines 30 --no-pager >&2 || true
    die "$1"
}

start_support_window() {
    local active_token="" attempt

    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl daemon-reload
    systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true
    SERVICE_STARTED=1
    systemctl start "$SERVICE_NAME"

    for ((attempt = 0; attempt < 60; attempt++)); do
        if [[ -s "$RUNTIME_TOKEN" ]]; then
            active_token="$(<"$RUNTIME_TOKEN")"
            break
        fi
        systemctl is-active --quiet "$SERVICE_NAME" || service_failure "service exited before publishing its token"
        sleep 0.5
    done
    [[ -n "$active_token" ]] || service_failure "service did not publish its token within 30 seconds"
    systemctl is-active --quiet "$SERVICE_NAME" || service_failure "service exited after publishing its token"
    validate_token "$active_token"

    if [[ "$DURATION_MINUTES" -eq 0 ]]; then
        # Persistent mode: enable at boot so the token survives reboots.
        systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 \
            || service_failure "could not enable service at boot"
    fi

    if [[ -n "$TOKEN" && "$TOKEN" != "$active_token" ]]; then
        systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
        die "persisted token does not match the server private key; refusing silent identity replacement"
    fi
    TOKEN="$active_token"
    printf '%s\n' "$TOKEN" >"$TOKEN_FILE"
    chown root:root "$TOKEN_FILE"
    chmod 0600 "$TOKEN_FILE"

    if [[ "$MIGRATED_LEGACY_KEY" -eq 1 ]]; then
        rm -f -- "$LEGACY_KEY_FILE"
    fi
    if [[ "$DURATION_MINUTES" -gt 0 ]] \
        && [[ "$(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || true)" == "enabled" ]]; then
        systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
        die "service must not be enabled at boot"
    fi
}

uninstall_service() {
    systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f -- "$SERVICE_FILE" "$LEGACY_KEY_FILE"
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true
    remove_legacy_support_user
    rm -rf -- "$STATE_DIR"
    log "removed the service, device identity, and token; the login user was not changed"
    log "the tailcat package remains installed; remove it with: dpkg --remove tailcat"
}

main() {
    parse_args "$@"
    preflight
    acquire_lock

    if [[ "$MODE" == "uninstall" ]]; then
        uninstall_service
        return
    fi

    select_package "$(dpkg --print-architecture)" "$(uname -m)"
    select_service_user
    TMP_DIR="$(mktemp -d -t tailcat-bootstrap.XXXXXXXX)"
    trap cleanup EXIT

    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    install_tailcat
    install -d -o root -g root -m 0755 "$STATE_DIR"
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 0700 "$WORK_DIR"
    configure_allowed_clients
    load_saved_relay
    [[ -z "$DERP_HOSTS" ]] || probe_derp_hosts
    prepare_identity
    write_service
    start_support_window
    remove_legacy_support_user
    INSTALL_COMPLETE=1

    log "tailcat bootstrap ${INSTALLER_VERSION} installed tailcat v${TAILCAT_VERSION}"
    log "remote session user: ${SERVICE_USER}; existing sudo policy is unchanged"
    if [[ "$DURATION_MINUTES" -gt 0 ]]; then
        log "support window: active for ${DURATION_MINUTES} minutes; disabled at boot"
    else
        log "persistent service: enabled at boot, restarts on failure"
    fi
    printf '\nDevice token:\n%s\n\n' "$TOKEN"
    printf 'Verify remotely: tailcat --key=<device-key> ping %s\n' "$TOKEN"
    printf 'Stop now:       sudo systemctl stop %s\n' "$SERVICE_NAME"
    printf 'Open again:     sudo systemctl start %s\n' "$SERVICE_NAME"
    printf 'Connection log: sudo journalctl -u %s\n' "$SERVICE_NAME"
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    main "$@"
fi
