import Foundation

// MARK: - 步行路线（Valhalla 公共实例）——迷雾路径的形状来源
//
// docs/navigation.md：公开、无需 Key、CORS 全开。
// iOS 原生不存在 CORS，直接 URLSession POST。
// 路线只用于画「当前位置前后一段」，绝不画终点、不画街道名。

@MainActor
final class RouteService {

    static let shared = RouteService()

    private struct CacheEntry {
        let route: WalkingRoute
        let date: Date
    }

    private var cache: [String: CacheEntry] = [:]
    private let cacheTTL: TimeInterval = 10 * 60

    private init() {}

    func walkingRoute(from origin: GeoPoint, to target: GeoPoint) async -> WalkingRoute? {
        let key = String(
            format: "%.4f,%.4f->%.4f,%.4f",
            origin.latitude, origin.longitude,
            target.latitude, target.longitude
        )
        if let entry = cache[key], Date().timeIntervalSince(entry.date) < cacheTTL {
            return entry.route
        }

        guard let url = URL(string: "https://valhalla1.openstreetmap.de/route") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "locations": [
                ["lat": origin.latitude, "lon": origin.longitude],
                ["lat": target.latitude, "lon": target.longitude]
            ],
            "costing": "pedestrian",
            "directions_options": ["language": "zh-CN"]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let trip = root["trip"] as? [String: Any],
                  let legs = trip["legs"] as? [[String: Any]],
                  let leg = legs.first,
                  let shape = leg["shape"] as? String else { return nil }
            let coordinates = Self.decodePolyline6(shape)
            guard coordinates.count >= 2 else { return nil }
            let route = WalkingRoute(points: coordinates, maneuvers: Self.parseManeuvers(leg["maneuvers"]))
            guard route.distanceMeters > 0 else { return nil }
            cache[key] = CacheEntry(route: route, date: Date())
            return route
        } catch {
            return nil
        }
    }

    private static func parseManeuvers(_ rawValue: Any?) -> [RouteManeuver] {
        guard let rawManeuvers = rawValue as? [[String: Any]] else { return [] }
        var cumulative = 0.0
        return rawManeuvers.compactMap { raw in
            guard let type = raw["type"] as? Int,
                  let kilometers = raw["length"] as? Double else { return nil }
            let direction = maneuverDirections[type] ?? "straight"
            let distance = max(0, Int((kilometers * 1000).rounded()))
            let maneuver = RouteManeuver(
                direction: direction,
                label: maneuverLabels[direction] ?? "直行",
                distance: distance,
                cumulative: cumulative
            )
            cumulative += Double(distance)
            return maneuver
        }
    }

    private static let maneuverDirections: [Int: String] = [
        1: "start", 2: "start", 3: "start",
        4: "arrive", 5: "arrive", 6: "arrive",
        7: "straight", 8: "straight", 9: "slight-right", 10: "right",
        11: "sharp-right", 12: "uturn", 13: "uturn", 14: "sharp-left",
        15: "left", 16: "slight-left", 18: "right", 19: "left",
        20: "right", 21: "left", 22: "straight", 23: "slight-right",
        24: "slight-left", 25: "straight", 26: "roundabout", 27: "roundabout",
        37: "straight", 38: "straight", 39: "straight", 40: "straight"
    ]

    private static let maneuverLabels: [String: String] = [
        "start": "出发", "straight": "直行", "slight-right": "向右前方",
        "right": "右拐", "sharp-right": "向右大拐", "slight-left": "向左前方",
        "left": "左拐", "sharp-left": "向左大拐", "uturn": "掉头",
        "roundabout": "走环岛", "arrive": "到达"
    ]

    /// Valhalla 的 shape 是 polyline6（精度 1e-6）
    private static func decodePolyline6(_ encoded: String) -> [GeoPoint] {
        var coordinates: [GeoPoint] = []
        var index = encoded.startIndex
        var latitude = 0
        var longitude = 0

        func nextValue() -> Int? {
            var result = 0
            var shift = 0
            while index < encoded.endIndex {
                let byte = Int(encoded[index].asciiValue ?? 63) - 63
                index = encoded.index(after: index)
                result |= (byte & 0x1f) << shift
                shift += 5
                if byte < 0x20 { break }
            }
            guard shift > 0 else { return nil }
            return (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
        }

        while index < encoded.endIndex {
            guard let dLat = nextValue(), let dLon = nextValue() else { break }
            latitude += dLat
            longitude += dLon
            coordinates.append(GeoPoint(
                latitude: Double(latitude) / 1_000_000,
                longitude: Double(longitude) / 1_000_000
            ))
        }
        return coordinates
    }
}
