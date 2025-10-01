# syntax=docker/dockerfile:1

FROM python:3.11-slim AS base

ARG POLLY_GIT_URL=https://github.com/lawlawrd/polly.git
ARG POLLY_GIT_REF=master
ARG NODE_MAJOR=20

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    LANG=C.UTF-8 \
    PRESIDIO_ANALYZER_URL=http://127.0.0.1:5002 \
    PRESIDIO_ANONYMIZER_URL=http://127.0.0.1:5001 \
    PRESIDIO_ANALYZER_PORT=5002 \
    PRESIDIO_ANONYMIZER_PORT=5001 \
    ANALYZER_CONF_FILE=/opt/presidio/analyzer-config.yml \
    NLP_CONF_FILE=/opt/presidio/nlp.yaml \
    RECOGNIZER_REGISTRY_CONF_FILE=/opt/presidio/recognizers.yaml \
    POLLY_GIT_REF=${POLLY_GIT_REF}

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    build-essential \
    ca-certificates \
    curl \
    git \
    gnupg \
    cron \
    util-linux \
    locales \
    tini \
    && echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen \
    && locale-gen \
    && curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && npm install --global npm@10.8.2 \
    && npm config set fund false \
    && npm config set update-notifier false \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt

RUN git clone --depth 1 --branch "${POLLY_GIT_REF}" "${POLLY_GIT_URL}" polly

WORKDIR /opt/polly

# npm ci requires a package-lock; fall back to npm install when missing
RUN if [ -f package-lock.json ]; then npm ci; else npm install; fi \
    && npm run build \
    && npm prune --omit=dev \
    && rm -rf /root/.npm

WORKDIR /opt

RUN pip install --no-cache-dir 'presidio-analyzer[server]' 'presidio-anonymizer[server]' spacy \
    && python -m spacy download en_core_web_lg \
    && python -m spacy download nl_core_news_lg

COPY analyzer-config.yml /opt/presidio/analyzer-config.yml
COPY nlp.yaml /opt/presidio/nlp.yaml
COPY recognizers.yaml /opt/presidio/recognizers.yaml
COPY presidio_analyzer_server.py /opt/presidio/analyzer_server.py
COPY presidio_anonymizer_server.py /opt/presidio/anonymizer_server.py
COPY start.sh /opt/start.sh

RUN mkdir -p /opt/scripts
COPY container/update-polly.sh /opt/scripts/update-polly.sh
COPY container/polly-cron /etc/cron.d/polly
RUN chmod 700 /opt/scripts/update-polly.sh \
    && chmod 644 /etc/cron.d/polly \
    && mkdir -p /var/log \
    && touch /var/log/polly-update.log

RUN sed -i 's/\r$//' /opt/start.sh \
    && chmod +x /opt/start.sh

EXPOSE 8081

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/opt/start.sh"]
