FROM node:20-alpine

# openssl for self-signed TLS cert generation
RUN apk add --no-cache curl openssl

WORKDIR /app

COPY package.json ./
RUN npm install --production

COPY server.js ./

EXPOSE 9440

# Health check uses -k to accept self-signed cert
HEALTHCHECK --interval=15s --timeout=5s --start-period=5s --retries=5 \
  CMD curl -skf https://localhost:9440/health || curl -sf http://localhost:9440/health || exit 1

COPY entrypoint.sh /
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
