"""使用系统 sips 的灰度滤镜示例插件。"""

import os
import subprocess
from macview_plugin import Plugin

PROFILES = [
    "/System/Library/ColorSync/Profiles/Generic Gray Gamma 2.2 Profile.icc",
    "/System/Library/ColorSync/Profiles/Generic Gray Profile.icc",
]

plugin = Plugin()


def _gray_profile():
    for path in PROFILES:
        if os.path.exists(path):
            return path
    raise RuntimeError("找不到系统灰度色彩描述文件")


@plugin.filter("grayscale")
def apply_grayscale(input_path, output_path, parameters):
    profile = _gray_profile()
    result = subprocess.run(
        ["/usr/bin/sips", "-m", profile, input_path, "--out", output_path],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError("sips 转换失败：{}".format((result.stderr or result.stdout).strip()))


if __name__ == "__main__":
    plugin.run()
