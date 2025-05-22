#!/bin/bash

clear
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 🔧 INSTALADOR AVANÇADO DO N8N COM SUPORTE A MÚLTIPLAS INSTÂNCIAS E ATUALIZAÇÕES "
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Função para exibir instruções iniciais
show_instructions() {
  echo " 👉 Antes de continuar, siga estas orientações:"
  echo ""
  echo "1️⃣  Configure o domínio no Cloudflare:"
  echo "    - Acesse https://dash.cloudflare.com"
  echo "    - Adicione seu domínio (ex: nortelab.cloud)"
  echo "    - Aponte os DNS do seu domínio para os servidores fornecidos"
  echo ""
  echo "2️⃣  Crie um subdomínio para cada instância do N8N:"
  echo "    - Vá em 'DNS' dentro do domínio"
  echo "    - Adicione registros do tipo A"
  echo "      Nome: flow (principal), flow2, flow3, etc | IP: IP público do seu MikroTik"
  echo ""
  echo "3️⃣  No MikroTik, redirecione as portas:"
  echo "    - Acesse o Winbox ➜ IP ➜ Firewall ➜ NAT"
  echo "    - Adicione 2 regras para cada instância:"
  echo "      a) Porta 80: dst-port=80 ➜ to-address=IP do Ubuntu ➜ to-ports=80"
  echo "      b) Porta 443: dst-port=443 ➜ to-address=IP do Ubuntu ➜ to-ports=443"
  echo ""
  echo "4️⃣  Gere sua chave de API na Cloudflare:"
  echo "    - Vá em 'Perfil' (canto superior direito)"
  echo "    - Clique em 'API Tokens'"
  echo "    - Copie a 'Global API Key'"
  echo ""
}

# Função para instalar dependências básicas
install_dependencies() {
  echo "🔄 Atualizando o sistema..."
  sudo apt update && sudo apt upgrade -y

  echo "🐳 Instalando Docker..."
  curl -fsSL https://get.docker.com -o get-docker.sh
  sudo sh get-docker.sh
  sudo systemctl enable docker
  sudo systemctl start docker

  echo "🌐 Instalando Nginx..."
  sudo apt install -y nginx
  sudo systemctl start nginx
  sudo systemctl enable nginx

  echo "📦 Instalando dependências adicionais..."
  sudo apt install -y snapd curl unzip ufw jq

  echo "🔒 Configurando firewall..."
  sudo ufw allow OpenSSH
  sudo ufw allow 80
  sudo ufw allow 443
  sudo ufw --force enable

  echo "🔄 Iniciando serviços..."
  sudo systemctl enable docker && sudo systemctl start docker
  sudo systemctl enable nginx && sudo systemctl start nginx

  echo "🔐 Instalando Certbot e plugin DNS Cloudflare..."
  sudo snap install core && sudo snap refresh core
  sudo snap install --classic certbot
  sudo ln -sf /snap/bin/certbot /usr/bin/certbot
  sudo snap set certbot trust-plugin-with-root=ok
  sudo snap install certbot-dns-cloudflare
}

# Função para configurar credenciais Cloudflare
setup_cloudflare() {
  echo "☁️ Configurando credenciais Cloudflare..."
  mkdir -p ~/.secrets/certbot
  CLOUDFLARE_FILE=~/.secrets/certbot/cloudflare.ini
  cat <<EOF > $CLOUDFLARE_FILE
dns_cloudflare_email = $CF_EMAIL
dns_cloudflare_api_key = $CF_API_KEY
EOF
  chmod 600 $CLOUDFLARE_FILE
}

# Função para obter certificado SSL
get_ssl_certificate() {
  echo "🔒 Obtendo certificado SSL para $DOMAIN..."
  sudo certbot certonly \
    --dns-cloudflare \
    --dns-cloudflare-credentials $CLOUDFLARE_FILE \
    -d $DOMAIN \
    --agree-tos \
    --no-eff-email \
    --email $LETSENCRYPT_EMAIL
}

# Função para criar configuração do Nginx
create_nginx_config() {
  local domain=$1
  local port=$2
  local instance_name=$3

  echo "🌐 Configurando Nginx para $domain (porta $port)..."
  sudo tee /etc/nginx/sites-available/$domain > /dev/null <<EOF
server {
    listen 80;
    server_name $domain;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $domain;

    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;

    location / {
        proxy_pass http://localhost:$port;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400;
    }
}
EOF

  sudo ln -sf /etc/nginx/sites-available/$domain /etc/nginx/sites-enabled/
  sudo nginx -t && sudo systemctl reload nginx
}

