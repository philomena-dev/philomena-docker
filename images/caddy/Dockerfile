# Caddy with the modules the public-facing web server and the server link
# need, built on the server by `./philomena.sh setup` and `update`:
#
#   cache-handler   keeps the files of the CDN domain on local disk
#   caddy-s3-proxy  fetches uploaded files from object storage, with one
#                   signed request each
#   caddy-l4        carries the scraper's connections over the server link,
#                   which are plain TCP rather than HTTP

FROM caddy:2.11.7-builder-alpine AS builder

RUN xcaddy build \
    --with github.com/Meow/cache-handler@v1.2.0 \
    --with github.com/Meow/caddy-s3-proxy@1.0.0 \
    --with github.com/mholt/caddy-l4@v0.1.2

FROM caddy:2.11.7-alpine

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
