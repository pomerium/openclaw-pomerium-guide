FROM node:24-slim

# Install git, openssh-server, iproute2 (for ip command), jq, and Docker CLI
RUN apt-get update && \
  apt-get install -y git openssh-server iproute2 jq ca-certificates curl sudo && \
  install -m 0755 -d /etc/apt/keyrings && \
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc && \
  chmod a+r /etc/apt/keyrings/docker.asc && \
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list && \
  apt-get update && \
  apt-get install -y docker-ce-cli && \
  rm -rf /var/lib/apt/lists/*

# Create claw user with home directory at /claw
RUN useradd -m -d /claw -s /bin/bash claw && \
  mkdir -p /claw/workspace && \
  chown -R claw:claw /claw

# Configure SSH
RUN mkdir -p /var/run/sshd && \
  mkdir -p /var/lib/pomerium && \
  sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config && \
  echo "TrustedUserCAKeys /var/lib/pomerium/pomerium_user_ca_key.pub" >> /etc/ssh/sshd_config

# Install openclaw
ARG OPENCLAW_VERSION=latest
RUN npm install -g openclaw@${OPENCLAW_VERSION}

WORKDIR /claw

# Copy and set up entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22

CMD ["/entrypoint.sh"]
