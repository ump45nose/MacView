#!/usr/bin/env python3
"""核对 Core 里要本地化的文案都在 App 的 Localizable.xcstrings 里有英文翻译。

Core 的界面文案用 String(localized:bundle: .main) 或 String.LocalizationValue 参数，
运行时由 App 的字符串目录翻译。编译器加 -emit-localized-strings 会为每个源文件写一份
.stringsdata（JSON，含源文件路径与键）；本脚本读这些文件，只看 Packages/MacViewKit/Sources
下仍存在的源文件，列出目录里缺失或没有英文的键。

用法：check-core-strings.py <stringsdata 目录> <Localizable.xcstrings>
"""
import json
import pathlib
import sys


def main() -> int:
    data_dir, catalog_path = map(pathlib.Path, sys.argv[1:3])
    sources = pathlib.Path(__file__).resolve().parent.parent / "Packages/MacViewKit/Sources"
    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))["strings"]
    missing = []
    seen_files = 0
    for path in sorted(data_dir.glob("*.stringsdata")):
        data = json.loads(path.read_text(encoding="utf-8"))
        source = pathlib.Path(data["source"])
        # 只核对 Core 源码；删掉或改名的源文件留下的旧记录跳过
        if sources not in source.parents or not source.exists():
            continue
        seen_files += 1
        for entry in data["tables"].get("Localizable", []):
            key = entry["key"]
            unit = catalog.get(key, {}).get("localizations", {}).get("en", {})
            english = unit.get("stringUnit", {}).get("value") or unit.get("variations")
            if not english:
                line = entry["location"]["startingLine"]
                missing.append(f"{source.relative_to(sources)}:{line}: {key}")
    if seen_files == 0:
        print(f"{data_dir} 里没有 Core 源文件的 .stringsdata", file=sys.stderr)
        return 1
    if missing:
        print("Localizable.xcstrings 缺少以下 Core 文案的英文翻译：", file=sys.stderr)
        print("\n".join(sorted(set(missing))), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
