FROM node:20-alpine AS base
ENV PNPM_HOME="/pnpm"
ENV PATH="$PNPM_HOME:$PATH"
RUN corepack enable
RUN apk --no-cache add postgresql16-client
RUN adduser --disabled-password --gecos '' haf_admin
RUN adduser --disabled-password --gecos '' vsc_owner
COPY . /app
COPY ./scripts /app/scripts
WORKDIR /app
RUN chown -R vsc_owner:vsc_owner /app

FROM base AS prod-deps
USER vsc_owner
RUN --mount=type=cache,id=pnpm,target=/pnpm/store pnpm install --prod --frozen-lockfile

FROM base AS build
USER vsc_owner
RUN --mount=type=cache,id=pnpm,target=/pnpm/store pnpm install --frozen-lockfile

ARG API_SCHEMA_NAME=vsc_api
ARG SCHEMA_NAME=vsc_app
ARG APP_CONTEXT=vsc_app
RUN pnpm run compile --schema=${SCHEMA_NAME} --api-schema=${API_SCHEMA_NAME} --app-context=${APP_CONTEXT} --docker

FROM base

USER vsc_owner
COPY --from=prod-deps /app/node_modules /app/node_modules
COPY --from=build /app/dist /app/dist
COPY --from=build /app/scripts /app/scripts

RUN chmod +x /app/scripts/*.sh

USER root
ENTRYPOINT ["/app/scripts/docker_entrypoint.sh"]