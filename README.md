# 🚀 Guía Definitiva: Docker + LocalStack + AWS CLI (SNS / SQS)

Este README documenta **paso a paso** cómo levantar un entorno de desarrollo local que simula servicios de AWS usando **Docker + LocalStack**, enfocado principalmente en **SNS y SQS (FIFO)**.

Funciona tanto en **Ubuntu 22.04** como en versiones más nuevas.

---

## 📦 Requisitos

- Ubuntu 22.04+
- Acceso a internet
- Permisos sudo

---

## 1️⃣ Instalación de Docker Engine

LocalStack corre sobre Docker, así que esto es obligatorio.

### 🧹 Limpieza de instalaciones previas (recomendado)
```bash
sudo apt remove $(dpkg --get-selections docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc | cut -f1)
```

### 🔐 Configurar repositorio oficial de Docker
```bash
sudo apt update
sudo apt install ca-certificates curl -y
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
```

```bash
sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
```

```bash
sudo apt update
sudo apt install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y
```

### 👤 Ejecutar Docker sin sudo
```bash
sudo usermod -aG docker $USER
newgrp docker
```

Verificar:
```bash
docker version
```

---

## 2️⃣ AWS CLI v2 + awslocal

### 🔧 Instalar AWS CLI v2 (binario oficial)
```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
sudo apt install unzip -y
unzip awscliv2.zip
sudo ./aws/install --update
hash -r
```

Verificar:
```bash
aws --version
```

### 🧩 Instalar awslocal (wrapper de LocalStack)
```bash
pip3 install awscli-local
```

Asegurar PATH:
```bash
export PATH=$PATH:$HOME/.local/bin
echo 'export PATH=$PATH:$HOME/.local/bin' >> ~/.bashrc
```

Verificar:
```bash
awslocal --version
```

---

## 3️⃣ LocalStack (docker-compose.yml)

Crear archivo `docker-compose.yml`:

```yaml
services:
  localstack:
    container_name: localstack_main
    image: localstack/localstack:latest
    ports:
      - "127.0.0.1:4566:4566"
      - "127.0.0.1:4510-4559:4510-4559"
    environment:
      - SERVICES=sns,sqs
      - DEBUG=1
      - DOCKER_HOST=unix:///var/run/docker.sock
    volumes:
      - "./volume:/var/lib/localstack"
      - "/var/run/docker.sock:/var/run/docker.sock"
```

Levantar LocalStack:
```bash
docker compose up -d
```

Ver logs:
```bash
docker logs -f localstack_main
```

---

## 4️⃣ Automatización de Infraestructura (init-aws.sh)

Script para crear **1 Topic SNS FIFO genérico + múltiples colas SQS FIFO suscriptas**.

El script crea:
- **Topic genérico**: `{TENANT}_{ENVIRONMENT}.fifo` (ej: `celutnba_dev.fifo`)
- **Queues específicas**: `{TENANT}_{ENVIRONMENT}_auth_person_email-changed_{subscriber}.fifo`

El script carga automáticamente las variables de entorno desde `.env` si existe.

Ejecutar:
```bash
chmod +x init-aws.sh
./init-aws.sh
```

**Estructura creada:**
- Topic: `celutnba_dev.fifo`
- Queues:
  - `celutnba_dev_auth_person_email-changed_keycloak.fifo`
  - `celutnba_dev_auth_person_email-changed_permitio.fifo`
  - `celutnba_dev_auth_person_email-changed_lms.fifo`
  - `celutnba_dev_auth_person_email-changed_sigead.fifo`
  - `celutnba_dev_auth_person_email-changed_participations.fifo`

---

## 5️⃣ Variables de Entorno (.env)

Crear archivo `.env` en el directorio `node-api/` con las siguientes variables:

```env
# AWS con LocalStack
AWS_ACCESS_KEY_ID=test
AWS_SECRET_ACCESS_KEY=test
AWS_REGION=us-east-1
AWS_ENDPOINT=http://localhost:4566

# Configuración de tenant y ambiente
TENANT=celutnba
AWS_ENVIRONMENT=dev

# Bases para construir ARNs y URLs
AWS_SNS_TOPIC_ARN_BASE=arn:aws:sns:us-east-1:000000000000:
AWS_URL_QUEUE_BASE=http://localhost:4566/000000000000

# Suscriptores de eventos (opcional)
NOTIFICATION_EVENT_SUBSCRIBERS={"person_email_changed":["keycloak","permitio","lms","sigead","participations"]}
```

**Nota:** El script `init-aws.sh` carga automáticamente estas variables desde `.env` si existe en el directorio `node-api/` o en el directorio actual.

