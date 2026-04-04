from .app import FAUST_TOPIC_PARTITIONS, app

block_words_table = app.Table(
    'block_words_table',
    default=bool,
    partitions=FAUST_TOPIC_PARTITIONS,
)
