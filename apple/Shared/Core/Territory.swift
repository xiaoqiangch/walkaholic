import Foundation
import CoreGraphics

// MARK: - 疆域与爵位（三端统一契约 docs/territory.md）
//
// 每个「成功开盒」的真实地点 = 一个占领点；这些点的**凸包面积** = 疆域。
// 只统计有真实坐标、来源真实（curated/osm/wikipedia/amap/baidu/wiki）的地点；
// 内置演示地点没有坐标，自然不计入。
//
// 纯逻辑，不依赖 UI。

public struct TerritoryRank: Identifiable, Hashable, Sendable {
    public let key: String
    public let seal: String
    public let title: String
    public let thresholdKm2: Double
    public let colorHex: String
    public let desc: String
    /// 点数门槛：防「四个角」刷面积（docs/territory.md 三）
    public let minPoints: Int

    public var id: String { key }

    /// 中国古代五等爵 + 士 / 王扩展；阈值必须与 docs/territory.md 逐字一致
    public static let ranks: [TerritoryRank] = [
        TerritoryRank(key: "commoner", seal: "民", title: "白身", thresholdKm2: 0, colorHex: "#9CA3AF", desc: "还没有自己的疆域", minPoints: 0),
        TerritoryRank(key: "shi", seal: "士", title: "士", thresholdKm2: 0.05, colorHex: "#64748B", desc: "初立门户，方寸之地", minPoints: 3),
        TerritoryRank(key: "nan", seal: "男", title: "男爵", thresholdKm2: 0.3, colorHex: "#0EA5E9", desc: "一街一巷，始有封地", minPoints: 5),
        TerritoryRank(key: "zi", seal: "子", title: "子爵", thresholdKm2: 1.2, colorHex: "#14B8A6", desc: "数坊之间，渐成版图", minPoints: 7),
        TerritoryRank(key: "bo", seal: "伯", title: "伯爵", thresholdKm2: 4, colorHex: "#5B6CFF", desc: "半城风物，已在掌中", minPoints: 9),
        TerritoryRank(key: "hou", seal: "侯", title: "侯爵", thresholdKm2: 12, colorHex: "#8B5CF6", desc: "纵横十余里，一方之望", minPoints: 12),
        TerritoryRank(key: "gong", seal: "公", title: "公爵", thresholdKm2: 30, colorHex: "#F59E0B", desc: "半壁城池，位极人臣", minPoints: 15),
        TerritoryRank(key: "wang", seal: "王", title: "王", thresholdKm2: 80, colorHex: "#EF4444", desc: "一城之主，疆域无出其右", minPoints: 21)
    ]
}

public struct TerritoryRankInfo: Sendable {
    public let rank: TerritoryRank
    public let next: TerritoryRank?
    public let progress: Double
    public let toNextKm2: Double
    /// 被点数门槛卡住的面积档（nil = 未被卡）
    public let blockedBy: TerritoryRank?
    /// 是否被点数门槛卡住
    public var capped: Bool { blockedBy != nil }
    /// 还差多少个探索点（capped 时是晋 blockedBy 的点数；否则是晋下一档的点数）
    public let pointsNeeded: Int

    public init(
        rank: TerritoryRank,
        next: TerritoryRank?,
        progress: Double,
        toNextKm2: Double,
        blockedBy: TerritoryRank? = nil,
        pointsNeeded: Int = 0
    ) {
        self.rank = rank
        self.next = next
        self.progress = progress
        self.toNextKm2 = toNextKm2
        self.blockedBy = blockedBy
        self.pointsNeeded = pointsNeeded
    }
}

public struct TerritoryStats: Hashable, Sendable {
    /// 有效真实点数量
    public let pointCount: Int
    /// 投影后的米坐标凸包（用于分享卡等比缩放、或调试）
    public let hull: [CGPoint]
    /// 与 `hull` 一一对应的原始经纬度凸包（CityMapView 画 MapPolygon 用）
    public let hullCoordinates: [GeoPoint]
    public let hullPointCount: Int
    public let areaM2: Double
    public let areaKm2: Double
    /// 凸包顶点两两最大距离（米）
    public let spanM: Double

