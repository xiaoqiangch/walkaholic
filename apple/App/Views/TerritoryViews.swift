import SwiftUI

// MARK: - 疆域卡（我的页）
//
// 规格：docs/territory.md「展示要求 1」
// 圆形印章 + 爵位名 / 释义 + 分享；数据行（面积 / 地点数 / 跨度）+ 进度条。
// 不足 3 个真实点时只提示还差几个，不显示假数据。

struct TerritoryCardView: View {

    let store: WalkaholicStore

    private var stats: TerritoryStats { TerritoryDataSource.stats(store: store) }
    private var info: TerritoryRankInfo { TerritoryMath.rank(for: stats.areaKm2, pointCount: stats.pointCount) }
    private var color: Color { TerritoryStyle.color(for: info.rank) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(color)
                    Text(info.rank.seal)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 48, height: 48)
                .accessibilityLabel("\(info.rank.title)印章")

                VStack(alignment: .leading, spacing: 2) {
                    Text(info.rank.title)
                        .font(.headline)
                        .foregroundStyle(WATheme.ink)
                    Text(info.rank.desc)
                        .font(.subheadline)
                        .foregroundStyle(WATheme.ink2)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.85)

                Spacer(minLength: 0)

                shareLink
            }

            if stats.hasTerritory {
                HStack(spacing: 0) {
                    territoryStat(TerritoryMath.formatArea(stats.areaKm2), "疆域面积")
                    Divider().frame(height: 26)
                    territoryStat("\(stats.pointCount)", "占领地点")
                    Divider().frame(height: 26)
                    territoryStat("\(Int(stats.spanM.rounded()))", "最长跨度", unit: "m")
                }

                ProgressView(value: info.progress)
                    .tint(color)

                if info.capped {
                    Text("边界够大了，但只有 \(stats.pointCount) 个探索点 · 再探索 \(info.pointsNeeded) 个点才能晋\(info.next?.title ?? info.blockedBy?.title ?? "")")
                        .font(.caption)
                        .foregroundStyle(WATheme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(info.next.map { next in
                        let suffix = info.pointsNeeded > 0 ? "（还需 \(info.pointsNeeded) 个探索点）" : ""
                        return "再扩 \(TerritoryMath.formatArea(info.toNextKm2)) 晋\(next.title)\(suffix)"
                    } ?? "已是最高爵位 · 疆域无出其右")
                        .font(.caption)
                        .foregroundStyle(WATheme.ink2)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("再开 \(max(0, 3 - stats.pointCount)) 个盲盒就能围出你的第一块疆域")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(WATheme.ink)
                    Text("至少 3 个真实地点才能围成一片地")
                        .font(.caption)
                        .foregroundStyle(WATheme.ink2)
                }
            }
        }
        .padding(16)
        .background(WATheme.paper)
        .clipShape(RoundedRectangle(cornerRadius: WATheme.cardRadius, style: .continuous))
    }

    private func territoryStat(_ value: String, _ title: String, unit: String? = nil) -> some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.headline)
                    .monospacedDigit()
                if let unit {
                    Text(unit).font(.caption).foregroundStyle(WATheme.ink2)
                }
            }
            Text(title)
                .font(.caption)
                .foregroundStyle(WATheme.ink2)
        }
        .frame(maxWidth: .infinity)
    }

    /// 分享：ImageRenderer 把 TerritoryShareCard 渲染成 UIImage → ShareLink
    private var shareLink: some View {
        let image = renderShareImage()
        return ShareLink(
            item: image,
            preview: SharePreview("我的疆域 · \(info.rank.title)", image: image)
        ) {
            Text("分享")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(WATheme.amber)
        }
        .buttonStyle(.plain)
        .tint(WATheme.amber)
    }

    @MainActor
    private func renderShareImage() -> Image {
        let card = TerritoryShareCard(stats: stats, info: info)
            .frame(width: 360, height: 480)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        renderer.isOpaque = true
        if let uiImage = renderer.uiImage {
            return Image(uiImage: uiImage)
        }
        return Image(systemName: "map")
    }
}

// MARK: - 分享卡（参照 Web renderTerritoryCard）

struct TerritoryShareCard: View {

    let stats: TerritoryStats
    let info: TerritoryRankInfo
    var date: Date = Date()

    private var color: Color { TerritoryStyle.color(for: info.rank) }

