# Serves the pre-built static dist/ (HTML + assets + fonts) with nginx.
# Build dist/ first with ./build.sh, then `fly deploy`.
FROM nginx:1.27-alpine

COPY dist /usr/share/nginx/html
COPY deploy/nginx.conf /etc/nginx/conf.d/default.conf

# Serve the scorecard at the site root as well as /scorecard.html
RUN cp /usr/share/nginx/html/scorecard.html /usr/share/nginx/html/index.html

EXPOSE 80
