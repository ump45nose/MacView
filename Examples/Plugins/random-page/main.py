"""随机跳页示例插件。"""

import random
from macview_plugin import Plugin

plugin = Plugin()


@plugin.command("random")
def random_page(arguments, context):
    pages = plugin.mv.pages()
    if not isinstance(pages, list) or not pages:
        return {"jumped": False}
    target = random.randrange(len(pages))
    plugin.mv.goTo(target)
    return {"jumped": True, "index": target}


if __name__ == "__main__":
    plugin.run()
