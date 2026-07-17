# Build the portal as a static SPA served by nginx.
# Multi-stage: stage 1 (build) has node+npm and produces static files;
# stage 2 (runtime) is small nginx with no node/npm at all.
FROM node:18-alpine AS build
WORKDIR /app
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
