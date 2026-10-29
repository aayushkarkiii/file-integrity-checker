# ==============================================================================
# Dockerfile for File Integrity Checker (FIM)
# Runs FIM in a secure, containerized environment with watched paths mounted read-only.
# ==============================================================================

FROM alpine:3.20

# Install runtime utilities required for POSIX file attribute inspection and hashing
RUN apk add --no-cache \
    bash \
    coreutils \
    findutils \
    gawk

WORKDIR /app

# Install FIM binary and default config
COPY bin/fim.sh /usr/local/bin/fim
COPY conf/fim.conf /etc/fim/fim.conf

RUN chmod +x /usr/local/bin/fim && \
    mkdir -p /var/lib/fim /var/log /watched

# Default environment variables
ENV WATCH_DIRS="/watched" \
    BASELINE_FILE="/var/lib/fim/baseline.db"

# Expose volume mount point for persisting baseline database across container runs
VOLUME ["/var/lib/fim"]

ENTRYPOINT ["/usr/local/bin/fim"]
CMD ["check"]
