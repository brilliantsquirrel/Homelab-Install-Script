FROM nginx:alpine

# Install apache2-utils for htpasswd
RUN apk add --no-cache apache2-utils openssl

# Copy nginx configuration
COPY nginx.conf /etc/nginx/nginx.conf

# Create directories for SSL certificates and auth
RUN mkdir -p /etc/nginx/certs /etc/nginx/auth

# Generate self-signed certificate (can be replaced with real certs)
RUN openssl req -x509 -newkey rsa:4096 -nodes \
    -out /etc/nginx/certs/cert.pem \
    -keyout /etc/nginx/certs/key.pem \
    -days 365 \
    -subj "/C=US/ST=State/L=City/O=Homelab/CN=homelab.local"

# Create .htpasswd with placeholder (will be replaced at runtime)
# Do NOT set a default password - credentials must be provided
RUN touch /etc/nginx/auth/.htpasswd && \
    chmod 600 /etc/nginx/auth/.htpasswd

# Set proper permissions on certificates
RUN chmod 644 /etc/nginx/certs/*

EXPOSE 80 443

CMD ["nginx", "-g", "daemon off;"]
