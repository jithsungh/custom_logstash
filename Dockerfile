# Dockerfile for building Logstash with modified logstash-output-elasticsearch plugin
# Based on opensearchproject/logstash-oss-with-opensearch-output-plugin:8.4.0

ARG LOGSTASH_VERSION=8.4.0
FROM opensearchproject/logstash-oss-with-opensearch-output-plugin:${LOGSTASH_VERSION}

USER root

# Install build dependencies (including dos2unix for line ending conversion)
RUN apt-get update && \
    apt-get install -y gcc make ruby-dev dos2unix && \
    rm -rf /var/lib/apt/lists/*

USER logstash

# Remove existing elasticsearch output plugin
RUN /usr/share/logstash/bin/logstash-plugin remove logstash-output-elasticsearch || true

# Copy the modified plugin source
COPY --chown=logstash:logstash . /tmp/logstash-output-elasticsearch/

WORKDIR /tmp/logstash-output-elasticsearch

# Convert Windows line endings to Unix (CRLF -> LF)
USER root
RUN find /tmp/logstash-output-elasticsearch -type f \( -name "*.rb" -o -name "*.gemspec" \) -exec dos2unix {} \;

# Build the gem using system gem (since we installed ruby-dev)
RUN gem build logstash-output-elasticsearch.gemspec
USER logstash

# Install the built gem using logstash-plugin
RUN /usr/share/logstash/bin/logstash-plugin install --no-verify /tmp/logstash-output-elasticsearch/logstash-output-elasticsearch-*.gem

# Clean up
RUN rm -rf /tmp/logstash-output-elasticsearch

WORKDIR /usr/share/logstash

# Verify plugin installation
RUN /usr/share/logstash/bin/logstash-plugin list | grep logstash-output-elasticsearch

USER logstash
