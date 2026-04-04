import asyncio
import os
import warnings
from datetime import datetime, timezone
from typing import Optional

import requests

warnings.simplefilter("ignore", UserWarning)

from faust.cli import option

from .agents import persist_block_words
from .app import app
from .models import BlockWordMessage


@app.command()
async def list_block_words(self):
    """Таблица стоп-слов живёт в процессе faust-worker (RocksDB), не в CLI.

    Читаем снимок через HTTP того же приложения (см. pages.get_block_words).
    """
    # тут ситуация такая: когда мы запускаем
    # faust -A shop_api.app list_block_words
    # поднимается другой процесс Python, чем "долгоиграющий" процесс,
    # в котором живёт агент persist_block_words.
    # commands и persist_block_words делят код,
    # но не делят один и тот же живой экземпляр таблицы — это разные процессы
    # и разные локальные хранилища (rocksdb).
    # Веб Faust — HTTP, не HTTPS. Connection refused = на порту нет слушателя
    # (воркер/веб выключен или другой порт).
    _web_port = os.getenv('SHOP_API_WEB_PORT', '6077')
    _explicit = os.getenv('SHOP_API_WEB_BASE', '').strip().rstrip('/')
    if _explicit:
        bases = [_explicit]
    else:
        _h = os.getenv('SERVICE_SHOP_API_APP_NAME', 'shop-api-app')
        bases = [
            f'http://{_h}:{_web_port}',
            f'http://127.0.0.1:{_web_port}',
        ]

    last_err: Optional[Exception] = None
    for base in bases:
        url = f'{base}/get-block-words/'
        try:
            r = await asyncio.to_thread(
                lambda u=url: requests.get(u, timeout=10))
            r.raise_for_status()
            data = r.json()
            if isinstance(data, dict) and data.get('error'):
                print(f"ошибка API: {data}")
                return None
            if not data:
                print('(пусто: воркер не видит записей в таблице '
                      'или ещё не обработал топик)')
                return None
            for row in data:
                print(row)
            return None
        except Exception as e:
            last_err = e
            continue

    print(f'не удалось GET ни один из {bases!r}: {last_err}')
    try:
        _datadir = app.conf.datadir.resolve()
    except Exception:
        _datadir = None
    print(
        'Проверьте: faust-worker в supervisord не в crash-loop'
        '(stderr: ConsistencyError по *-changelog '
        'значит рассинхрон RocksDB и Kafka: остановите воркер,'
        'удалите datadir и перезапустите).'
    )
    return None


@app.command(
    option('--word',
           type=str, default=None,
           help='Word to block|unblock.'),
    option('--block',
           type=bool, default=True,
           help='Block (True) or unblock (False) word.'),
)
async def block_word(self, word: str, block: bool = True):
    """Отправить команду в топик prohibition-list (без RPC).

    ask() требует ответ в f-reply и держит ReplyConsumer до ответа агента;
    параллельно с долгоживущим worker в той же consumer group это часто
    зависает. send() — обычная запись в топик агента,
    обработает основной worker.
    """

    message: BlockWordMessage = BlockWordMessage(
        word=word,
        block=block,
        timestamp=datetime.now(tz=timezone.utc),
    )
    print('sending BlockWordMessage')
    await persist_block_words.send(value=message)
    print(f'sent: word={word!r} block={block}')
    return None
