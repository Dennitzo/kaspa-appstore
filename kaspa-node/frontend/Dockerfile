FROM nginx:1.27.4-alpine

RUN apk add --no-cache wget

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html styles.css dashboard.js kaspa_icon.svg /usr/share/nginx/html/

EXPOSE 19112

CMD ["nginx", "-g", "daemon off;"]
