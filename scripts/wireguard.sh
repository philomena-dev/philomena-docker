#!/usr/bin/env bash
# This file is meant to be sourced by `philomena.sh`, not executed directly.
# It sets up the WireGuard tunnel between the app server and the proxy
# server, which the link between them then runs through. A deployment works
# without it, but the app server then has a port open to the internet.
#
# The tunnel belongs to the host, not to a container: this only writes its
# configuration to ./wireguard. `scripts/install-wireguard.sh`, run as root,
# installs it.

wireguard_dir=wireguard

# Print a new private key and its public key, separated by a space.
function wireguard_keypair {
  local pem private public

  if command -v wg > /dev/null 2>&1; then
    private=$(wg genkey)
    public=$(printf '%s' "$private" | wg pubkey)
  else
    # A WireGuard key is a raw X25519 key, which is the last 32 bytes of what
    # OpenSSL writes.
    pem=$(openssl genpkey -algorithm X25519 2> /dev/null) ||
      die "This version of OpenSSL cannot create WireGuard keys. Install wireguard-tools and try again."
    private=$(printf '%s\n' "$pem" | openssl pkey -outform DER | tail -c 32 | base64)
    public=$(printf '%s\n' "$pem" | openssl pkey -pubout -outform DER | tail -c 32 | base64)
  fi

  echo "$private $public"
}

