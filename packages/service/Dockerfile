# syntax=docker/dockerfile:1
FROM node:22-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY tsconfig.json ./
COPY src ./src
RUN npm run build

FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production
COPY package.json package-lock.json openapi.json ./
RUN npm ci --omit=dev
COPY --from=build /app/dist ./dist

# Auth tokens live outside the image — see OPEN_AI_SUB_AUTH_DIR in auth.ts.
# Bind-mount only ~/.open-ai-sub-auth (not the whole home dir) to this path.
ENV OPEN_AI_SUB_AUTH_DIR=/data/auth
VOLUME ["/data/auth"]

EXPOSE 8787
CMD ["node", "dist/server.js"]