# Função para criar docker-compose.yml para instância principal
create_primary_docker_compose() {
  local port=$1
  local instance_name=$2
  local schema_prefix=$3

  echo "🐳 Criando configuração Docker para instância principal ($instance_name)..."
  cat <<EOF > docker-compose.yml
version: "3.8"
services:
  $instance_name:
    image: n8nio/n8n
    restart: always
    ports:
      - $port:5678
    environment:
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=admin
      - N8N_BASIC_AUTH_PASSWORD=admin
      - WEBHOOK_URL=https://$DOMAIN/
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=n8n
      - DB_POSTGRESDB_USER=n8n
      - DB_POSTGRESDB_PASSWORD=$DB_PASSWORD
      - DB_POSTGRESDB_SCHEMA=$schema_prefix
      - N8N_METRICS=true
      - NODE_ENV=production
      - N8N_HOST=$DOMAIN
      - N8N_PROTOCOL=https
      - N8N_PORT=5678
      - N8N_EDITOR_BASE_URL=https://$DOMAIN/
    volumes:
      - ${instance_name}_data:/home/node/.n8n
    depends_on:
      - postgres

  postgres:
    image: postgres:14
    restart: always
    environment:
      - POSTGRES_USER=n8n
      - POSTGRES_PASSWORD=$DB_PASSWORD
      - POSTGRES_DB=n8n
      - POSTGRES_NON_ROOT_USER=n8n
    volumes:
      - postgres_data:/var/lib/postgresql/data
    ports:
      - 5432:5432

volumes:
  ${instance_name}_data:
  postgres_data:
EOF
}

# Função para criar docker-compose.yml para instância secundária
create_secondary_docker_compose() {
  local port=$1
  local instance_name=$2
  local schema_prefix=$3

  echo "🐳 Criando configuração Docker para instância secundária ($instance_name)..."
  cat <<EOF > docker-compose.yml
version: "3.8"
services:
  $instance_name:
    image: n8nio/n8n
    restart: always
    ports:
      - $port:5678
    environment:
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=admin
      - N8N_BASIC_AUTH_PASSWORD=admin
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
      - N8N_RUNNERS_ENABLED=true
      - N8N_SECURE_COOKIE=false
      - WEBHOOK_URL=https://$DOMAIN/
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=$DB_HOST
      - DB_POSTGRESDB_PORT=$DB_PORT
      - DB_POSTGRESDB_DATABASE=n8n
      - DB_POSTGRESDB_USER=n8n
      - DB_POSTGRESDB_PASSWORD=$DB_PASSWORD
      - DB_POSTGRESDB_SCHEMA=$schema_prefix
      - N8N_METRICS=true
      - NODE_ENV=production
      - N8N_HOST=$DOMAIN
      - N8N_PROTOCOL=https
      - N8N_PORT=5678
      - N8N_EDITOR_BASE_URL=https://$DOMAIN/
    volumes:
      - ${instance_name}_data:/home/node/.n8n

volumes:
  ${instance_name}_data:
EOF
}

# Função para atualizar uma instância existente
update_n8n_instance() {
  local instance_dir=$1
  local backup_dir="${instance_dir}_backup_$(date +%Y%m%d_%H%M%S)"
  
  echo "🔄 Atualizando instância N8N em $instance_dir..."
  
  # Verificar se o diretório existe
  if [ ! -d "$instance_dir" ]; then
    echo "❌ Diretório $instance_dir não encontrado!"
    return 1
  fi
  
  # Criar backup
  echo "📦 Criando backup em $backup_dir..."
  cp -r "$instance_dir" "$backup_dir"
  
  # Parar containers
  echo "🛑 Parando containers..."
  cd "$instance_dir"
  docker compose down
  
  # Obter a versão atual da imagem
  local current_image=$(grep -o 'n8nio/n8n:[^ ]*' docker-compose.yml || echo "n8nio/n8n:latest")
  if [ "$current_image" == "n8nio/n8n" ]; then
    current_image="n8nio/n8n:latest"
  fi
  
  # Puxar a nova imagem
  echo "🔄 Atualizando para a versão mais recente do N8N..."
  docker pull n8nio/n8n:latest
  
  # Atualizar a imagem no docker-compose.yml
  if [ "$current_image" != "n8nio/n8n:latest" ]; then
    echo "📝 Atualizando referência da imagem no docker-compose.yml..."
    sed -i "s|$current_image|n8nio/n8n:latest|g" docker-compose.yml
  fi
  
  # Iniciar containers novamente
  echo "🚀 Iniciando containers com a nova versão..."
  docker compose up -d
  
  echo "✅ Atualização concluída com sucesso!"
  echo "📌 Backup disponível em: $backup_dir"
}

