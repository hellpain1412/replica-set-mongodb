# Base: official Mongo

ARG MONGO_VER=${MONGO_VER:-8.0}
FROM mongo:${MONGO_VER}

# Install numactl (Debian-based images). If Alpine, switch to apk add numactl
USER root
RUN apt-get update && apt-get install -y --no-install-recommends numactl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Luôn chạy script này bằng root (service sẽ set user: root)
RUN install -d -m 700 -o 999 -g 999 /mongo/keyfile /mongo/ssl

USER 999:999

COPY --chown=999:999 --chmod=u+x,g+x entrypoint-numa.sh /usr/local/bin/entrypoint-numa.sh
# RUN chmod +x /usr/local/bin/entrypoint-numa.sh


# Switch back to mongodb user at runtime via compose (user: "999:999")
ENTRYPOINT ["/usr/local/bin/entrypoint-numa.sh"]
