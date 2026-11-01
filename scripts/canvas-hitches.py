#!/usr/bin/env python3
"""按阶段汇总画布测试的 Animation Hitches 录制。

用法：scripts/canvas-hitches.py <录制.trace> <画布测试结果.json | -> [输出.json]

画布测试结果由 `-MVCanvasTestReport` 写出，其中各阶段的起止时间是显示链接时间戳，
与录制的 mach_absolute_time 同一时基，据此把录制切成阶段。手动滚动的录制没有结果文件，
传 `-` 时整段录制作为一个阶段。每个阶段统计：
- 帧：MacView 提交并上屏的帧（帧生命周期在阶段内结束）；
- 帧时间：每帧为一个刷新间隔，被判为 hitch 的帧再加上 hitch 时长。内容不变时 App 不提交新帧，
  这段空闲不算帧时间，所以不直接用相邻两帧上屏的间隔；
- 卡顿：Instruments 判定的 hitch 次数、总时长与每秒卡顿毫秒数；
- 提交与渲染：MacView 提交（update）和渲染服务器合成（render）的用时。
"""
import json
import math
import subprocess
import sys
import xml.etree.ElementTree as ET


def export(trace, schema):
    """导出一张表，解析 id/ref 去重，返回行的列表；每格是 (显示文本, 原值)。"""
    xpath = f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'
    data = subprocess.run(['xcrun', 'xctrace', 'export', '--input', trace, '--xpath', xpath], check=True, capture_output=True).stdout
    node = ET.fromstring(data).find('node')
    if node is None or node.find('schema') is None:
        return []
    columns = [column.findtext('mnemonic') for column in node.find('schema').findall('col')]
    ids = {}

    def value(element):
        if 'ref' in element.attrib:
            return ids[element.attrib['ref']]
        for child in element.iter():
            if 'id' in child.attrib and child.attrib['id'] not in ids:
                ids[child.attrib['id']] = (child.attrib.get('fmt'), child.text)
        return ids.get(element.attrib.get('id'), (element.attrib.get('fmt'), element.text))

    return [dict(zip(columns, (value(element) for element in row))) for row in node.findall('row')]


def number(cell):
    return int(cell[1])


def percentile(values, fraction):
    if not values:
        return 0
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, max(0, math.ceil(len(ordered) * fraction) - 1))]


def milliseconds(nanoseconds):
    return round(nanoseconds / 1e6, 3)


def main():
    trace, summary_path = sys.argv[1], sys.argv[2]
    summary = json.load(open(summary_path)) if summary_path != '-' else {'phases': [{'name': '手动滚动', 'start': None, 'end': None}]}

    time_info = export(trace, 'time-info')[0]
    epoch_ticks = int(time_info['mabs-epoch'][1])
    numer, denom = (int(text) for text in time_info['timebase-info'][0].split('/'))

    def trace_time(host_seconds):
        """显示链接时间戳（秒）→ 录制内的相对时间（纳秒）。"""
        return host_seconds * 1e9 - epoch_ticks * numer / denom

    updates = [row for row in export(trace, 'hitches-updates') if (row['process'][0] or '').startswith('MacView')]
    swaps = {row['swap-id'][0]: row for row in updates}
    lifetimes = {row['swap-id'][0]: row for row in export(trace, 'hitches-frame-lifetimes') if row['swap-id'][0] in swaps}
    renders = {row['swap-id'][0]: row for row in export(trace, 'hitches-renders') if row['swap-id'][0] in swaps}
    hitches = [row for row in export(trace, 'hitches') if (row['process'][0] or '').startswith('MacView')]
    displays = export(trace, 'device-display-info')
    refresh = 1e9 / max(number(row['max-refresh-rate']) for row in displays)

    phases = []
    for phase in summary['phases']:
        if phase['start'] is None:
            ends = [number(row['start']) + number(row['duration']) for row in lifetimes.values()]
            begin, end = min(ends, default=0), max(ends, default=0) + 1
        else:
            begin, end = trace_time(phase['start']), trace_time(phase['end'])
        presented = sorted(
            number(row['start']) + number(row['duration']) for row in lifetimes.values()
            if begin <= number(row['start']) + number(row['duration']) < end
        )
        in_phase = [row for row in updates if begin <= number(row['start']) < end]
        update_times = [number(row['duration']) for row in in_phase]
        render_times = [number(renders[row['swap-id'][0]]['duration']) for row in in_phase if row['swap-id'][0] in renders]
        phase_hitches = [number(row['duration']) for row in hitches if begin <= number(row['start']) < end]
        frame_times = [refresh] * max(0, len(presented) - len(phase_hitches)) + [refresh + hitch for hitch in phase_hitches]
        seconds = (end - begin) / 1e9
        phases.append({
            'name': phase['name'],
            'seconds': round(seconds, 3),
            'frames': len(presented),
            'framesPerSecond': round(len(presented) / seconds, 1) if seconds else 0,
            'frameTimeP50': milliseconds(percentile(frame_times, 0.5)),
            'frameTimeP99': milliseconds(percentile(frame_times, 0.99)),
            'frameTimeMax': milliseconds(max(frame_times, default=0)),
            'hitches': len(phase_hitches),
            'hitchMilliseconds': milliseconds(sum(phase_hitches)),
            'hitchRatioMsPerSecond': round(sum(phase_hitches) / 1e6 / seconds, 2) if seconds else 0,
            'updateP50': milliseconds(percentile(update_times, 0.5)),
            'updateP99': milliseconds(percentile(update_times, 0.99)),
            'renderP50': milliseconds(percentile(render_times, 0.5)),
            'renderP99': milliseconds(percentile(render_times, 0.99)),
        })

    result = {
        'trace': trace.rstrip('/').split('/')[-1],
        'displays': [{'name': row['device-name'][0], 'builtIn': row['built-in'][0], 'maxRefreshRate': number(row['max-refresh-rate'])} for row in displays],
        'app': {key: value for key, value in summary.items() if key != 'phases'},
        'appPhases': summary['phases'],
        'phases': phases,
    }
    text = json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True) + '\n'
    if len(sys.argv) > 3:
        open(sys.argv[3], 'w').write(text)
    print(text, end='')


if __name__ == '__main__':
    main()
