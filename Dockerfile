FROM progrium/busybox

RUN opkg-install wget bash ca-certificates
RUN cat /etc/ssl/certs/*.crt > /etc/ssl/certs/ca-certificates.crt
COPY cdbg /cdbg

ENV GCE_METADATA_HOST localhost:7900
ENTRYPOINT ["/cdbg/launch_debug_agent.sh"]
