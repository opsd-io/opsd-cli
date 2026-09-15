FROM ruby:3.4.10-alpine

RUN apk add --no-cache bash git

WORKDIR /app

COPY . /app

ENV OPSD_APP_ROOT=/app
ENV OPSD_WORKSPACE_ROOT=/workspace

ENTRYPOINT ["ruby", "--disable-gems", "-I/app/lib", "-ropsd/cli", "-e", "OPSd::CLI.run(ARGV)", "--"]