---

## 6️⃣ Comandos Útiles (Debug & Operación)

### 📜 Listar recursos

**Listar todos los topics SNS:**
```bash
awslocal sns list-topics
```

**Listar todas las queues SQS:**
```bash
awslocal sqs list-queues
```

**Ver suscripciones de un topic:**
```bash
awslocal sns list-subscriptions-by-topic \
  --topic-arn arn:aws:sns:us-east-1:000000000000:celutnba_dev_auth_person_email-changed.fifo
```

### 📤 Publicar mensaje SNS FIFO

**Publicar mensaje simple:**
```bash
awslocal sns publish \
  --topic-arn arn:aws:sns:us-east-1:000000000000:celutnba_dev.fifo \
  --message "Test Message" \
  --message-group-id "dev-test" \
  --message-deduplication-id "$(date +%s)"
```

**Publicar mensaje con atributos (formato real):**
```bash
awslocal sns publish \
  --topic-arn arn:aws:sns:us-east-1:000000000000:celutnba_dev.fifo \
  --message '{"event":"person_email_changed","topic":"celutnba_dev_auth_person_email-changed.fifo","data":{"userId":123,"previousEmail":"old@example.com","newEmail":"new@example.com"},"origin":"MS-Auth"}' \
  --message-group-id "celutnba_dev_auth_person_email-changed.fifo" \
  --message-deduplication-id "$(date +%s)" \
  --message-attributes '{
    "Destino": {"DataType": "String", "StringValue": "celutnba_dev_auth_person_email-changed_keycloak.fifo_queue"},
    "AuthToken": {"DataType": "String", "StringValue": "Bearer token123"},
    "AppToken": {"DataType": "String", "StringValue": "app-token-123"}
  }'
```

### 📥 Ver mensajes de un Topic

**⚠️ Importante:** Los topics SNS **no almacenan mensajes**. Los mensajes se envían a las queues SQS suscritas. Para ver los mensajes publicados en un topic, debes leerlos de las queues.

**Ver todas las suscripciones de un topic:**
```bash
awslocal sns list-subscriptions-by-topic \
  --topic-arn arn:aws:sns:us-east-1:000000000000:celutnba_dev.fifo
```

**Ver mensajes de todas las queues suscritas al topic:**
```bash
# Obtener lista de queues y leer mensajes de cada una
for queue in $(awslocal sqs list-queues --query 'QueueUrls[]' --output text | grep "celutnba_dev_auth_person_email-changed"); do
  echo "=== Mensajes en: $queue ==="
  awslocal sqs receive-message \
    --queue-url "$queue" \
    --attribute-names All \
    --message-attribute-names All \
    --max-number-of-messages 10 | jq '.'
  echo ""
done
```

**Leer mensajes de una queue específica (Keycloak):**
```bash
awslocal sqs receive-message \
  --queue-url http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/celutnba_dev_auth_person_email-changed_keycloak.fifo \
  --attribute-names All \
  --message-attribute-names All \
  --max-number-of-messages 10
```

**Leer mensajes de una queue específica (Permitio):**
```bash
awslocal sqs receive-message \
  --queue-url http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/celutnba_dev_auth_person_email-changed_permitio.fifo \
  --attribute-names All \
  --message-attribute-names All \
  --max-number-of-messages 10
```

**Leer mensajes con formato JSON legible:**
```bash
awslocal sqs receive-message \
  --queue-url http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/celutnba_dev_auth_person_email-changed_keycloak.fifo \
  --attribute-names All \
  --message-attribute-names All | jq '.'
```

**Ver el cuerpo del mensaje parseado:**
```bash
awslocal sqs receive-message \
  --queue-url http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/celutnba_dev_auth_person_email-changed_keycloak.fifo \
  --attribute-names All \
  --message-attribute-names All | jq '.Messages[0].Body | fromjson'
```

**Nota:** Las URLs de las queues pueden usar cualquiera de estos formatos:
- `http://localhost:4566/000000000000/{QUEUE_NAME}`
- `http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/{QUEUE_NAME}`

Ambos funcionan, pero LocalStack puede mostrar el segundo formato en algunos comandos.


### 🧹 Borrar mensaje (ack)

Después de procesar un mensaje, debes eliminarlo de la queue:

```bash
awslocal sqs delete-message \
  --queue-url http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/celutnba_dev_auth_person_email-changed_keycloak.fifo \
  --receipt-handle "<RECEIPT_HANDLE>"
```

