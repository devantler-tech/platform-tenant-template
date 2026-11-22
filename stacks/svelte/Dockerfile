# Builds the SvelteKit application with adapter-node and runs it on Node.
#
# It matches deploy/deployment.yaml: the server listens on port 3000 (the PORT
# variable), runs as the non-root `node` user (UID 1000), and writes only to /tmp.
# The Node major matches .node-version; bump them together. Both stages pin the
# image by digest, so Dependabot proposes each rebuilt image as a reviewed update.
FROM node:26-alpine@sha256:6bd9ab43c0ec0190ca7b2d193906cb8b7edf6e7f4afa43ddeccd6452710bffb5 AS build
WORKDIR /app
COPY package.json package-lock.json .npmrc ./
RUN npm ci
COPY . .
RUN npm run build && npm prune --omit=dev

FROM node:26-alpine@sha256:6bd9ab43c0ec0190ca7b2d193906cb8b7edf6e7f4afa43ddeccd6452710bffb5
WORKDIR /app
COPY --from=build /app/build ./build
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/package.json ./
ENV NODE_ENV=production
ENV PORT=3000
EXPOSE 3000
USER 1000
CMD ["node", "build/index.js"]