    private var dateText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter.string(from: date)
    }

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [Color(hex: 0xF3F5FB), Color(hex: 0xE8ECFB)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // 爵位色带（顶部 10pt 按 720→360 折半成 5pt）
            color.frame(height: 6)

            VStack(spacing: 0) {
                // 印章
                ZStack {
                    Circle().fill(color)
                    Text(info.rank.seal)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 56, height: 56)
                .padding(.top, 34)

                Text(info.rank.title)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Color(hex: 0x111827))
                    .padding(.top, 10)

                Text(info.rank.desc)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: 0x6B7280))
                    .padding(.top, 3)

                territoryShape
                    .frame(width: 200, height: 170)
                    .padding(.top, 14)

                dataRow
                    .padding(.top, 8)

                Spacer(minLength: 0)

                Text("步谜 StepRiddle · \(dateText)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color(hex: 0x9CA3AF))
                    .padding(.bottom, 18)
            }
        }
        .frame(width: 360, height: 480)
        .clipShape(RoundedRectangle(cornerRadius: 0, style: .continuous))
    }

    private var territoryShape: some View {
        Canvas { context, size in
            guard stats.hull.count >= 3 else {
                let text = Text("再开 \(max(0, 3 - stats.pointCount)) 个盲盒即可围出疆域")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: 0x9CA3AF))
                context.draw(text, at: CGPoint(x: size.width / 2, y: size.height / 2), anchor: .center)
                return
            }

            let minX = stats.hull.map(\.x).min() ?? 0
            let maxX = stats.hull.map(\.x).max() ?? 0
            let minY = stats.hull.map(\.y).min() ?? 0
            let maxY = stats.hull.map(\.y).max() ?? 0
            let spanX = max(1, maxX - minX)
            let spanY = max(1, maxY - minY)
            let margin: CGFloat = 18
            let scale = min((size.width - margin * 2) / spanX, (size.height - margin * 2) / spanY)
            let centerX = size.width / 2 - (minX + maxX) / 2 * scale
            let centerY = size.height / 2 + (minY + maxY) / 2 * scale

            func point(_ value: CGPoint) -> CGPoint {
                CGPoint(x: centerX + value.x * scale, y: centerY - value.y * scale)
            }

            var path = Path()
            path.move(to: point(stats.hull[0]))
            for value in stats.hull.dropFirst() {
                path.addLine(to: point(value))
            }
            path.closeSubpath()
            context.fill(path, with: .color(color.opacity(0.20)))
            context.stroke(path, with: .color(color), lineWidth: 2.2)

            for value in stats.hull {
                let dot = point(value)
                let circle = Path(ellipseIn: CGRect(x: dot.x - 4, y: dot.y - 4, width: 8, height: 8))
                context.fill(circle, with: .color(color))
            }
        }
    }

    private var dataRow: some View {
        HStack(spacing: 0) {
            shareStat(TerritoryMath.formatArea(stats.areaKm2), "疆域面积")
            shareStat("\(stats.pointCount)", "占领地点")
            shareStat("\(Int(stats.spanM.rounded()))m", "最长跨度")
        }
        .padding(.horizontal, 20)
    }

    private func shareStat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(Color(hex: 0x111827))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(Color(hex: 0x9CA3AF))
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 分享卡预览 / 系统分享（仅截图 & 走查用）

struct TerritorySharePreviewSheet: View {

    let store: WalkaholicStore
    @Environment(\.dismiss) private var dismiss

    private var stats: TerritoryStats { TerritoryDataSource.stats(store: store) }
    private var info: TerritoryRankInfo { TerritoryMath.rank(for: stats.areaKm2, pointCount: stats.pointCount) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                TerritoryShareCard(stats: stats, info: info)
                    .frame(width: 360, height: 480)
                    .clipShape(RoundedRectangle(cornerRadius: WATheme.cardRadius, style: .continuous))
                    .shadow(color: WATheme.ink.opacity(0.12), radius: 18, y: 8)

                shareLink

                Text("分享卡由 ImageRenderer 渲染；正式入口在「我的 → 疆域卡 → 分享」。")
                    .font(.caption)
                    .foregroundStyle(WATheme.ink2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WATheme.cream)
            .navigationTitle("我的疆域 · \(info.rank.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    @MainActor
    private var shareLink: some View {
        let renderer = ImageRenderer(content: TerritoryShareCard(stats: stats, info: info).frame(width: 360, height: 480))
        renderer.scale = 3
        let image: Image = renderer.uiImage.map(Image.init(uiImage:)) ?? Image(systemName: "map")
        return ShareLink(item: image, preview: SharePreview("我的疆域 · \(info.rank.title)", image: image)) {
            Label("分享身份卡", systemImage: "square.and.arrow.up")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(WATheme.amberDeep)
                .foregroundStyle(.white)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
    }
}

// MARK: - 爵位色

enum TerritoryStyle {
    static func color(for rank: TerritoryRank) -> Color {
        color(hex: rank.colorHex)
    }

    static func color(hex: String) -> Color {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt32(cleaned, radix: 16) ?? 0x9CA3AF
        return Color(hex: value)
    }
}
