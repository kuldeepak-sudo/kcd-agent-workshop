# Build the Acme resource API (Go) — the "downstream API" in the RFC 8693 story.
FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /acme-resource-api .

FROM alpine:3.20
RUN apk add --no-cache ca-certificates
COPY --from=build /acme-resource-api /acme-resource-api
EXPOSE 8181
ENTRYPOINT ["/acme-resource-api"]
