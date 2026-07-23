FROM mcr.microsoft.com/devcontainers/base:debian

# Install Homebrew dependencies.
RUN apt-get update && apt-get install -y \
    build-essential \
    procps \
    curl \
    file \
    git \
    && rm -rf /var/lib/apt/lists/*

# Install Homebrew as non-root.
USER vscode
RUN /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Add Homebrew to PATH for the remainder of the build.
ENV PATH="/home/linuxbrew/.linuxbrew/bin:${PATH}"

# Install Gleam using Homebrew.
RUN brew install gleam

# If later steps require root, switch back to root.
# USER root