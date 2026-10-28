FROM mcr.microsoft.com/playwright:v1.49.1-noble
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev
COPY server.js ./
ENV PORT=3000
EXPOSE 3000
USER pwuser
CMD ["node", "server.js"]
