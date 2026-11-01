import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 缩略图与浏览图落盘时的编码。读回时用 `ImageDecoder.image` 解码。
public enum RenditionEncoding: String, Sendable, Codable, CaseIterable {
    case heic, jpeg

    /// 渲染件用 JPEG：解码比 HEIC 快 4–6 倍、编码快 4–12 倍，同等 SSIM 下文件约大一倍（S1-T3 实测）。
    public static let `default` = RenditionEncoding.jpeg

    /// 编码质量，0–1。0.8 时缩略图约 130 KB，SSIM 0.99 以上。
    public static let defaultQuality = 0.8

    public var type: UTType {
        switch self {
        case .heic: .heic
        case .jpeg: .jpeg
        }
    }

    public func encode(_ image: CGImage, quality: Double = RenditionEncoding.defaultQuality) throws(MediaError) -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { throw .unsupported }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw .decodeFailed("\(rawValue) 编码失败") }
        return data as Data
    }
}
