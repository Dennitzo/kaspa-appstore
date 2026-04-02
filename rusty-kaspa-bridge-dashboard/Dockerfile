FROM nginx:1.27.4-alpine

COPY static/index.html /usr/share/nginx/html/index.html
COPY static/kaspa_icon.svg /usr/share/nginx/html/kaspa_icon.svg
COPY static/kaspa_icon.png /usr/share/nginx/html/kaspa_icon.png
COPY static/favicon.png /usr/share/nginx/html/favicon.png
COPY static/favicon.ico /usr/share/nginx/html/favicon.ico
COPY static/assets /usr/share/nginx/html/static/assets
COPY static/css /usr/share/nginx/html/static/css
COPY static/js /usr/share/nginx/html/static/js
COPY nginx.dashboard.conf /etc/nginx/conf.d/default.conf

EXPOSE 80
