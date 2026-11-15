# Builds the Go application into a static binary on a distroless base.
#
# It matches deploy/deployment.yaml: the server listens on port 3000 (the PORT
# variable), runs as the non-root user 1000, and needs no writable filesystem.
FROM golang:1.27.3-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/app .

FROM gcr.io/distroless/static-debian13:nonroot
COPY --from=build /out/app /app
EXPOSE 3000
USER 1000
ENTRYPOINT ["/app"]
