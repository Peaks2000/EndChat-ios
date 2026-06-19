# EndChat self-hosted relay

The relay stores only opaque end-to-end-encrypted packets. LAN messaging does not depend on it.

1. Copy `.env.example` to `.env` and set a long random token.
2. Run `docker compose up -d --build`.
3. Put an HTTPS reverse proxy (Caddy, nginx, or equivalent) in front of `127.0.0.1:8080`.
4. Turn off **LAN Only**, enter the resulting HTTPS domain or IP (with an optional port) under **Custom Server**, enter the token, and tap **Test Custom Server**.

The iOS client requires trusted HTTPS. A raw IP works only when its TLS certificate is valid for that IP and trusted by the phone; using a domain with an automatic certificate is usually easier.

`GET /health` is unauthenticated for monitoring. Queued packets expire after seven days and persist in the Docker volume.
