FROM node:22-bookworm-slim

WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY src ./src
RUN mkdir -p /var/lib/mipopup-relay && chown -R node:node /var/lib/mipopup-relay

ENV NODE_ENV=production
EXPOSE 8787
USER node
CMD ["node", "src/main.js"]
