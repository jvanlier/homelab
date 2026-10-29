FROM caddy:2.10.2-builder AS builder

# v2.0.3 uses a Go module path without /v2, so pin its commit instead of the tag.
RUN xcaddy build --with github.com/caddy-dns/transip@9b8f83754ff79a735a114dba4a4d38b7f54a7b76

FROM caddy:2.10.2

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
