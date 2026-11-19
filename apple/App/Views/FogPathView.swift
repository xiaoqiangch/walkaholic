import SwiftUI

// MARK: - 步行导航地图（docs/parity.md §3 / docs/navigation.md）
//
// 视觉参照 Apple Maps / Google Maps 的**步行导航**：
//   · 一条带白色描边的蓝色路线，越远越淡，在画布边缘化进背景（没有「线的尽头」）
//   · 「你」是蓝点 + 朝向扇形，钉在画面偏下位置（地图跟着人走，不是人在地图上跑）
//   · 左上角是保密标签，右下角比例尺，右上角指北针（点一下切「随动 / 正北」）
//   · 不画终点、不画街道名、不画终点图标
//
// 朝向语义（与两家文档一致）：
//   · 蓝点扇形 = 你现在面朝哪（device heading）
//   · 路线 = 该怎么走（walk bearing）
//   · 随动转向：画布「上」= 设备朝向，蓝点恒朝上，路线按真实夹角倾斜
//   · 正北朝上：画布「上」= 正北，蓝点随你转身而转，路线固定指向真实方位
//   · 没有罗盘：画布退回「路线朝上」，蓝点不画扇形（不知道就不假装知道）

struct FogPathView: View {

    let route: WalkingRoute?
    let here: GeoPoint?
    /// 设备朝向（罗盘）。nil = 还没拿到
    var heading: Double? = nil
    /// true = 固定正北朝上
    var northUp: Bool = false
    /// 点指北针时回调（切换朝向模式）
    var onToggleOrientation: (() -> Void)? = nil

    private var frame: FogFrame? {
        guard let route, let here else { return nil }
        return FogFrame.make(route: route, here: here, upBearing: northUp ? 0 : heading)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: WATheme.cardRadius, style: .continuous)
                    .fill(WATheme.paper2)

                if let frame, !frame.isHidden {
                    Canvas { context, canvasSize in
                        drawBackdrop(in: &context, size: canvasSize, frame: frame)
                        drawRoute(frame: frame, in: &context, size: canvasSize)
                        drawUser(frame: frame, in: &context, size: canvasSize)
                        drawScaleBar(frame: frame, in: &context, size: canvasSize)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: WATheme.cardRadius, style: .continuous))
                    .accessibilityHidden(true)

                    // 左上：保密标签（不占空间，压在地图边上）
                    fogBadge
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                    // 右上：指北针（只做指示，指针跟着地图转）
                    compassDial(frame: frame)
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

