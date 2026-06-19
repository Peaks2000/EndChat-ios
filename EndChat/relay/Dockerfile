FROM node:22-alpine
WORKDIR /app
COPY server.mjs ./server.mjs
ENV PORT=8080 DATA_DIR=/data
VOLUME ["/data"]
EXPOSE 3667
CMD ["node", "server.mjs"]
