import Foundation
import ImageIO
import CoreGraphics

// MARK: - 拍照 + EXIF GPS 到达验证（docs/territory.md 四）
//
// 为什么不用手机 GPS：定位可以被模拟/伪造。真正的「到过」= 在目的地 120 米内，
// 拍一张**照片本身带 GPS** 的图，读 EXIF 比对。
//
// 只做纯解析/判定，不依赖 UI；照片的数据由 App 层从相册/相机取。

public enum PhotoGpsFailure: String, CaseIterable, Sendable {
    case noExif
    case noGpsTag
    case incompleteGps
    case invalidGps
    case notImage
    case brokenExif
    case pngNoExif
}

public enum PhotoGpsResult: Equatable, Sendable {
    case ok(lat: Double, lon: Double)
    case failed(reason: PhotoGpsFailure)

    public var gps: GeoPoint? {
        if case .ok(let lat, let lon) = self { return GeoPoint(latitude: lat, longitude: lon) }
        return nil
    }

    public var failure: PhotoGpsFailure? {
        if case .failed(let reason) = self { return reason }
        return nil
    }
}

public enum PhotoGps {

    /// 到达判定半径（米）
    public static let radiusMeters: Double = 120

    // MARK: 读取 EXIF GPS

    public static func read(from data: Data) -> PhotoGpsResult {
        guard !data.isEmpty else { return .failed(reason: .notImage) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            return .failed(reason: .notImage)
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return .failed(reason: .brokenExif)
        }

        let sourceType = (CGImageSourceGetType(source) as String?) ?? ""
        let hasExif = properties[kCGImagePropertyExifDictionary] != nil
        let gpsValue = properties[kCGImagePropertyGPSDictionary]

        guard let gpsValue else {
            if sourceType.localizedCaseInsensitiveContains("png") {
                return .failed(reason: .pngNoExif)
            }
            // 有 EXIF 但无 GPS：相机没开位置信息（不是截图/没 EXIF）
            return .failed(reason: hasExif ? .noGpsTag : .noExif)
        }
        guard let gps = gpsValue as? [CFString: Any] else {
            return .failed(reason: .brokenExif)
        }

        guard let latitude = number(gps[kCGImagePropertyGPSLatitude]),
              let longitude = number(gps[kCGImagePropertyGPSLongitude]) else {
            return .failed(reason: .incompleteGps)
        }

        // ImageIO 给的是**无符号十进制**度；南纬/西经按 Ref 取负
        let latRef = ((gps[kCGImagePropertyGPSLatitudeRef] as? String) ?? "N").uppercased()
        let lonRef = ((gps[kCGImagePropertyGPSLongitudeRef] as? String) ?? "E").uppercased()
        let signedLat = latRef.hasPrefix("S") ? -latitude : latitude
        let signedLon = lonRef.hasPrefix("W") ? -longitude : longitude

        guard signedLat.isFinite, signedLon.isFinite,
              abs(signedLat) <= 90, abs(signedLon) <= 180 else {
            return .failed(reason: .invalidGps)
        }
        return .ok(lat: signedLat, lon: signedLon)
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    // MARK: 到达判定

    /// - Returns: ok 是否在半径内；distance 是照片坐标到目的地的距离（米），拍照失败时为 nil
    public static func verify(
        target: GeoPoint,
        photo: PhotoGpsResult,
        radiusMeters: Double = PhotoGps.radiusMeters
    ) -> (ok: Bool, distance: Double?) {
        guard let gps = photo.gps else { return (false, nil) }
        let distance = haversineMeters(
            aLat: target.latitude,
            aLon: target.longitude,
            bLat: gps.latitude,
            bLon: gps.longitude
        )
        return (distance <= radiusMeters, distance)
    }

    public static func tooFarText(distance: Double, radiusMeters: Double = PhotoGps.radiusMeters) -> String {
        "照片拍摄点离目的地 \(Int(distance.rounded())) 米，需要在 \(Int(radiusMeters.rounded())) 米内拍摄。走近一点再拍一张。"
    }

    // MARK: 文案（与 docs/territory.md / exif.js 失败文案表一致）

    public static func reasonText(_ reason: PhotoGpsFailure) -> String {
        switch reason {
        case .noExif: return "这张照片没有位置信息"
        case .noGpsTag: return "相机没有开启「位置信息」"
        case .incompleteGps: return "照片的位置数据不完整"
        case .invalidGps: return "照片坐标不合法"
        case .notImage: return "这不是有效的照片文件"
        case .brokenExif: return "照片信息损坏"
        case .pngNoExif: return "PNG 照片不保存位置信息"
        }
    }

    public static func reasonHowto(_ reason: PhotoGpsFailure) -> String {
        switch reason {
        case .noExif:
            return "请用手机自带相机 App 拍一张新照片（不要用截图，也不要转发微信里的图）"
        case .noGpsTag:
            // 任务给定的精确文案（B3）
            return "请到 设置 → 相机 → 打开「位置信息」或「地点标记」，然后重新拍一张"
        case .incompleteGps:
            return "这张图的位置信息被改过或不完整，请重新用相机拍一张"
        case .invalidGps:
            return "请重新用相机拍一张"
        case .notImage:
            return "请选择一张照片"
        case .brokenExif:
            return "请重新用相机拍一张"
        case .pngNoExif:
            return "请用相机拍 JPEG 照片，不要用截图或 PNG"
        }
    }

    // MARK: 距离

    private static func haversineMeters(aLat: Double, aLon: Double, bLat: Double, bLon: Double) -> Double {
        let earthRadius = 6_371_008.8
        let toRad = Double.pi / 180
        let dLat = (bLat - aLat) * toRad
        let dLon = (bLon - aLon) * toRad
        let sLat = sin(dLat / 2)
        let sLon = sin(dLon / 2)
        let h = sLat * sLat + cos(aLat * toRad) * cos(bLat * toRad) * sLon * sLon
        return 2 * earthRadius * asin(min(1, max(0, sqrt(h))))
    }
}
