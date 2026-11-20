import Foundation

/// 疆域数据来源：只统计「真实来源 + 真实坐标」的已开盒地点。
/// 内置演示地点没有坐标，自然排除（docs/territory.md）。
@MainActor
enum TerritoryDataSource {

    static func points(store: WalkaholicStore) -> [GeoPoint] {
        var seen = Set<String>()
        var points: [GeoPoint] = []
        for card in store.profile.cards {
            guard !seen.contains(card.placeID) else { continue }
            guard let place = PlaceDirectory.shared.place(id: card.placeID),
                  let coordinate = place.coordinate else { continue }
            guard TerritoryMath.realSources.contains(place.source) else { continue }
            seen.insert(card.placeID)
            points.append(coordinate)
        }
        return points
    }

    static func stats(store: WalkaholicStore) -> TerritoryStats {
        TerritoryMath.stats(points: points(store: store))
    }

    static func rankInfo(store: WalkaholicStore) -> TerritoryRankInfo {
        TerritoryMath.rank(for: stats(store: store).areaKm2, pointCount: stats(store: store).pointCount)
    }
}
