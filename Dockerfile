# Base Node.js image
FROM node:20-alpine

# Set working directory
WORKDIR /app

# Create directory structure
RUN mkdir -p common echo-service

# Copy package.json files first (for layer caching)
COPY services/common/package.json common/
COPY services/echo-service/package.json echo-service/

# Install common dependencies
WORKDIR /app/common
RUN npm install --omit=dev

# Install echo service dependencies
WORKDIR /app/echo-service
RUN npm install --omit=dev

# Copy source files
WORKDIR /app
COPY services/common/ common/
COPY services/echo-service/ echo-service/

# Set working directory to echo-service for startup
WORKDIR /app/echo-service

EXPOSE 3000

CMD ["node", "server.js"]
