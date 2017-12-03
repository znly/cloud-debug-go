FROM progrium/busybox

RUN opkg-install wget bash ca-certificates
RUN cat /etc/ssl/certs/*.crt > /etc/ssl/certs/ca-certificates.crt
ADD https://storage.googleapis.com/cloud-debugger/compute-go/go-cloud-debug /go-cloud-debug
RUN chmod 0755 /go-cloud-debug
COPY launch.sh /launch.sh

ENTRYPOINT ["/launch.sh"]
