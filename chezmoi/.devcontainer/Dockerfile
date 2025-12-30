FROM jdxcode/mise AS mise
FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

COPY --from=mise /usr/local/bin/mise /usr/local/bin/

# Make mise available to ALL shells, including non-interactive
ENV PATH="/usr/local/bin:${PATH}"

# make sure mise is activated in both zsh and bash. Might be overridden by a user's dotfiles.
RUN echo 'eval "$(mise activate bash)"' >> /home/vscode/.bashrc && \
    echo 'eval "$(mise activate zsh)"' >> /home/vscode/.zshrc