**Ejemplo completo (leer y borrar):**
```bash
# 1. Leer mensaje
QUEUE_URL="http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/celutnba_dev_auth_person_email-changed_keycloak.fifo"
RESPONSE=$(awslocal sqs receive-message \
  --queue-url "$QUEUE_URL")

# 2. Extraer receipt handle
RECEIPT_HANDLE=$(echo $RESPONSE | jq -r '.Messages[0].ReceiptHandle')

# 3. Borrar mensaje
awslocal sqs delete-message \
  --queue-url "$QUEUE_URL" \
  --receipt-handle "$RECEIPT_HANDLE"
```

### 🔍 Ver atributos y configuración

**Ver atributos de una queue:**
```bash
awslocal sqs get-queue-attributes \
  --queue-url http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/celutnba_dev_auth_person_email-changed_keycloak.fifo \
  --attribute-names All
```

**Ver atributos de un topic:**
```bash
awslocal sns get-topic-attributes \
  --topic-arn arn:aws:sns:us-east-1:000000000000:celutnba_dev.fifo
```

**Ver cantidad de mensajes aproximados en una queue:**
```bash
awslocal sqs get-queue-attributes \
  --queue-url http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/celutnba_dev_auth_person_email-changed_keycloak.fifo \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible
```

### 🗑️ Limpiar recursos

**Eliminar una queue:**
```bash
awslocal sqs delete-queue \
  --queue-url http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/celutnba_dev_auth_person_email-changed_keycloak.fifo
```

**Eliminar un topic:**
```bash
awslocal sns delete-topic \
  --topic-arn arn:aws:sns:us-east-1:000000000000:celutnba_dev.fifo
```

**Limpiar todas las queues (cuidado!):**
```bash
for queue in $(awslocal sqs list-queues --query 'QueueUrls[]' --output text); do
  awslocal sqs delete-queue --queue-url "$queue"
done
```

### 🔄 Purgar una queue (eliminar todos los mensajes)

```bash
awslocal sqs purge-queue \
  --queue-url http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/celutnba_dev_auth_person_email-changed_keycloak.fifo
```

### 📊 Monitoreo continuo

**Monitorear mensajes en tiempo real (requiere jq):**
```bash
watch -n 2 'awslocal sqs receive-message \
  --queue-url http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/celutnba_dev_auth_person_email-changed_keycloak.fifo \
  --max-number-of-messages 1 | jq "."'
```

### 🔍 Script helper: Ver mensajes de todas las queues de un topic

Crear un script `view-topic-messages.sh`:

```bash
#!/bin/bash

TOPIC_ARN="arn:aws:sns:us-east-1:000000000000:celutnba_dev.fifo"

echo "📋 Suscripciones del topic: $TOPIC_ARN"
echo ""

# Obtener suscripciones
SUBSCRIPTIONS=$(awslocal sns list-subscriptions-by-topic \
  --topic-arn "$TOPIC_ARN" \
  --query 'Subscriptions[?Protocol==`sqs`].Endpoint' \
  --output text)

if [ -z "$SUBSCRIPTIONS" ]; then
  echo "❌ No hay suscripciones SQS para este topic"
  exit 1
fi

# Para cada suscripción (queue ARN), extraer el nombre y leer mensajes
for QUEUE_ARN in $SUBSCRIPTIONS; do
  # Extraer nombre de la queue del ARN
  QUEUE_NAME=$(echo $QUEUE_ARN | awk -F: '{print $NF}')
  
  # Construir URL de la queue
  QUEUE_URL="http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/$QUEUE_NAME"
  
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "📬 Queue: $QUEUE_NAME"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  
  # Leer mensajes
  MESSAGES=$(awslocal sqs receive-message \
    --queue-url "$QUEUE_URL" \
    --attribute-names All \
    --message-attribute-names All \
    --max-number-of-messages 10)
  
  if echo "$MESSAGES" | jq -e '.Messages' > /dev/null 2>&1; then
    echo "$MESSAGES" | jq '.Messages[] | {
      MessageId: .MessageId,
      Body: (.Body | fromjson),
      Attributes: .Attributes,
      MessageAttributes: .MessageAttributes
    }'
  else
    echo "  (sin mensajes)"
  fi
  
  echo ""
done
```

Hacer ejecutable y usar:
```bash
chmod +x view-topic-messages.sh
./view-topic-messages.sh
```

**Ver logs de LocalStack:**
```bash
docker logs -f localstack_main
```

---

## ✅ Checklist rápido

- [ ] Docker corriendo
- [ ] LocalStack levantado
- [ ] awslocal responde
- [ ] Topic creado
- [ ] Colas suscriptas
- [ ] Mensajes fluyen

---

