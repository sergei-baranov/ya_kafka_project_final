from datetime import datetime
import warnings

warnings.simplefilter("ignore", UserWarning)

import faust


class BlockWordMessage(faust.Record):
    word: str
    timestamp: datetime
    block: bool
