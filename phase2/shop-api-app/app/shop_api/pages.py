from .app import app
from .tables import block_words_table


@app.page('/get-block-words/')
async def get_block_words(web, request):
    try:
        words_list = []
        for word in block_words_table.keys():
            words_list.append({word: block_words_table[word]})
        return web.json(words_list)
    except Exception as e:
        return web.json({
            'error': str(e)
        }, status=500)


@app.page('/get-block-word/{word}')
async def get_block_word(web, request, word: str):
    try:
        block = block_words_table[word]
        if block is None:
            return web.json({
                'word': word,
                'block': None,
            })
        return web.json({
            'word': word,
            'block': block,
        })
    except Exception as e:
        return web.json({
            'error': str(e),
            'word': word
        }, status=500)
