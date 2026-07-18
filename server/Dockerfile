# Build the portal as a static SPA served by nginx.
# Multi-stage: stage 1 (build) has node+npm and produces static files;
# stage 2 (runtime) is small nginx with no node/npm at all.
FROM node:18-alpine AS build
WORKDIR /app
# CRA bakes REACT_APP_* vars into the static bundle at build time. server/.env
# is dockerignored, so pass these as build args instead.
ARG REACT_APP_DEX_BASE_URL
ARG REACT_APP_DEX_CLIENT_ID
ARG REACT_APP_DEX_REDIRECT_URI
ARG REACT_APP_API_BASE_URL
ARG REACT_APP_MOCK_MODE
ENV REACT_APP_DEX_BASE_URL=${REACT_APP_DEX_BASE_URL} \
    REACT_APP_DEX_CLIENT_ID=${REACT_APP_DEX_CLIENT_ID} \
    REACT_APP_DEX_REDIRECT_URI=${REACT_APP_DEX_REDIRECT_URI} \
    REACT_APP_API_BASE_URL=${REACT_APP_API_BASE_URL} \
    REACT_APP_MOCK_MODE=${REACT_APP_MOCK_MODE}
# Copy lockfile + manifest first for layer caching; install is reproducible.
COPY package.json package-lock.json ./
RUN npm ci --legacy-peer-deps
COPY . .
RUN npm run build

FROM nginx:alpine
COPY --from=build /app/build /usr/share/nginx/html
# SPA fallback so client-side routes (e.g. /auth/callback) hit index.html.
# nginx listens on 3000 to match EXPOSE and the compose port mapping.
RUN printf 'server {\n  listen 3000;\n  location / {\n    root /usr/share/nginx/html;\n    try_files $uri /index.html;\n  }\n}\n' > /etc/nginx/conf.d/default.conf
EXPOSE 3000
CMD ["nginx", "-g", "daemon off;"]
