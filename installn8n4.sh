#!/bin/bash

clear
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 🔧 INSTALADOR AUTOMÁTICO DO N8N COM SSL VIA CLOUDFLARE "
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo " 👉 Antes de continuar, siga estas orientações:"
echo ""
echo "1️⃣  Configure o domínio no Cloudflare:"
echo "    - Acesse https://dash.cloudflare.com"
echo "    - Adicione seu domínio (ex: nortelab.cloud)"
echo "    - Aponte os DNS do seu domínio para os servidores fornecidos"
echo ""
echo "2️⃣  Crie um subdomínio:"
echo "    - Vá em 'DNS' dentro do domínio"
echo "    - Adicione um registro do tipo A"
echo "      Nome: flow | IP: IP público do seu MikroTik"
echo ""
echo "3️⃣  No MikroTik, redirecione as portas:"
echo "    - Acesse o Winbox ➜ IP ➜ Firewall ➜ NAT"
echo "    - Adicione 2 regras:"
echo "      a) Porta 80: dst-port=80 ➜ to-address=IP do Ubuntu ➜ to-ports=80"
echo "      b) Porta 443: dst-port=443 ➜ to-address=IP do Ubuntu ➜ to-ports=443"
echo ""
echo "4️⃣  Gere sua chave de API na Cloudflare:"
echo "    - Vá em 'Perfil' (canto superior direito)"
echo "    - Clique em 'API Tokens'"
echo "    - Copie a 'Global API Key'"
echo ""
read -p "✅ Pressione Enter para iniciar a instalação automática..."
clear

# Solicitar dados
read -p "Digite o subdomínio (ex: flow.nortelab.cloud): " DOMAIN
read -p "Digite o e-mail associado à conta da Cloudflare: " CF_EMAIL
read -p "Cole a chave Global API da Cloudflare: " CF_API_KEY
read -p "Digite o e-mail de contato para o Let's Encrypt (Certbot): " LETSENCRYPT_EMAIL

# Atualizar sistema
sudo apt update && sudo apt upgrade -y

# Instalando Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo systemctl enable docker
sudo systemctl start Docker

# Instalando Ngnix
sudo apt install -y nginx
sudo systemctl start nginx
sudo systemctl enable nginx

#Instalando dependências
sudo apt install -y snapd curl unzip ufw

# Configurar firewall
sudo ufw allow OpenSSH
sudo ufw allow 80
sudo ufw allow 443
sudo ufw --force enable

# Iniciar e habilitar serviços
sudo systemctl enable docker && sudo systemctl start docker
sudo systemctl enable nginx && sudo systemctl start nginx

# Instalar Certbot e plugin DNS Cloudflare
sudo snap install core && sudo snap refresh core
sudo snap install --classic certbot
sudo ln -s /snap/bin/certbot /usr/bin/certbot
sudo snap set certbot trust-plugin-with-root=ok
sudo snap install certbot-dns-cloudflare

# Criar credenciais Cloudflare
mkdir -p ~/.secrets/certbot
CLOUDFLARE_FILE=~/.secrets/certbot/cloudflare.ini
cat <<EOF > $CLOUDFLARE_FILE
dns_cloudflare_email = $CF_EMAIL
dns_cloudflare_api_key = $CF_API_KEY
EOF
chmod 600 $CLOUDFLARE_FILE

# Obter certificado SSL
sudo certbot certonly \
  --dns-cloudflare \
  --dns-cloudflare-credentials $CLOUDFLARE_FILE \
  -d $DOMAIN \
  --agree-tos \
  --no-eff-email \
  --email $LETSENCRYPT_EMAIL

# Criar pasta do projeto N8N
mkdir -p ~/n8n && cd ~/n8n

# Criar docker-compose.yml
cat <<EOF > docker-compose.yml
version: "3.8"
services:
  n8n:
    image: n8nio/n8n
    restart: always
    ports:
      - 5678:5678
    environment:
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=admin
      - N8N_BASIC_AUTH_PASSWORD=admin
      - WEBHOOK_URL=https://$DOMAIN/
    volumes:
      - n8n_data:/home/node/.n8n

volumes:
  n8n_data:
EOF

# Subir container
docker compose up -d

# Configurar NGINX
sudo tee /etc/nginx/sites-available/$DOMAIN > /dev/null <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    location / {
        proxy_pass http://localhost:5678;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

# Ativar site e reiniciar nginx
sudo ln -s /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl restart nginx

# Finalização
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ N8N instalado com sucesso e acessível via HTTPS!"
echo "🌐 URL: https://$DOMAIN"
echo "🔐 Usuário: admin | Senha: admin"
echo "📌 Recomenda-se alterar a senha após o primeiro login."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
