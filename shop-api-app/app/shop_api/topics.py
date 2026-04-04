import os

from .models import BlockWordMessage
from .app import app


filtered_topic_name = os.getenv('TOPIC_GOODS_FILTERED')
filtered_schema_val_name = f"{filtered_topic_name}-value"
prohibited_topic_name = os.getenv('TOPIC_GOODS_PROHIBITED')
prohibited_schema_val_name = f"{prohibited_topic_name}-value"
blocked_words_topic_name = os.getenv('TOPIC_GOODS_PROHIBITION_LIST')

raw_topic = app.topic(os.getenv('TOPIC_GOODS_RAW'), value_type=bytes)
dlq_topic = app.topic(os.getenv('TOPIC_GOODS_DLQ'), value_serializer='json')
blocked_words_topic = app.topic(
    blocked_words_topic_name, value_type=BlockWordMessage)
