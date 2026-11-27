FROM docker.io/library/node:22.23.5-bookworm-slim@sha256:be979e5523c76fa4d5ca4ebd3099078f220aa47ec39c48ad5b5df9314debd6eb AS build
WORKDIR /src
COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts --no-audit --no-fund
COPY app/ app/
RUN npm run check:app

FROM gcr.io/distroless/cc-debian13:nonroot@sha256:29ee70762214fe8190cea04ef1c0a84a8365879e047ce8f911ae5a5ab2355fa2
WORKDIR /srv
COPY --from=build /usr/local/bin/node /usr/local/bin/node
COPY --from=build /src/app ./app
ENV NODE_ENV=production DB_PATH=/data/desk.sqlite SESSION_KEY_FILE=/run/desk/session.key HOME=/tmp
USER 10001:10001
RUN ["/usr/local/bin/node", "--disable-warning=ExperimentalWarning", "-e", "require('node:sqlite')"]
EXPOSE 8080 9091
HEALTHCHECK --interval=20s --timeout=3s --retries=3 CMD ["/usr/local/bin/node", "-e", "fetch('http://127.0.0.1:8080/healthz',{signal:AbortSignal.timeout(2000)}).then(r=>{if(!r.ok)process.exit(1)}).catch(()=>process.exit(1))"]
ENTRYPOINT ["/usr/local/bin/node", "--disable-warning=ExperimentalWarning"]
CMD ["app/main.mjs"]
