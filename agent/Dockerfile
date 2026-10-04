# The platform agent: the loop, the MCP server and the tools check.sh needs.
# The repository itself is not copied in. Compose mounts it, read-only except
# for services/.
FROM python:3.12-slim

ARG CONFTEST_VERSION=0.71.0
ARG TARGETARCH

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates \
 && case "${TARGETARCH}" in arm64) arch=arm64 ;; *) arch=x86_64 ;; esac \
 && curl -fsSL "https://github.com/open-policy-agent/conftest/releases/download/v${CONFTEST_VERSION}/conftest_${CONFTEST_VERSION}_Linux_${arch}.tar.gz" \
    | tar -xz -C /usr/local/bin conftest \
 && apt-get purge -y curl && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*

COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PLATFORM_REPO=/repo \
    AGENT_HOST=0.0.0.0 \
    AGENT_PORT=8765

RUN useradd --create-home agent
USER agent
WORKDIR /repo

EXPOSE 8765
CMD ["python", "-m", "agent.server"]