                    // 右下：正北 / 随动 两档切换（这是真正可点的控件）
                    orientationSwitch
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)

                    // 走偏了才提示，正常走路不弹任何东西
                    if abs(frame.userLateral) > FogFrame.deviationMeters {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                                .font(.system(size: 11, weight: .semibold))
                            Text("偏离路线约 \(Int(abs(frame.userLateral).rounded())) 米")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(WATheme.ember)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(WATheme.paper.opacity(0.95))
                        .clipShape(Capsule())
                        .padding(.top, 50)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                } else if frame?.isHidden == true {
                    VStack(spacing: 10) {
                        Image(systemName: "figure.walk.motion")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(WATheme.amber)
                        Text("路线到这里为止")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(WATheme.ink)
                        Text("剩下的路，用眼睛找")
                            .font(.system(size: 12))
                            .foregroundStyle(WATheme.ink3)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("就在附近，抬头看看周围")
                } else {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("正在规划步行路径…")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(WATheme.ink3)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("正在规划步行路径")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: WATheme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: WATheme.cardRadius, style: .continuous)
                    .stroke(WATheme.line, lineWidth: 1)
            )
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: 地图上的按钮

    private var fogBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "cloud.fog")
                .font(.system(size: 10.5, weight: .semibold))
            Text("迷雾路径")
                .font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(WATheme.ink2)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(WATheme.paper.opacity(0.92))
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }

    /// 指北针：红头朝北，指针按 -bearing 旋转（纯指示，不拦截手势）
    private func compassDial(frame: FogFrame) -> some View {
        ZStack {
            Circle()
                .fill(WATheme.paper.opacity(0.95))
            Circle()
                .stroke(WATheme.line, lineWidth: 1)

            VStack(spacing: 0) {
                Triangle()
                    .fill(WATheme.ember)
                    .frame(width: 7, height: 9)
                Triangle()
                    .fill(WATheme.ink3.opacity(0.45))
                    .rotationEffect(.degrees(180))
                    .frame(width: 6, height: 7)
            }
            .rotationEffect(.degrees(-frame.bearing))
            .offset(y: 2.5)
        }
        .frame(width: 34, height: 34)
        .overlay(alignment: .top) {
            Text("N")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(WATheme.ink3.opacity(0.8))
                .padding(.top, 1.5)
        }
        .accessibilityHidden(true)
    }

    /// 正北 / 随动 两档切换 —— 地图上最显眼的模式开关
    private var orientationSwitch: some View {
        HStack(spacing: 0) {
            orientationChip("正北", active: northUp)
            orientationChip("随动", active: !northUp)
        }
        .padding(2)
        .background(WATheme.paper.opacity(0.96))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(WATheme.line, lineWidth: 1))
        .shadow(color: WATheme.ink.opacity(0.08), radius: 4, y: 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("地图朝向，当前\(northUp ? "正北朝上" : "随动转向")")
    }

    private func orientationChip(_ title: String, active: Bool) -> some View {
        Button {
            guard !active else { return }
            onToggleOrientation?()
            WAHaptics.light()
        } label: {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(active ? .white : WATheme.ink2)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(active ? WATheme.ink : Color.clear)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: 绘制

    /// 坐标系：屏幕 x 向右、y 向下；「上」= frame.bearing（随动 = 设备朝向，正北 = 0）
    private struct Metrics {
        let scale: CGFloat
        let userX: CGFloat
        let userY: CGFloat
    }

    private func metrics(for size: CGSize, frame: FogFrame) -> Metrics {
        let userY = size.height * 0.72
        let topInset: CGFloat = 14
        let ahead = max(1, frame.ahead)
        // 统一比例尺（不要 min(纵向, 横向)）：横向放不下就让路线画出画布边缘，
        // 这才是导航地图该有的样子 —— 取小值会把整条路压成中间一根细线。
        let raw = (userY - topInset) / CGFloat(ahead)
        let scale = min(max(raw, 0.5), 2.4)
        return Metrics(scale: scale, userX: size.width / 2, userY: userY)
    }

    private func drawBackdrop(in context: inout GraphicsContext, size: CGSize, frame: FogFrame) {
        let up = frame.bearing
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .color(WATheme.paper2)
        )

        // 淡街区底纹：跟着地图一起转，转身时整张「纸」在动，而不是路线在纸上滑
        var rotated = context
        rotated.translateBy(x: size.width / 2, y: size.height * 0.72)
        rotated.rotate(by: .degrees(-up))
        rotated.translateBy(x: -size.width / 2, y: -size.height * 0.72)

        var grid = Path()
        let step: CGFloat = 54
        var y = -size.height
        while y < size.height * 2 {
            grid.move(to: CGPoint(x: -size.width, y: y))
            grid.addLine(to: CGPoint(x: size.width * 2, y: y))
            y += step
        }
        var x = -size.width
        while x < size.width * 2 {
            grid.move(to: CGPoint(x: x, y: -size.height))
            grid.addLine(to: CGPoint(x: x, y: size.height * 2))
            x += step
        }
        rotated.stroke(grid, with: .color(WATheme.ink.opacity(0.045)), style: StrokeStyle(lineWidth: 1))

        // 距离圆环：给「这段路还有多远」一个尺度参照（不暴露目的地）
        let m = metrics(for: size, frame: frame)
        for step in [50.0, 100.0, 150.0, 200.0] {
            let radius = CGFloat(step) * m.scale
            guard radius > 24, radius < max(size.width, size.height) * 1.1 else { continue }
            let ring = Path(ellipseIn: CGRect(
                x: m.userX - radius,
                y: m.userY - radius,
                width: radius * 2,
                height: radius * 2
            ))
            context.stroke(
                ring,
                with: .color(WATheme.ink.opacity(0.055)),
                style: StrokeStyle(lineWidth: 1, dash: [3, 6])
            )
        }
    }

    private func drawRoute(frame: FogFrame, in context: inout GraphicsContext, size: CGSize) {
        let m = metrics(for: size, frame: frame)
        func point(_ along: Double, _ lateral: Double) -> CGPoint {
            CGPoint(
                x: m.userX + CGFloat(lateral) * m.scale,
                y: m.userY - CGFloat(along) * m.scale
            )
        }

        // 一条连续路径（不是逐段描边）：逐段描白边会把前一段的蓝色线芯盖掉，
        // 看起来像一串白色珠子 —— 这正是之前「一塌糊涂」的主要原因。
        var aheadPath = Path()
        var behindPath = Path()
        var hasAhead = false
        var hasBehind = false
        for segment in frame.segments {
            let p = point(segment.along, segment.lateral)
            if segment.isBehind {
                if hasBehind && shouldConnect(previous: behindPath.currentPoint, to: p) {
                    behindPath.addLine(to: p)
                } else {
                    behindPath.move(to: p)
                    hasBehind = true
                }
            } else {
                if hasAhead && shouldConnect(previous: aheadPath.currentPoint, to: p) {
                    aheadPath.addLine(to: p)
                } else {
                    aheadPath.move(to: p)
                    hasAhead = true
                }
            }
        }

        // 距离越远越淡：竖直渐变近似「按里程渐隐」，线在画布上缘化开，看不出终点在哪
        let fadeEnd = CGPoint(x: 0, y: -size.height * 0.12)
        let fadeStart = CGPoint(x: 0, y: m.userY)

        if hasBehind {
            let gradient = Gradient(stops: [
                .init(color: Color(hex: 0xA9AFBB).opacity(0.40), location: 0),
                .init(color: Color(hex: 0xA9AFBB).opacity(0.05), location: 1)
            ])
            context.stroke(
                behindPath,
                with: .linearGradient(gradient, startPoint: fadeStart, endPoint: CGPoint(x: 0, y: size.height)),
                style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
            )
        }

        if hasAhead {
            let casing = Gradient(stops: [
                .init(color: WATheme.paper.opacity(0.98), location: 0),
                .init(color: WATheme.paper.opacity(0.55), location: 0.55),
                .init(color: WATheme.paper.opacity(0), location: 1)
            ])
            context.stroke(
                aheadPath,
                with: .linearGradient(casing, startPoint: fadeStart, endPoint: fadeEnd),
                style: StrokeStyle(lineWidth: 12, lineCap: .round, lineJoin: .round)
            )
            let core = Gradient(stops: [
                .init(color: WATheme.amber, location: 0),
                .init(color: WATheme.amber.opacity(0.92), location: 0.5),
                .init(color: WATheme.amber.opacity(0), location: 1)
            ])
            context.stroke(
                aheadPath,
                with: .linearGradient(core, startPoint: fadeStart, endPoint: fadeEnd),
                style: StrokeStyle(lineWidth: 7.5, lineCap: .round, lineJoin: .round)
            )
        }

        // 行进方向：蓝线上的白色小箭头（每 55 米一个）
        for chevron in frame.chevrons {
            guard chevron.opacity > 0.25 else { continue }
            let center = point(chevron.along, chevron.lateral)
            var path = Path()
            path.move(to: CGPoint(x: -4.5, y: 3))
            path.addLine(to: CGPoint(x: 0, y: -3.5))
            path.addLine(to: CGPoint(x: 4.5, y: 3))
            var transform = CGAffineTransform(translationX: center.x, y: center.y)
            transform = transform.rotated(by: chevron.angle * .pi / 180)
            context.stroke(
                path.applying(transform),
                with: .color(.white.opacity(0.9 * chevron.opacity)),
                style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
            )
        }
    }

    /// 相邻采样点跳得太远说明中间被截断了，不要连成一条假直线
    private func shouldConnect(previous: CGPoint?, to next: CGPoint) -> Bool {
        guard let previous else { return false }
        return hypot(next.x - previous.x, next.y - previous.y) < 80
    }

    private func drawUser(frame: FogFrame, in context: inout GraphicsContext, size: CGSize) {
        let m = metrics(for: size, frame: frame)
        let userX = m.userX + CGFloat(frame.userLateral) * m.scale
        let userY = m.userY

        // 偏离路线：从路线画一条虚线连回来（只在真的走偏时）
        if abs(frame.userLateral) > FogFrame.deviationMeters {
            var deviation = Path()
            deviation.move(to: CGPoint(x: m.userX, y: userY))
            deviation.addLine(to: CGPoint(x: userX, y: userY))
            context.stroke(
                deviation,
                with: .color(WATheme.ember.opacity(0.7)),
                style: StrokeStyle(lineWidth: 2, dash: [4, 4])
            )
        }

        // 朝向扇形：从蓝点朝「你面朝的方向」张开 ±22°
        if let heading {
            let rotation = heading - frame.bearing
            var cone = Path()
            cone.move(to: .zero)
            cone.addArc(
                center: .zero,
                radius: 34,
                startAngle: .degrees(-90 - 22),
                endAngle: .degrees(-90 + 22),
                clockwise: false
            )
            cone.closeSubpath()
            var transform = CGAffineTransform(translationX: userX, y: userY)
            transform = transform.rotated(by: rotation * .pi / 180)
            context.fill(cone.applying(transform), with: .color(WATheme.amber.opacity(0.22)))
        }

        // 蓝点：白描边 + 蓝芯（Apple Maps 同款）
        let halo = Path(ellipseIn: CGRect(x: userX - 16, y: userY - 16, width: 32, height: 32))
        context.fill(halo, with: .color(WATheme.amber.opacity(0.14)))
        let ring = Path(ellipseIn: CGRect(x: userX - 9.5, y: userY - 9.5, width: 19, height: 19))
        context.fill(ring, with: .color(.white))
        context.stroke(ring, with: .color(WATheme.ink.opacity(0.10)), style: StrokeStyle(lineWidth: 1))
        let dot = Path(ellipseIn: CGRect(x: userX - 6, y: userY - 6, width: 12, height: 12))
        context.fill(dot, with: .color(WATheme.amber))
    }

    /// 比例尺：给人「这段路大概多长」的参照，主流导航地图都有
    private func drawScaleBar(frame: FogFrame, in context: inout GraphicsContext, size: CGSize) {
        let m = metrics(for: size, frame: frame)
        guard m.scale > 0 else { return }
        // 选一个 40…96pt 之间的整数距离
        let candidates: [Double] = [20, 25, 50, 75, 100, 150, 200]
        let meters = candidates.first { CGFloat($0) * m.scale >= 40 } ?? candidates[candidates.count - 1]
        let length = CGFloat(meters) * m.scale

        let origin = CGPoint(x: 14, y: size.height - 20)
        var bar = Path()
        bar.move(to: origin)
        bar.addLine(to: CGPoint(x: origin.x + length, y: origin.y))
        bar.move(to: CGPoint(x: origin.x, y: origin.y - 4))
        bar.addLine(to: CGPoint(x: origin.x, y: origin.y + 4))
        bar.move(to: CGPoint(x: origin.x + length, y: origin.y - 4))
        bar.addLine(to: CGPoint(x: origin.x + length, y: origin.y + 4))
        context.stroke(
            bar,
            with: .color(WATheme.ink.opacity(0.35)),
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
        )
        context.draw(
            Text("\(Int(meters)) 米")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(WATheme.ink3),
            at: CGPoint(x: origin.x + length / 2, y: origin.y - 11)
        )
    }
}

// MARK: - 指北针指针

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
