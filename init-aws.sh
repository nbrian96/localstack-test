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

# Topics por evento (nombre exacto que usa node-api en getParamsToSendSNS)
# node-api publica a: AWS_SNS_TOPIC_ARN_BASE + topic = .../celutnba_dev_auth_person_emailchanged (sin .fifo)
EVENT_TOPICS=(
  "${TOPIC_PREFIX}_auth_person_emailchanged"
)

# Suscriptores del evento auth_person_emailchanged (queueName en EVENTS.yml con prefijo aplicado)
# Debe coincidir con node-api/src/config/EVENTS.yml
SUBSCRIBERS=(
  "lms_person_emailchanged"
  "participations_person_emailchanged"
  "auth_person_permitemailchanged"
  "auth_person_keycloakemailchanged"
  "sigead_person_emailchanged"
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
# 1. Crear los Topics SNS (estándar, sin FIFO - como los usa node-api para custom topics)
# ============================
for event_topic in "${EVENT_TOPICS[@]}"; do
  EVENT_TOPIC_ARN="arn:aws:sns:${REGION}:${ACCOUNT_ID}:${event_topic}"
  echo ""
  echo "Creando Topic SNS: ${event_topic}"
  awslocal sns create-topic --name "${event_topic}"

  if [ $? -eq 0 ]; then
    echo "✓ Topic creado exitosamente"
  else
    echo "✗ Error al crear el topic (puede que ya exista)"
  fi
done

# ============================
# 2. Crear Queues (estándar) y Suscripciones
# ============================
# Un topic SNS estándar solo puede tener suscripciones a colas SQS estándar (no FIFO)
for event_topic in "${EVENT_TOPICS[@]}"; do
  EVENT_TOPIC_ARN="arn:aws:sns:${REGION}:${ACCOUNT_ID}:${event_topic}"

  echo ""
  echo "=========================================="
  echo "Configurando topic de evento: ${event_topic}"
  echo "=========================================="

  for sub in "${SUBSCRIBERS[@]}"; do
    # Nombre de cola = topicPrefix + queueName (igual que en events.js: topicPrefix_lms_person_emailchanged)
    QUEUE_NAME="${TOPIC_PREFIX}_${sub}"
    QUEUE_ARN="arn:aws:sqs:${REGION}:${ACCOUNT_ID}:${QUEUE_NAME}"
    QUEUE_URL="http://sqs.${REGION}.localhost.localstack.cloud:4566/${ACCOUNT_ID}/${QUEUE_NAME}"

    echo ""
    echo "Configurando suscriptor: ${sub}"
    echo "  - Queue Name: ${QUEUE_NAME}"

    # Crear la Queue SQS estándar (topic SNS estándar no admite colas FIFO)
    awslocal sqs create-queue --queue-name "${QUEUE_NAME}"

    if [ $? -eq 0 ]; then
      echo "  ✓ Queue creada exitosamente"
    else
      echo "  ✗ Error al crear la queue (puede que ya exista)"
    fi

    # Suscribir la Queue al Topic SNS
    # Sin RawMessageDelivery, el Body en SQS es el envoltorio SNS (Type, TopicArn, Message como string);
    # sofia-deco espera el JSON publicado en la raíz (p. ej. message.topic) — igual que con raw delivery en AWS.
    SUBSCRIPTION_ARN=$(awslocal sns subscribe \
      --topic-arn "${EVENT_TOPIC_ARN}" \
      --protocol sqs \
      --notification-endpoint "${QUEUE_ARN}" \
      --query 'SubscriptionArn' --output text 2>/dev/null)

    if [ -n "${SUBSCRIPTION_ARN}" ] && [ "${SUBSCRIPTION_ARN}" != "None" ]; then
      echo "  ✓ Suscripción creada exitosamente"
      awslocal sns set-subscription-attributes \
        --subscription-arn "${SUBSCRIPTION_ARN}" \
        --attribute-name RawMessageDelivery \
        --attribute-value true
      if [ $? -eq 0 ]; then
        echo "  ✓ RawMessageDelivery=true (payload directo en SQS, compatible con NotificationService)"
      else
        echo "  ✗ Error al habilitar RawMessageDelivery"
      fi
    else
      echo "  ✗ Error al crear la suscripción (puede que ya exista sin raw delivery)"
      echo "     Si el consumer sigue viendo topic undefined: elimina la suscripción antigua o borra el volumen de LocalStack y vuelve a ejecutar este script."
    fi

    # Política para permitir que SNS envíe mensajes a SQS
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

  # Idempotente: suscripciones creadas antes (sin raw delivery) siguen enviando el envoltorio SNS
  echo ""
  echo "Sincronizando RawMessageDelivery en suscripciones SQS existentes del topic: ${event_topic}"
  EXISTING_SUBS=$(awslocal sns list-subscriptions-by-topic \
    --topic-arn "${EVENT_TOPIC_ARN}" \
    --query 'Subscriptions[?Protocol==`sqs`].SubscriptionArn' --output text 2>/dev/null || true)
  for sub_arn in ${EXISTING_SUBS}; do
    [ -z "${sub_arn}" ] && continue
    awslocal sns set-subscription-attributes \
      --subscription-arn "${sub_arn}" \
      --attribute-name RawMessageDelivery \
      --attribute-value true \
      && echo "  ✓ RawMessageDelivery en ${sub_arn}"
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
