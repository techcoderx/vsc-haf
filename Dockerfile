# Base image
FROM node:18-slim AS vsc_haf
WORKDIR /app
COPY package*.json ./
RUN npm install
COPY . .
CMD ["npm", "start"]