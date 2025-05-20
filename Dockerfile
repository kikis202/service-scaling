FROM node:20-alpine AS base
WORKDIR /app

RUN mkdir -p common
COPY services/common/package.json common/

WORKDIR /app/common
RUN npm install --omit=dev

COPY services/common/ ./

# ---- Echo Service ----
FROM base AS echo-service
WORKDIR /app

RUN mkdir -p echo-service
COPY services/echo-service/package.json echo-service/

WORKDIR /app/echo-service
RUN npm install --omit=dev

COPY services/echo-service/ ./

EXPOSE 3000
CMD ["node", "server.js"]

# ---- CPU Service ----
FROM base AS cpu-service
WORKDIR /app

RUN mkdir -p cpu-service
COPY services/cpu-service/package.json cpu-service/

WORKDIR /app/cpu-service
RUN npm install --omit=dev

COPY services/cpu-service/ ./

EXPOSE 3000
CMD ["node", "server.js"]

# ---- IO Service ----
FROM base AS io-service
WORKDIR /app

RUN mkdir -p io-service
COPY services/io-service/package.json io-service/

WORKDIR /app/io-service
RUN npm install --omit=dev

COPY services/io-service/ ./

EXPOSE 3000
CMD ["node", "server.js"]

# Template for adding new services:
#
# ---- New Service ----
# FROM base AS new-service
# WORKDIR /app
# RUN mkdir -p new-service
# COPY services/new-service/package.json new-service/
# WORKDIR /app/new-service
# RUN npm install --omit=dev
# COPY services/new-service/ ./
# EXPOSE 3000
# CMD ["node", "server.js"]

# docker build -t new-service:v1 --target new-service -f Dockerfile .
