# Chisel server with nginx front-end for Cloud Run
# nginx on 8080 splits: WebSocket → chisel, HTTP → reverse tunnel

FROM alpine:3.18

# Install nginx and supervisor
RUN apk add --no-cache nginx supervisor curl

# Download chisel
ARG CHISEL_VERSION=1.9.1
RUN curl -fsSL "https://github.com/jpillora/chisel/releases/download/v${CHISEL_VERSION}/chisel_${CHISEL_VERSION}_linux_amd64.gz" \
    -o /tmp/chisel.gz \
    && gunzip /tmp/chisel.gz \
    && chmod +x /tmp/chisel \
    && mv /tmp/chisel /usr/local/bin/chisel

# nginx config: route WebSocket to chisel, HTTP to reverse tunnel
RUN mkdir -p /run/nginx /var/www/static
COPY nginx.conf /etc/nginx/nginx.conf
COPY static/ /var/www/static/

# Supervisor config to run both nginx and chisel
COPY supervisord.conf /etc/supervisord.conf

# Startup script that sets auth from environment
COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 8080

CMD ["/start.sh"]
