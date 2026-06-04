FROM golang:1.25-alpine as builder

# Creates an app directory to hold your app’s source code
WORKDIR /app

# Copies everything from your root directory into /app
COPY . .

# Installs Go dependencies
RUN go mod download

# Builds your app with optional configuration
RUN go build -o /app/archmirrorlist-proxy

# Production
FROM alpine:latest as production

# Bundle app source
WORKDIR /app
COPY --from=builder /app/* /app/

RUN adduser -D nonroot
USER nonroot

ENTRYPOINT [ "/app/archmirrorlist-proxy" ]