# Menu principal
show_menu() {
  clear
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " 🔧 INSTALADOR AVANÇADO DO N8N COM SUPORTE A MÚLTIPLAS INSTÂNCIAS E ATUALIZAÇÕES "
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo " Escolha uma opção:"
  echo ""
  echo " 1️⃣  Instalar instância principal do N8N (com banco de dados PostgreSQL)"
  echo " 2️⃣  Adicionar instância secundária do N8N (usando banco existente)"
  echo " 3️⃣  Atualizar uma instância existente do N8N"
  echo " 4️⃣  Exibir instruções de pré-requisitos"
  echo " 0️⃣  Sair"
  echo ""
  read -p "Digite sua escolha [0-4]: " choice
  
  case $choice in
    1) install_primary_instance ;;
    2) install_secondary_instance ;;
    3) update_instance ;;
    4) show_instructions; read -p "Pressione Enter para voltar ao menu..." && show_menu ;;
    0) exit 0 ;;
    *) echo "Opção inválida!"; sleep 2; show_menu ;;
  esac
}

# Função para instalar instância principal
install_primary_instance() {
  clear
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " 🔧 INSTALAÇÃO DA INSTÂNCIA PRINCIPAL DO N8N "
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  show_instructions
  read -p "✅ Pressione Enter para iniciar a instalação da instância principal..."
  clear
  
  # Solicitar dados
  read -p "Digite o subdomínio para a instância principal (ex: flow.nortelab.cloud): " DOMAIN
  read -p "Digite o e-mail associado à conta da Cloudflare: " CF_EMAIL
  read -p "Cole a chave Global API da Cloudflare: " CF_API_KEY
  read -p "Digite o e-mail de contato para o Let's Encrypt (Certbot): " LETSENCRYPT_EMAIL
  read -p "Digite uma senha para o banco de dados PostgreSQL: " DB_PASSWORD
  read -p "Digite um nome para esta instância [n8n-primary]: " INSTANCE_NAME
  INSTANCE_NAME=${INSTANCE_NAME:-n8n-primary}
  read -p "Digite o prefixo do schema para esta instância [primary]: " SCHEMA_PREFIX
  SCHEMA_PREFIX=${SCHEMA_PREFIX:-primary}
  read -p "Digite a porta para esta instância [5678]: " INSTANCE_PORT
  INSTANCE_PORT=${INSTANCE_PORT:-5678}
  
  # Instalar dependências
  install_dependencies
  
  # Configurar Cloudflare
  setup_cloudflare
  
  # Obter certificado SSL
  get_ssl_certificate
  
  # Criar pasta do projeto N8N
  echo "📁 Criando pasta para a instância $INSTANCE_NAME..."
  mkdir -p ~/n8n/$INSTANCE_NAME && cd ~/n8n/$INSTANCE_NAME
  
  # Criar docker-compose.yml
  create_primary_docker_compose $INSTANCE_PORT $INSTANCE_NAME $SCHEMA_PREFIX
  
  # Subir container
  echo "🚀 Iniciando containers..."
  docker compose up -d
  
  # Configurar NGINX
  create_nginx_config $DOMAIN $INSTANCE_PORT $INSTANCE_NAME
  
  # Finalização
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "✅ Instância principal do N8N instalada com sucesso e acessível via HTTPS!"
  echo "🌐 URL: https://$DOMAIN"
  echo "🔐 Usuário: admin | Senha: admin"
  echo "🗄️ Banco de dados PostgreSQL configurado e persistente"
  echo "📌 Recomenda-se alterar a senha após o primeiro login."
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  
  read -p "Pressione Enter para voltar ao menu principal..."
  show_menu
}