    public static let empty = TerritoryStats(
        pointCount: 0,
        hull: [],
        hullCoordinates: [],
        hullPointCount: 0,
        areaM2: 0,
        areaKm2: 0,
        spanM: 0
    )

    public init(
        pointCount: Int,
        hull: [CGPoint],
        hullCoordinates: [GeoPoint],
        hullPointCount: Int,
        areaM2: Double,
        areaKm2: Double,
        spanM: Double
    ) {
        self.pointCount = pointCount
        self.hull = hull
        self.hullCoordinates = hullCoordinates
        self.hullPointCount = hullPointCount
        self.areaM2 = areaM2
        self.areaKm2 = areaKm2
        self.spanM = spanM
    }

    public var hasTerritory: Bool { hullPointCount >= 3 && areaM2 > 0 }
}

public enum TerritoryMath {

    /// 叉积共线容差（单位 m²）：小于它视为共线，避免浮点误差留下面积 1e-12 的退化三角形
    public static let collinearEps: Double = 0.5

    public static var ranks: [TerritoryRank] { TerritoryRank.ranks }

    /// 有真实坐标 + 真实来源的地点才计入疆域
    public static let realSources: Set<String> = [
        "curated", "osm", "wikipedia", "amap", "baidu", "wiki", "apple"
    ]

    // MARK: 疆域统计

    public static func stats(points: [GeoPoint]) -> TerritoryStats {
        let valid = points.filter { point in
            point.latitude.isFinite && point.longitude.isFinite
                && abs(point.latitude) <= 90 && abs(point.longitude) <= 180
        }
        guard valid.count >= 3 else {
            return TerritoryStats(
                pointCount: valid.count,
                hull: [],
                hullCoordinates: [],
                hullPointCount: 0,
                areaM2: 0,
                areaKm2: 0,
                spanM: 0
            )
        }

        // 等距圆柱投影：以所有点的平均纬度做近似
        let meanLat = valid.reduce(0.0) { $0 + $1.latitude } / Double(valid.count)
        let kx = cos(meanLat * .pi / 180) * 111_320
        let ky = 110_540.0
        let origin = valid[0]
        let projected = valid.map { point in
            ProjectedPoint(
                x: (point.longitude - origin.longitude) * kx,
                y: (point.latitude - origin.latitude) * ky,
                geo: point
            )
        }

        let hull = convexHull(projected)
        let areaM2 = polygonAreaM2(hull)
        var spanM = 0.0
        if hull.count >= 2 {
            for i in 0..<hull.count {
                for j in (i + 1)..<hull.count {
                    let dx = hull[i].x - hull[j].x
                    let dy = hull[i].y - hull[j].y
                    spanM = max(spanM, (dx * dx + dy * dy).squareRoot())
                }
            }
        }

        return TerritoryStats(
            pointCount: valid.count,
            hull: hull.map { CGPoint(x: $0.x, y: $0.y) },
            hullCoordinates: hull.map(\.geo),
            hullPointCount: hull.count,
            areaM2: areaM2,
            areaKm2: areaM2 / 1_000_000,
            spanM: spanM
        )
    }

    // MARK: 爵位