function is_ipv4_address {
  [[ $1 =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]
}

function explain_wireguard_install {
  echo >&2
  echo "The tunnel is installed by root. On this server, run:" >&2
  echo "  apt install wireguard-tools" >&2
  echo "  $repo_root/scripts/install-wireguard.sh" >&2
}

# App server: create the keys and the configuration of both ends, and route
# the link through the tunnel.
function wireguard_create {
  local endpoint port app_keys proxy_keys preshared

  if [[ -e $wireguard_dir/philomena.conf ]]; then
    warn "This replaces the keys of the tunnel. The link stays down until the new"
    warn "configuration is installed on both servers."
    confirm "Replace the WireGuard configuration?" || exit 1
  fi

  endpoint=$(env_get WIREGUARD_ENDPOINT)
  port=$(env_get WIREGUARD_PORT)

  echo "The app server connects to the proxy server, so only the proxy server" >&2
  echo "needs a port that is reachable from outside." >&2
  ask WIREGUARD_ENDPOINT_ADDRESS "Public address of the proxy server" "${endpoint:-$(env_get PROXY_SERVER)}"
  ask WIREGUARD_PORT "UDP port of the tunnel on the proxy server" "${port:-51820}"
  ask WIREGUARD_APP_ADDRESS "Address of this server inside the tunnel" 10.99.0.1
  ask WIREGUARD_PROXY_ADDRESS "Address of the proxy server inside the tunnel" 10.99.0.2

  [[ -n $WIREGUARD_ENDPOINT_ADDRESS ]] || die "The public address of the proxy server is required."
  [[ $WIREGUARD_PORT =~ ^[0-9]+$ ]] || die "The port must be a number."

  if ! is_ipv4_address "$WIREGUARD_APP_ADDRESS" || ! is_ipv4_address "$WIREGUARD_PROXY_ADDRESS"; then
    die "The addresses inside the tunnel must be IPv4 addresses."
  fi

  [[ $WIREGUARD_APP_ADDRESS != "$WIREGUARD_PROXY_ADDRESS" ]] || die "The two addresses inside the tunnel must differ."

  if is_ipv4_address "$WIREGUARD_ENDPOINT_ADDRESS" && [[ $WIREGUARD_ENDPOINT_ADDRESS == "$WIREGUARD_PROXY_ADDRESS" ]]; then
    die "The public address of the proxy server is needed here, not its address inside the tunnel."
  fi

  read -r -a app_keys <<< "$(wireguard_keypair)"
  read -r -a proxy_keys <<< "$(wireguard_keypair)"
  preshared=$(openssl rand -base64 32)

  # An IPv6 address is written in brackets when a port follows it.
  endpoint=$WIREGUARD_ENDPOINT_ADDRESS

  if [[ $endpoint == *:* && $endpoint != \[* ]]; then
    endpoint="[$endpoint]"
  fi

  mkdir -p "$wireguard_dir"
  chmod 700 "$wireguard_dir"

  (
    umask 077

    cat > "$wireguard_dir/philomena.conf" << EOF
# WireGuard tunnel to the proxy server of this Philomena deployment.
# Written by './philomena.sh wireguard', installed by scripts/install-wireguard.sh.

[Interface]
PrivateKey = ${app_keys[0]}
Address = $WIREGUARD_APP_ADDRESS/32

[Peer]
PublicKey = ${proxy_keys[1]}
PresharedKey = $preshared
Endpoint = $endpoint:$WIREGUARD_PORT
AllowedIPs = $WIREGUARD_PROXY_ADDRESS/32
PersistentKeepalive = 25
EOF

    cat > "$wireguard_dir/proxy.conf" << EOF
# WireGuard tunnel to the app server of this Philomena deployment.
# Written by './philomena.sh wireguard', installed by scripts/install-wireguard.sh.

[Interface]
PrivateKey = ${proxy_keys[0]}
Address = $WIREGUARD_PROXY_ADDRESS/32
ListenPort = $WIREGUARD_PORT

[Peer]
PublicKey = ${app_keys[1]}
PresharedKey = $preshared
AllowedIPs = $WIREGUARD_APP_ADDRESS/32
EOF
  )

  if ! grep -qE '^ORIGIN_BIND=' "$env_file"; then
    {
      echo
      echo "## WireGuard tunnel"
      echo "#"
      echo "# The link to the proxy server runs through a WireGuard tunnel: the two"
      echo "# addresses of the link above are addresses inside the tunnel, and the"
      echo "# link's port is only published on this server's one."
      echo "WIREGUARD_ENDPOINT="
      echo "WIREGUARD_PORT="
      echo "ORIGIN_BIND="
    } >> "$env_file"
  fi

  env_set WIREGUARD_ENDPOINT "$WIREGUARD_ENDPOINT_ADDRESS"
  env_set WIREGUARD_PORT "$WIREGUARD_PORT"
  env_set ORIGIN_BIND "$WIREGUARD_APP_ADDRESS"
  env_set ORIGIN_ADDRESS "$WIREGUARD_APP_ADDRESS"
  env_set PROXY_SERVER "$WIREGUARD_PROXY_ADDRESS"

  info "Wrote the WireGuard configuration of both servers to ./$wireguard_dir."
  explain_wireguard_install
  echo >&2
  echo "Then:" >&2
  echo "  1. Run './philomena.sh up' here (or continue with './philomena.sh setup')." >&2
  echo "  2. Run './philomena.sh proxy-bundle' and copy the bundle to the proxy server." >&2
  echo "  3. On a proxy server that is already set up, run" >&2
  echo "     './philomena.sh wireguard proxy-bundle.tar.gz'. On a new one, run" >&2
  echo "     './philomena.sh prepare --proxy proxy-bundle.tar.gz' as usual." >&2
  echo "  4. Install the tunnel on the proxy server as well, and run './philomena.sh up' there." >&2
  echo >&2
  echo "The proxy server has to accept UDP port $WIREGUARD_PORT from this server." >&2
}

# Proxy server: take the tunnel configuration out of an unpacked bundle.
function wireguard_install_from_bundle {
  local staging=$1

  [[ -f $staging/wireguard/philomena.conf ]] || return 1

  mkdir -p "$wireguard_dir"
  chmod 700 "$wireguard_dir"

  (
    umask 077
    cp "$staging/wireguard/philomena.conf" "$wireguard_dir/philomena.conf"
  )
}

# Proxy server that is already set up: switch its end of the link over to
# the tunnel described by a new bundle.
function wireguard_join {
  local bundle=$1 staging

  [[ -r $bundle ]] || die "Cannot read $bundle"

  staging=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$staging'" EXIT

  tar -xzf "$bundle" -C "$staging"

  wireguard_install_from_bundle "$staging" ||
    die "$bundle does not contain a WireGuard configuration. Run './philomena.sh wireguard' on the app server, then make a new bundle."

  env_set ORIGIN_URL "$(env_get ORIGIN_URL "$staging/proxy.env")"
  env_set SCRAPER_LINK_BIND "$(env_get SCRAPER_LINK_BIND "$staging/proxy.env")"

  info "Wrote the WireGuard configuration to ./$wireguard_dir, and pointed the link at the tunnel."
  explain_wireguard_install
  echo >&2
  echo "Then run './philomena.sh up', and delete $bundle; it contains credentials." >&2
}

function cmd_wireguard {
  require_config
  require_command openssl

  case "$(role)" in
    app)
      if [[ ${1:-} == --yes || ${1:-} == -y ]]; then
        assume_yes=true
        shift
      fi

      [[ $# -eq 0 ]] || die "Usage: ./philomena.sh wireguard [--yes]"
      wireguard_create
      ;;

    proxy)
      [[ $# -eq 1 ]] || die "Usage: ./philomena.sh wireguard <bundle>"
      wireguard_join "$1"
      ;;

    *)
      die "A single server has no link to put in a tunnel."
      ;;
  esac
}
