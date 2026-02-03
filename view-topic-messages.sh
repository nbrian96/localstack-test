#!/bin/bash

# ============================
# Cargar variables de entorno
# ============================
if [ -f "../node-api/.env" ]; then
  export $(cat ../node-api/.env | grep -v '^#' | xargs)
elif [ -f ".env" ]; then
  export $(cat .env | grep -v '^#' | xargs)
fi

# ============================
# Configuración
# ============================
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
TOPIC_NAME="${TOPIC_PREFIX}_auth_person_email-changed.fifo"
TOPIC_ARN="arn:aws:sns:${REGION}:${ACCOUNT_ID}:${TOPIC_NAME}"

echo "📋 Suscripciones del topic: $TOPIC_ARN"
echo ""

# Obtener suscripciones
SUBSCRIPTIONS=$(awslocal sns list-subscriptions-by-topic \
  --topic-arn "$TOPIC_ARN" \
  --query 'Subscriptions[?Protocol==`sqs`].Endpoint' \
  --output text 2>/dev/null)

if [ -z "$SUBSCRIPTIONS" ]; then
  echo "❌ No hay suscripciones SQS para este topic"
  echo ""
  echo "Verifica que el topic exista:"
  echo "  awslocal sns list-topics"
  exit 1
fi

# Para cada suscripción (queue ARN), extraer el nombre y leer mensajes
for QUEUE_ARN in $SUBSCRIPTIONS; do
  # Extraer nombre de la queue del ARN
  QUEUE_NAME=$(echo $QUEUE_ARN | awk -F: '{print $NF}')
  
  # Construir URL de la queue (ambos formatos funcionan)
  QUEUE_URL="http://sqs.us-east-1.localhost.localstack.cloud:4566/${ACCOUNT_ID}/${QUEUE_NAME}"
  
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "📬 Queue: $QUEUE_NAME"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  
  # Leer mensajes
  MESSAGES=$(awslocal sqs receive-message \
    --queue-url "$QUEUE_URL" \
    --attribute-names All \
    --message-attribute-names All \
    --max-number-of-messages 10 2>/dev/null)
  
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

