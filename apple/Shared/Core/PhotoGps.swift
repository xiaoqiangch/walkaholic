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

    /// 分步操作指引。
    /// 设计原则（用户明确反馈过）：只说「没有位置信息」而不告诉用户怎么改，是最差的体验。
    public static func reasonSteps(_ reason: PhotoGpsFailure) -> [String] {
        switch reason {
        case .noExif:
            return [
                "这是截图，或从微信/QQ 转发保存的图 —— 这类图片会被去掉位置信息",
                "请用手机「自带的相机 App」直接拍一张（不要截图）",
                "拍之前确认相机界面有「定位箭头」图标（没有说明相机没拿到定位权限）",
                "从相册选图时，选「原始照片 / 实际大小」，不要选压缩过的版本"
            ]
        case .noGpsTag:
            return [
                "打开 iPhone「设置」",
                "设置 → 隐私与安全性 → 定位服务 → 找到「相机」→ 选「使用 App 期间」",
                "回到相机 App，确认界面出现「定位箭头」图标",
                "重新拍一张"
            ]
        case .incompleteGps:
            return [
                "这张照片的位置字段不完整（可能被修图软件改过）",
                "请用手机自带相机 App 重新拍一张，不要用修图软件另存"
            ]
        case .invalidGps:
            return [
                "照片里的坐标超出有效范围（可能被篡改）",
                "请用手机自带相机 App 重新拍一张"
            ]
        case .notImage:
            return [
                "这个文件不是可识别的图片，或是 HEIC/HEIF 等暂不支持的格式",
                "请用相机拍一张 JPEG 照片（设置 → 相机 → 格式 → 兼容性最佳）"
            ]
        case .brokenExif:
            return [
                "这张照片的文件结构异常（可能没下载完整，或被其他软件改过）",
                "请用手机自带相机 App 重新拍一张"
            ]
        case .pngNoExif:
            return [
                "PNG 格式本身不保存位置信息",
                "请用相机拍 JPEG 照片；如果是截图，请改用相机直接拍"
            ]
        }
    }

    /// 一句话摘要（用于 toast 等短提示）
    public static func reasonHowto(_ reason: PhotoGpsFailure) -> String {
        switch reason {
        case .noExif: return "请用手机自带相机拍新照片，不要用截图或转发的图"
        case .noGpsTag: return "请到 设置 → 隐私与安全性 → 定位服务 → 相机 → 选「使用 App 期间」"
        case .incompleteGps: return "请用相机重新拍一张"
        case .invalidGps: return "请用相机重新拍一张"
        case .notImage: return "请选择一张相机拍的 JPEG 照片"
        case .brokenExif: return "请用相机重新拍一张"
        case .pngNoExif: return "请用相机拍 JPEG，不要用截图"
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