# Função para instalar instância secundária
install_secondary_instance() {
  clear
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " 🔧 INSTALAÇÃO DE INSTÂNCIA SECUNDÁRIA DO N8N "
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  show_instructions
  read -p "✅ Pressione Enter para iniciar a instalação da instância secundária..."
  clear
  
  # Solicitar dados
  read -p "Digite o subdomínio para esta instância (ex: flow2.nortelab.cloud): " DOMAIN
  read -p "Digite o e-mail associado à conta da Cloudflare: " CF_EMAIL
  read -p "Cole a chave Global API da Cloudflare: " CF_API_KEY
  read -p "Digite o e-mail de contato para o Let's Encrypt (Certbot): " LETSENCRYPT_EMAIL
  read -p "Digite o endereço IP ou hostname do banco de dados PostgreSQL: " DB_HOST
  read -p "Digite a porta do banco de dados PostgreSQL [5432]: " DB_PORT
  DB_PORT=${DB_PORT:-5432}
  read -p "Digite a senha do banco de dados PostgreSQL: " DB_PASSWORD
  read -p "Digite um nome para esta instância [n8n-secondary]: " INSTANCE_NAME
  INSTANCE_NAME=${INSTANCE_NAME:-n8n-secondary}
  read -p "Digite o prefixo do schema para esta instância [secondary]: " SCHEMA_PREFIX
  SCHEMA_PREFIX=${SCHEMA_PREFIX:-secondary}
  read -p "Digite a porta para esta instância [5679]: " INSTANCE_PORT
  INSTANCE_PORT=${INSTANCE_PORT:-5679}
  
  # Verificar se as dependências já estão instaladas
  if ! command -v docker &> /dev/null || ! command -v nginx &> /dev/null; then
    install_dependencies
  fi
  
  # Configurar Cloudflare
  setup_cloudflare
  
  # Obter certificado SSL
  get_ssl_certificate
  
  # Criar pasta do projeto N8N
  echo "📁 Criando pasta para a instância $INSTANCE_NAME..."
  mkdir -p ~/n8n/$INSTANCE_NAME && cd ~/n8n/$INSTANCE_NAME
  
  # Criar docker-compose.yml
  create_secondary_docker_compose $INSTANCE_PORT $INSTANCE_NAME $SCHEMA_PREFIX
  
  # Subir container
  echo "🚀 Iniciando containers..."
  docker compose up -d
  
  # Configurar NGINX
  create_nginx_config $DOMAIN $INSTANCE_PORT $INSTANCE_NAME
  
  # Finalização
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "✅ Instância secundária do N8N instalada com sucesso e acessível via HTTPS!"
  echo "🌐 URL: https://$DOMAIN"
  echo "🔐 Usuário: admin | Senha: admin"
  echo "🗄️ Conectado ao banco de dados PostgreSQL existente"
  echo "📌 Recomenda-se alterar a senha após o primeiro login."
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  
  read -p "Pressione Enter para voltar ao menu principal..."
  show_menu
}

# Função para atualizar uma instância existente
update_instance() {
  clear
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " 🔄 ATUALIZAÇÃO DE INSTÂNCIA DO N8N "
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  
  # Listar instâncias disponíveis
  echo "📋 Instâncias disponíveis:"
  echo ""
  
  if [ ! -d "~/n8n" ] || [ -z "$(ls -A ~/n8n 2>/dev/null)" ]; then
    echo "❌ Nenhuma instância encontrada!"
    read -p "Pressione Enter para voltar ao menu principal..."
    show_menu
    return
  fi
  
  # Listar diretórios dentro de ~/n8n
  ls -1 ~/n8n | nl
  echo ""
  read -p "Digite o número da instância que deseja atualizar: " instance_num
  
  # Obter o nome da instância selecionada
  instance_name=$(ls -1 ~/n8n | sed -n "${instance_num}p")
  
  if [ -z "$instance_name" ]; then
    echo "❌ Seleção inválida!"
    read -p "Pressione Enter para tentar novamente..."
    update_instance
    return
  fi
  
  # Confirmar atualização
  echo ""
  echo "🔄 Você está prestes a atualizar a instância: $instance_name"
  read -p "Confirmar atualização? (s/n): " confirm
  
  if [ "$confirm" != "s" ] && [ "$confirm" != "S" ]; then
    echo "❌ Atualização cancelada!"
    read -p "Pressione Enter para voltar ao menu principal..."
    show_menu
    return
  fi
  
  # Executar atualização
  update_n8n_instance "~/n8n/$instance_name"
  
  read -p "Pressione Enter para voltar ao menu principal..."
  show_menu
}

# Iniciar o script
show_menu