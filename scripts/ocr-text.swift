#!/usr/bin/env swift
import Foundation
import Vision

let arguments = Array(CommandLine.arguments.dropFirst())
let batch = arguments.first == "--batch-json"
let paths = batch ? Array(arguments.dropFirst()) : arguments
guard !paths.isEmpty else {
    FileHandle.standardError.write(Data("用法：ocr-text.swift <image>...\n".utf8))
    exit(2)
}

func recognize(_ path: String) throws -> [String] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    let handler = VNImageRequestHandler(url: URL(fileURLWithPath: path), options: [:])
    try handler.perform([request])
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
}

var failed = false
for path in paths {
    let text = (try? recognize(path)) ?? []
    if text.isEmpty { failed = true }
    if batch {
        // JSON Lines 保留每一张图片的边界，空数组表示识别失败。
        let encoded = try JSONEncoder().encode(text)
        print(String(decoding: encoded, as: UTF8.self))
    } else {
        for segment in text { print(segment) }
    }
}
if failed && !batch {
    FileHandle.standardError.write(Data("识别失败\n".utf8))
    exit(2)
}
