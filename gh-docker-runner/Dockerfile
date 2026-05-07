FROM ghcr.io/actions/actions-runner:latest

USER root

COPY start.sh /start.sh
RUN chmod +x /start.sh

USER runner

ENTRYPOINT ["/start.sh"]
