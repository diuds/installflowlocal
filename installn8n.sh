#!/bin/bash

set -e

# Função para verificar e instalar PostgreSQL local
install_postgres() {
  if ! command -v psql >/dev/null 2>&1; then
    echo "PostgreSQL não encontrado, instalando..."
    sudo apt update
    sudo apt install -y postgresql postgresql-contrib
    sudo systemctl enable postgresql
    sudo systemctl start postgresql
  else
    echo "PostgreSQL já instalado."
  fi
}

# Função para criar banco e usuário PostgreSQL
create_pg_db_user() {
  echo "Digite o nome do banco PostgreSQL para esta instância:"
  read pg_db
  echo "Digite o nome do usuário PostgreSQL para esta instância:"
  read pg_user
  echo "Digite a senha para o usuário PostgreSQL '$pg_user':"
  read -s pg_pass

  sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname = '$pg_db'" | grep -q 1 && {
    echo "Banco $pg_db já existe, ignorando criação."
  } || {
    sudo -u postgres psql -c "CREATE DATABASE $pg_db;"
    echo "Banco $pg_db criado."
  }

  sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname = '$pg_user'" | grep -q 1 && {
    echo "Usuário $pg_user já existe, ignorando criação."
  } || {
    sudo -u postgres psql -c "CREATE USER $pg_user WITH PASSWORD '$pg_pass';"
    echo "Usuário $pg_user criado."
  }

  sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $pg_db TO $pg_user;"
  echo "Permissões concedidas para $pg_user no banco $pg_db."
}

# Função para criar .env para instância
create_env_file() {
  inst_name=$1
  pg_db=$2
  pg_user=$3
  pg_pass=$4
  port=$5

  mkdir -p ~/n8n_instances/$inst_name
  cat > ~/n8n_instances/$inst_name/.env <<EOF
# Configuração para instância $inst_name
N8N_BASIC_AUTH_ACTIVE=true
N8N_BASIC_AUTH_USER=admin
N8N_BASIC_AUTH_PASSWORD=admin

DB_TYPE=postgresdb
DB_POSTGRESDB_HOST=localhost
DB_POSTGRESDB_PORT=5432
DB_POSTGRESDB_DATABASE=$pg_db
DB_POSTGRESDB_USER=$pg_user
DB_POSTGRESDB_PASSWORD=$pg_pass

N8N_PORT=$port
EOF
  echo ".env criado em ~/n8n_instances/$inst_name/.env"
}

# Função para criar container docker n8n para instância
create_n8n_container() {
  inst_name=$1
  port=$2

  docker run -d \
    --name $inst_name \
    --restart unless-stopped \
    --env-file ~/n8n_instances/$inst_name/.env \
    -p $port:5678 \
    n8nio/n8n
  echo "Container $inst_name iniciado na porta $port"
}

# Função para atualizar container n8n existente
update_n8n_container() {
  echo "Digite o nome do container da instância N8N que deseja atualizar:"
  read inst_name

  if ! docker ps -a --format '{{.Names}}' | grep -q "^${inst_name}$"; then
    echo "Container $inst_name não encontrado."
    return
  fi

  echo "Parando container $inst_name..."
  docker stop $inst_name
  echo "Removendo container $inst_name..."
  docker rm $inst_name
  echo "Baixando última imagem n8n..."
  docker pull n8nio/n8n
  echo "Reiniciando container $inst_name..."
  # Considera que .env está em ~/n8n_instances/$inst_name/.env e porta está na variável do container anterior
  port=$(docker port $inst_name 5678/tcp | cut -d: -f2)
  if [ -z "$port" ]; then
    echo "Não foi possível detectar a porta exposta. Usando 5678 como padrão."
    port=5678
  fi
  create_n8n_container $inst_name $port
}

# Menu interativo
while true; do
  echo ""
  echo "==== Gerenciamento de instâncias N8N ===="
  echo "1) Instalar nova instância N8N (com banco PostgreSQL local)"
  echo "2) Atualizar instância N8N existente"
  echo "3) Incluir nova instância N8N (com banco PostgreSQL local)"
  echo "4) Sair"
  echo "========================================="
  echo -n "Escolha uma opção [1-4]: "
  read opcao

  case $opcao in
    1|3)
      install_postgres
      create_pg_db_user
      echo "Digite um nome único para a instância (ex: n8n-instancia1):"
      read inst_name
      echo "Digite a porta TCP para expor a instância (ex: 5678):"
      read port

      create_env_file "$inst_name" "$pg_db" "$pg_user" "$pg_pass" "$port"
      create_n8n_container "$inst_name" "$port"
      ;;
    2)
      update_n8n_container
      ;;
    4)
      echo "Saindo..."
      exit 0
      ;;
    *)
      echo "Opção inválida."
      ;;
  esac
done