    /// 爵位判定（docs/territory.md 三）。
    ///
    /// - Parameters:
    ///   - areaKm2: 凸包面积（km²）
    ///   - pointCount: 探索点数；传 nil 时保留旧行为（只看面积，不做点数门槛）
    public static func rank(for areaKm2: Double, pointCount: Int? = nil) -> TerritoryRankInfo {
        let area = areaKm2.isFinite ? max(0, areaKm2) : 0
        let ranks = TerritoryRank.ranks

        // 1) 面积够格的最高一档
        var areaIndex = 0
        for (i, rank) in ranks.enumerated() where area >= rank.thresholdKm2 {
            areaIndex = i
        }
        let areaRank = ranks[areaIndex]

        // 2) 扣除点数门槛：从面积档往下找第一个「点数也够」的档
        var current = areaRank
        if let pointsRaw = pointCount {
            let points = max(0, pointsRaw)
            var currentIndex = 0
            for i in stride(from: areaIndex, through: 0, by: -1) where points >= ranks[i].minPoints {
                currentIndex = i
                break
            }
            current = ranks[currentIndex]
        }

        // 3) 目标档：被点数卡住 → 目标就是被卡的面积档；否则 → 面积上的下一档
        let blockedBy: TerritoryRank? = areaIndex > ranks.firstIndex(where: { $0.key == current.key })! ? areaRank : nil
        let currentIndex = ranks.firstIndex(where: { $0.key == current.key }) ?? 0
        let next: TerritoryRank?
        if let blockedBy {
            next = blockedBy
        } else if currentIndex + 1 < ranks.count {
            next = ranks[currentIndex + 1]
        } else {
            next = nil
        }

        var progress = 1.0
        var toNextKm2 = 0.0
        var pointsNeeded = 0
        if let next {
            if let blockedBy {
                // 被点数卡住：进度按点数算
                let span = max(1, next.minPoints - current.minPoints)
                let points = max(0, pointCount ?? 0)
                progress = min(1, max(0, Double(points - current.minPoints) / Double(span)))
                pointsNeeded = max(0, next.minPoints - points)
                toNextKm2 = 0
            } else {
                let span = next.thresholdKm2 - current.thresholdKm2
                progress = span > 0 ? min(1, max(0, (area - current.thresholdKm2) / span)) : 1
                toNextKm2 = max(0, next.thresholdKm2 - area)
                if let pointCount {
                    pointsNeeded = max(0, next.minPoints - max(0, pointCount))
                }
            }
        }

        return TerritoryRankInfo(
            rank: current,
            next: next,
            progress: progress,
            toNextKm2: toNextKm2,
            blockedBy: blockedBy,
            pointsNeeded: pointsNeeded
        )
    }

    // MARK: 面积格式化

    public static func formatArea(_ areaKm2: Double) -> String {
        let area = areaKm2.isFinite ? max(0, areaKm2) : 0
        if area <= 0 { return "0 m²" }
        if area < 0.01 { return "\(Int((area * 1_000_000).rounded())) m²" }
        if area < 100 {
            let decimals = area < 1 ? 2 : 1
            return String(format: "%.\(decimals)f km²", locale: Locale(identifier: "en_US_POSIX"), area)
        }
        return "\(Int(area.rounded())) km²"
    }

    // MARK: 几何

    private struct ProjectedPoint {
        let x: Double
        let y: Double
        let geo: GeoPoint
    }

    /// Andrew 单调链凸包；返回逆时针点序。
    /// 叉积 ≤ EPS（0.5 m²）视为共线并弹出，防止浮点误差留下退化细长三角。
    private static func convexHull(_ points: [ProjectedPoint]) -> [ProjectedPoint] {
        let sorted = points.sorted { a, b in
            if a.x == b.x { return a.y < b.y }
            return a.x < b.x
        }
        var unique: [ProjectedPoint] = []
        for point in sorted {
            if let last = unique.last, last.x == point.x, last.y == point.y { continue }
            unique.append(point)
        }
        guard unique.count > 2 else { return unique }

        func cross(_ o: ProjectedPoint, _ a: ProjectedPoint, _ b: ProjectedPoint) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        func turnsLeft(_ o: ProjectedPoint, _ a: ProjectedPoint, _ b: ProjectedPoint) -> Bool {
            cross(o, a, b) > collinearEps
        }

        var lower: [ProjectedPoint] = []
        for point in unique {
            while lower.count >= 2, !turnsLeft(lower[lower.count - 2], lower[lower.count - 1], point) {
                lower.removeLast()
            }
            lower.append(point)
        }

        var upper: [ProjectedPoint] = []
        for point in unique.reversed() {
            while upper.count >= 2, !turnsLeft(upper[upper.count - 2], upper[upper.count - 1], point) {
                upper.removeLast()
            }
            upper.append(point)
        }

        lower.removeLast()
        upper.removeLast()
        return lower + upper
    }

    /// 鞋带公式（平方米）
    private static func polygonAreaM2(_ hull: [ProjectedPoint]) -> Double {
        guard hull.count >= 3 else { return 0 }
        var sum = 0.0
        for i in 0..<hull.count {
            let a = hull[i]
            let b = hull[(i + 1) % hull.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }
}
