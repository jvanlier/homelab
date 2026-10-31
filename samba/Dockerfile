FROM debian:trixie-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends samba samba-vfs-modules \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /run/samba

COPY smb.conf /etc/samba/smb.conf
RUN testparm -s

CMD ["smbd", "--foreground", "--no-process-group", "--debug-stdout"]
