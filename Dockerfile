# Base image
FROM node:18-slim AS vsc_haf
WORKDIR /app
COPY package*.json ./
RUN npm install
COPY . .

# Sync
FROM node:18-slim AS vsc_haf_sync
WORKDIR /app
COPY --from=vsc_haf /app ./
CMD ["npm", "start"]

# Server
FROM node:18-slim AS vsc_haf_server
WORKDIR /app
COPY --from=vsc_haf /app ./
ENV VSC_HAF_HTTP_PORT=3010
EXPOSE ${VSC_HAF_HTTP_PORT}
CMD ["npm", "run", "server"]