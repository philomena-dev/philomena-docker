#!/usr/bin/env bash
# This file is meant to be sourced by `philomena.sh`, not executed directly.
# It manages the certificates in ./certs.

# Print the SHA-256 of the public key of a certificate or private key.
function public_key_hash {
  local kind=$1 file=$2

  if [[ $kind == cert ]]; then
    openssl x509 -in "$file" -noout -pubkey
  else
    openssl pkey -in "$file" -pubout
  fi 2> /dev/null | openssl sha256 | awk '{ print $NF }'
}

# Create a self-signed certificate for the three domains.
function cert_self_signed {
  local site cdn ext
  site=$(env_get SITE_DOMAIN)
  cdn=$(env_get CDN_DOMAIN)
  ext=$(env_get EXT_DOMAIN)

  mkdir -p certs

  quiet openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
    -keyout certs/privkey.pem \
    -out certs/fullchain.pem \
    -subj "/CN=$site" \
    -addext "subjectAltName=DNS:$site,DNS:$cdn,DNS:$ext"

  chmod 600 certs/privkey.pem
  env_set TLS_CERT_PATH ''

  info "Created a self-signed certificate for $site, $cdn and $ext, valid for a year."
}

# Copy a certificate and its key from a directory, such as the one certbot
# keeps up to date.
function cert_install {
  local source=${1:-}

  if [[ -z $source ]]; then
    source=$(env_get TLS_CERT_PATH)
    [[ -n $source ]] || die "Usage: ./philomena.sh cert install <directory containing fullchain.pem and privkey.pem>"
  fi

  source=${source%/}

  [[ -r $source/fullchain.pem ]] || die "Cannot read $source/fullchain.pem"
  [[ -r $source/privkey.pem ]] || die "Cannot read $source/privkey.pem"

  if [[ $(public_key_hash cert "$source/fullchain.pem") != "$(public_key_hash key "$source/privkey.pem")" ]]; then
    die "$source/privkey.pem is not the key of the certificate in $source/fullchain.pem"
  fi

  mkdir -p certs

  # Written under a temporary name first, so the web server never sees a
  # certificate without its matching key.
  cp -L "$source/fullchain.pem" certs/fullchain.pem.new
  cp -L "$source/privkey.pem" certs/privkey.pem.new
  chmod 600 certs/privkey.pem.new
  match_owner certs/fullchain.pem.new certs/privkey.pem.new
  mv certs/fullchain.pem.new certs/fullchain.pem
  mv certs/privkey.pem.new certs/privkey.pem

  if [[ $(env_get TLS_CERT_PATH) != "$source" ]]; then
    env_set TLS_CERT_PATH "$source"
  fi

  info "Installed the certificate from $source ($(cert_days_left certs/fullchain.pem) days left)."
}

# Create the private certificate authority and the two certificates that
# authenticate the app server and the proxy server to each other.
function cert_link {
  local dir=certs/internal name config

  mkdir -p "$dir"
  chmod 700 "$dir"

  quiet openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$dir/ca-key.pem" \
    -out "$dir/ca.pem" \
    -subj "/CN=link authority"

  config=$(mktemp)

  for name in origin edge; do
    cat > "$config" << EOF
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = DNS:$name.internal
EOF

    quiet openssl req -new -newkey rsa:2048 -nodes \
      -keyout "$dir/$name-key.pem" \
      -out "$dir/$name.csr" \
      -subj "/CN=$name.internal"

    quiet openssl x509 -req -days 3650 \
      -in "$dir/$name.csr" \
      -CA "$dir/ca.pem" \
      -CAkey "$dir/ca-key.pem" \
      -CAcreateserial \
      -extfile "$config" \
      -out "$dir/$name.pem"

    rm -f "$dir/$name.csr"
  done

  rm -f "$config" "$dir"/*.srl
  chmod 600 "$dir"/*-key.pem

  info "Created the certificates for the link between the two servers, valid for ten years."
}

function reload_web_server {
  local service

  for service in web link; do
    if is_running "$service"; then
      step compose exec -T "$service" openresty -s reload
    fi
  done
}

function cmd_cert {
  local action=${1:-}
  shift || true

  require_config
  require_command openssl

  case "$action" in
    install)
      has_edge || die "The public certificate belongs on the proxy server."
      cert_install "$@"
      reload_web_server
      ;;

    self-signed)
      has_edge || die "The public certificate belongs on the proxy server."
      cert_self_signed
      reload_web_server
      ;;

    link)
      [[ $(role) == app ]] || die "The link certificates are created on the app server."

      if [[ -e certs/internal/ca.pem ]]; then
        warn "This replaces the link certificates. The proxy server keeps working"
        warn "only after it has been given a new bundle (./philomena.sh proxy-bundle)."
        confirm "Replace the link certificates?" || exit 1
      fi

      cert_link
      reload_web_server
      ;;

    *)
      die "Usage: ./philomena.sh cert install [directory] | self-signed | link"
      ;;
  esac
}
