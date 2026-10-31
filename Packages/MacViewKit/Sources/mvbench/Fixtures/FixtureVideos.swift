import AVFoundation
import CoreVideo
import Foundation
import MVFoundation

/// 用 AVAssetWriter 生成视频夹具，每帧是一张带移动竖条的合成图。
enum FixtureVideo {
    struct Spec: Sendable {
        var fileType: AVFileType
        var codec: AVVideoCodecType
        /// 编码的尺寸（轨道的 naturalSize）。
        var size: PixelSize
        var frames: Int
        var frameRate: Int32
        /// 轨道变换顺时针旋转 90°，与竖着拍的手机视频一样。
        var rotated = false
    }

    static func write(_ spec: Spec, title: String, to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: spec.fileType)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: spec.codec,
            AVVideoWidthKey: spec.size.width,
            AVVideoHeightKey: spec.size.height,
        ])
        if spec.rotated {
            input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(spec.size.height), ty: 0)
        }
        guard writer.canAdd(input) else { throw FixtureError("AVAssetWriter 不能添加视频轨道：\(spec.codec.rawValue)") }
        // 创建接收器时把输入加进 writer。
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: CVPixelBufferCreationAttributes(
            pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_32BGRA),
            size: CVImageSize(width: spec.size.width, height: spec.size.height)
        ))
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        for index in 0..<spec.frames {
            guard let pool = receiver.pixelBufferPool else { throw FixtureError("没有像素缓冲池") }
            var buffer = try pool.makeMutablePixelBuffer()
            try buffer.accessUnsafeMutableRawPlaneBytes { planes in
                guard let plane = planes.first, let context = CGContext(
                    data: plane.bytes.baseAddress, width: spec.size.width, height: spec.size.height, bitsPerComponent: 8,
                    bytesPerRow: plane.properties.bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                ) else {
                    throw FixtureError("无法在像素缓冲上绘制")
                }
                FixtureArt.draw("\(title) \(index + 1)/\(spec.frames)", in: context, size: spec.size, phase: Double(index) / Double(max(spec.frames - 1, 1)))
            }
            try await receiver.append(CVReadOnlyPixelBuffer(buffer), with: CMTime(value: Int64(index), timescale: spec.frameRate))
        }
        receiver.finish()
        writer.endSession(atSourceTime: CMTime(value: Int64(spec.frames), timescale: spec.frameRate))
        await writer.finishWriting()
        guard writer.status == .completed else { throw FixtureError("写视频失败：\(String(describing: writer.error))") }
    }
}
