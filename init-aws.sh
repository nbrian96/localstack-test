#!/bin/bash

# ============================
# Cargar variables de entorno
# ============================
# Si existe un archivo .env en el directorio padre, cargarlo
if [ -f "../node-api/.env" ]; then
  export $(cat ../node-api/.env | grep -v '^#' | xargs)
elif [ -f ".env" ]; then
  export $(cat .env | grep -v '^#' | xargs)
fi

# ============================
# Configuración básica
# ============================
# Variables de entorno requeridas (con valores por defecto para LocalStack)
REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID="${AWS_ACCOUNT_ID:-000000000000}"
TENANT="${TENANT:-celutnba}"
AWS_ENVIRONMENT="${AWS_ENVIRONMENT:-dev}"

# Construir el prefijo del topic (igual que en el código)
if [ -n "${AWS_ENVIRONMENT}" ]; then
  TOPIC_PREFIX="${TENANT}_${AWS_ENVIRONMENT}"
else
  TOPIC_PREFIX="${TENANT}"
fi

# Topic específico por evento
# Formato: ${TOPIC_PREFIX}_${suffix}.fifo
EVENT_TOPICS=(
  "${TOPIC_PREFIX}_auth_person_email-changed.fifo"
)

# Lista de suscriptores (servicios que escuchan el evento)
SUBSCRIBERS=(
  "keycloak"
  "permit"
  "lms"
  "sigead"
  "participations"
)

echo ""
echo "Iniciando configuración de infraestructura local..."
echo ""
echo "Configuración:"
echo "  - Region: ${REGION}"
echo "  - Account ID: ${ACCOUNT_ID}"
echo "  - Tenant: ${TENANT}"
echo "  - Environment: ${AWS_ENVIRONMENT}"
echo "  - Topic Prefix: ${TOPIC_PREFIX}"
echo ""

# ============================
# 1. Crear los Topics SNS (FIFO)
# ============================
# Crear topics específicos por evento
for event_topic in "${EVENT_TOPICS[@]}"; do
  EVENT_TOPIC_ARN="arn:aws:sns:${REGION}:${ACCOUNT_ID}:${event_topic}"
  echo ""
  echo "Creando Topic SNS: ${event_topic}"
  awslocal sns create-topic \
    --name "${event_topic}" \
    --attributes FifoTopic=true,ContentBasedDeduplication=true

  if [ $? -eq 0 ]; then
    echo "✓ Topic creado exitosamente"
  else
    echo "✗ Error al crear el topic (puede que ya exista)"
  fi
done

# ============================
# 2. Crear Queues y Suscripciones
# ============================
# Para cada topic de evento, crear las queues y suscripciones correspondientes
for event_topic in "${EVENT_TOPICS[@]}"; do
  EVENT_TOPIC_ARN="arn:aws:sns:${REGION}:${ACCOUNT_ID}:${event_topic}"
  
  # Extraer el suffix del topic eliminando el prefijo y el servicio que publica
  # Ejemplo: "celutnba_dev_auth_person_email-changed.fifo" -> "person_email-changed"
  EVENT_SUFFIX="${event_topic#${TOPIC_PREFIX}_}"
  EVENT_SUFFIX="${EVENT_SUFFIX%.fifo}"
  # Eliminar el primer segmento (servicio que publica, ej: "auth_")
  EVENT_SUFFIX="${EVENT_SUFFIX#*_}"
  
  echo ""
  echo "=========================================="
  echo "Configurando topic de evento: ${event_topic}"
  echo "=========================================="
  
  for sub in "${SUBSCRIBERS[@]}"; do
    # Determinar el formato del nombre de la queue según el suscriptor
    # keycloak y permit usan formato especial: ${TOPIC_PREFIX}_auth_person_${sub}-email-changed.fifo
    # Los demás usan formato estándar: ${TOPIC_PREFIX}_${sub}_${EVENT_SUFFIX}.fifo
    if [ "${sub}" = "keycloak" ] || [ "${sub}" = "permit" ]; then
      # Formato especial: celutnba_dev_auth_person_keycloak-email-changed.fifo
      QUEUE_NAME="${TOPIC_PREFIX}_auth_person_${sub}-email-changed.fifo"
    else
      # Formato estándar: celutnba_dev_lms_person_email-changed.fifo
      QUEUE_NAME="${TOPIC_PREFIX}_${sub}_${EVENT_SUFFIX}.fifo"
    fi
    
    QUEUE_ARN="arn:aws:sqs:${REGION}:${ACCOUNT_ID}:${QUEUE_NAME}"
    QUEUE_URL="http://sqs.${REGION}.localhost.localstack.cloud:4566/${ACCOUNT_ID}/${QUEUE_NAME}"

    echo ""
    echo "Configurando suscriptor: ${sub}"
    echo "  - Queue Name: ${QUEUE_NAME}"

    # Crear la Queue SQS (FIFO)
    awslocal sqs create-queue \
      --queue-name "${QUEUE_NAME}" \
      --attributes FifoQueue=true,ContentBasedDeduplication=true

    if [ $? -eq 0 ]; then
      echo "  ✓ Queue creada exitosamente"
    else
      echo "  ✗ Error al crear la queue (puede que ya exista)"
    fi

    # Suscribir la Queue al Topic SNS específico del evento
    awslocal sns subscribe \
      --topic-arn "${EVENT_TOPIC_ARN}" \
      --protocol sqs \
      --notification-endpoint "${QUEUE_ARN}"

    if [ $? -eq 0 ]; then
      echo "  ✓ Suscripción creada exitosamente"
    else
      echo "  ✗ Error al crear la suscripción"
    fi

    # Aplicar política para permitir que SNS envíe mensajes a SQS
    awslocal sqs set-queue-attributes \
      --queue-url "${QUEUE_URL}" \
      --attributes "{
        \"Policy\": \"{
          \\\"Version\\\": \\\"2012-10-17\\\",
          \\\"Statement\\\": [{
            \\\"Effect\\\": \\\"Allow\\\",
            \\\"Principal\\\": { \\\"Service\\\": \\\"sns.amazonaws.com\\\" },
            \\\"Action\\\": \\\"sqs:SendMessage\\\",
            \\\"Resource\\\": \\\"${QUEUE_ARN}\\\"
          }]
        }\"
      }"

    if [ $? -eq 0 ]; then
      echo "  ✓ Política aplicada exitosamente"
    else
      echo "  ✗ Error al aplicar la política"
    fi
  done
done

echo ""
echo "=========================================="
echo "¡Todo listo! Infraestructura creada correctamente."
echo ""
echo "Topics creados:"
for event_topic in "${EVENT_TOPICS[@]}"; do
  echo "  - Topic: ${event_topic}"
done
echo ""
echo "Variables de entorno requeridas en .env:"
echo "  AWS_REGION=${REGION}"
echo "  AWS_ACCOUNT_ID=${ACCOUNT_ID}"
echo "  TENANT=${TENANT}"
echo "  AWS_ENVIRONMENT=${AWS_ENVIRONMENT}"
echo "  AWS_SNS_TOPIC_ARN_BASE=arn:aws:sns:${REGION}:${ACCOUNT_ID}:"
echo "  AWS_ENDPOINT=http://localhost:4566"
echo "  AWS_ACCESS_KEY_ID=test"
echo "  AWS_SECRET_ACCESS_KEY=test"
echo "=========================================="
echo ""
