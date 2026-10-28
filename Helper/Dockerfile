FROM alpine:3.22 AS build
RUN apk add --no-cache build-base linux-headers
COPY Backend /src
RUN cc -std=gnu17 -O2 -static /src/main.c -lpthread -lm -o /outer-firehose-helper
FROM scratch
COPY --from=build /outer-firehose-helper /outer-firehose-helper
