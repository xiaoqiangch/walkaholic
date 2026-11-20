import SwiftUI
import Foundation
import PhotosUI
import ImageIO
import UniformTypeIdentifiers

// MARK: - 揭晓 Reveal（design-system §5.4，全屏覆盖；视觉基准：web 原型 #/reveal）
//
// 两段：
// 1. 开盒（深色 ink 背景，盒子抖动 → 盒盖弹飞 + 暖光 + 纸屑，1.2s）
// 2. 卡片（奶油纸上的地点卡，-1.2° 微倾；收进图鉴 / 分享）

struct RevealView: View {

    let store: WalkaholicStore
    var onCollected: (CollectResult) -> Void
    /// 可选：右上角「关闭」的回调。
    /// 由于揭晓页是从旅程页全屏推入的，只有调用方（JourneyView）能真正收起它；
    /// 没传就不显示关闭按钮，避免出现按了没反应 / 误跳到图鉴的路径。
    var onClose: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var didStart = false
    @State private var showCard = false

    // 开盒动画
    @State private var boxShake = false
    @State private var lidUp = false
    @State private var lightOn = false
    @State private var particlesOut = false
    @State private var particlesFade = false

    // 卡片交互
    @State private var taskDone = false
    @State private var hasShared = false
    @State private var hasCollected = false
    @State private var isCollecting = false
    @State private var lastCollectedResult: CollectResult?
    @State private var toasts: [WAToast] = []

    // 到达时的实拍：拍完先存本机，登录后再上传到账号（按地点存，换机也能取回）
    @State private var showCamera = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var checkInImage: UIImage?
    @State private var checkInPhotoName: String?
    @State private var checkInRemotePath: String?
    @State private var isUploadingPhoto = false

    // 到达验证：照片 EXIF GPS 与目的地的比对
    @State private var photoGpsResult: PhotoGpsResult?
    @State private var photoGpsDistance: Double?
    @State private var photoGpsVerified = false
    @State private var photoVerifyPrompt: PhotoVerifyPrompt?

    private var place: Place? {
        store.reveal?.place ?? store.currentPlace
    }

    private var serialText: String {
        let seed = UInt64(max(0, store.session?.startedAt.timeIntervalSince1970 ?? 0))
        return "No.\(BlindBoxEngine.serial(seed: seed))"
    }

    /// 后台策展信息（照片 / 署名 / 简介）。只有到达后的 Reveal 页才读取；
    /// 旅程页/首页都不会碰它（保密规则）。查不到时静默降级为普通卡片。
    private var curatedInfo: CuratedPlaceInfo? {
        guard let place else { return nil }
        return AdminPOIService.shared.info(for: place)
    }

    private var isCurated: Bool {
        place?.source == "curated"
    }

    var body: some View {
        ZStack {
            if showCard {
                cardStage
                    .transition(.opacity)
            } else {
                openingStage
                    .transition(.opacity)
            }

            toastLayer
        }
        .animation(WAAnimation.slow, value: showCard)
        .interactiveDismissDisabled(true)
        .onAppear(perform: startOpening)
        .onAppear { loadExistingCheckInPhoto() }
        .sheet(isPresented: $showCamera) {
            CameraPhotoPicker(
                onPicked: { image in
                    showCamera = false
                    handleCheckInPhoto(image)
                },
                onCancel: { showCamera = false }
            )
            .ignoresSafeArea()
        }
        .sheet(item: $photoVerifyPrompt) { prompt in
            PhotoVerificationSheet(issue: prompt.issue) {
                photoVerifyPrompt = nil
                showCamera = true
            }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { @MainActor in
                // 必须在压缩前拿到原始 Data：save() 会重编码，EXIF 就没了
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    handleCheckInPhoto(image, data: data)
                } else if let image = await PhotoLibraryService.loadImage(from: item) {
                    handleCheckInPhoto(image)
                }
                pickerItem = nil
            }
        }
        .onAppear {
            // 仅用于截图/演示：`WA_PREVIEW_TOAST=1` 自动点一次「收进图鉴」，验证 toast 层级
            if ProcessInfo.processInfo.environment["WA_PREVIEW_TOAST"] == "1" {
                waAfter(1.6) {
                    guard showCard, !hasCollected else { return }
                    collectCard()
                }
            }
            #if DEBUG
            // 拍照 + EXIF 自检：`WA_PREVIEW_PHOTO=ok|nogps|far`，配合 `WA_PREVIEW_COLLECT=1`
            let env = ProcessInfo.processInfo.environment
            if let scenario = env["WA_PREVIEW_PHOTO"] {
                waAfter(2.4) {
                    guard let place, let data = PhotoTestData.make(scenario: scenario, target: place.coordinate) else { return }
                    handleCheckInPhotoData(data)
                    if env["WA_PREVIEW_COLLECT"] == "1" {
                        waAfter(0.45) { collectCard() }
                    }
                }
            }
            #endif
        }
    }

    // MARK: - 第一段：开盒

    private var openingStage: some View {
        ZStack {
            revealStageBackground

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            WATheme.amber.opacity(lightOn ? 0.50 : 0.0),
                            WATheme.amber.opacity(0.0)
                        ],
                        center: .center,
                        startRadius: 2,
                        endRadius: 210
                    )
                )
                .frame(width: 400, height: 400)
                .blur(radius: 10)

            VStack(spacing: 26) {
                ZStack {
                    particles

                    // 盒盖
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(WAKraft.boxLid)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(WATheme.ink.opacity(0.9), lineWidth: 1.8)
                        )
                        .frame(width: 156, height: 35)
                        .rotationEffect(.degrees(lidUp ? -26 : 0))
                        .offset(x: lidUp ? 36 : 0, y: lidUp ? -148 : -38)

                    // 盒体
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(WAKraft.boxBody)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(WATheme.ink.opacity(0.9), lineWidth: 1.8)
                        )
                        .overlay(
                            Text("?")
                                .font(.system(size: 50, weight: .bold))
                                .foregroundStyle(WATheme.ink)
                        )
                        .frame(width: 140, height: 92)
                        .offset(y: 26)
                }
                .frame(height: 246)
                .rotationEffect(.degrees(boxShake ? 6 : -6))

                Text("这次，城市选了这个地方。")
                    .font(.system(size: 14))
                    .tracking(0.3)
                    .foregroundStyle(WATheme.cream.opacity(lightOn ? 0.92 : 0.62))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            .padding(.bottom, 40)
        }
    }

    /// 纸屑粒子：固定 12 个方向，开盒瞬间向外飞再淡出
    private var particles: some View {
        ZStack {
            ForEach(0..<12, id: \.self) { index in
                particle(index: index)
            }
        }
    }

    private func particle(index: Int) -> some View {
        let angle = Double(index) / 12.0 * Double.pi * 2.0
        let distance = 100.0 + Double(index % 3) * 28.0
        let factor = particlesOut ? 1.0 : 0.12
        let diameter = 4.0 + Double(index % 3) * 2.0

        return RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(index % 2 == 0 ? WATheme.amber : WATheme.ember)
            .frame(width: CGFloat(diameter), height: CGFloat(diameter * 1.4))
            .offset(
                x: CGFloat(cos(angle) * distance * factor),
                y: CGFloat(sin(angle) * distance * factor)
            )
            .rotationEffect(.degrees(particlesOut ? Double(index) * 30 : 0))
            .opacity(particlesFade ? 0.0 : (particlesOut ? 1.0 : 0.0))
    }

    // MARK: - 第二段：卡片

    private var cardStage: some View {
        ZStack {
            // web 里揭晓卡始终浮在深色舞台上（与开盒阶段同一个底）
            revealStageBackground

            if let place = place {
                VStack(spacing: 0) {
                    stageBar
                    GeometryReader { geo in
                        ScrollView(showsIndicators: false) {
                            VStack(spacing: 0) {
                                revealCard(place)
                                Text("这个地点，只为你亮一次。")
                                    .font(.system(size: 12))
                                    .tracking(0.6)
                                    .foregroundStyle(WATheme.cream.opacity(0.42))
                                    .padding(.top, 14)
                            }
                            .padding(.horizontal, 26)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: geo.size.height, alignment: .center)
                        }
                    }
                }
            } else {
                WAEmptyState(title: "今晚的盲盒还没准备好。", showsArt: false)
            }
        }
    }

    private var revealStageBackground: some View {
        RadialGradient(
            colors: [
                Color.waMix(WATheme.ink, WATheme.amberDeep, 0.16),
                Color.waMix(WATheme.ink, WATheme.amberDeep, 0.06),
                WATheme.ink
            ],
            center: UnitPoint(x: 0.5, y: 0.26),
            startRadius: 12,
            endRadius: 460
        )
        .ignoresSafeArea()
    }

    /// 顶栏：左计时，右关闭（web .reveal-stage__bar）
    private var stageBar: some View {
        HStack {
            TimelineView(.periodic(from: Date(), by: 20)) { context in
                Text(WAFormat.clock(seconds: elapsed(context.date)))
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(WATheme.cream.opacity(0.92))
            }

            Spacer(minLength: 0)

            // 只有调用方提供了真正的「收起」时才显示关闭：
            // 否则按下去会跳到图鉴，反而是误导性的假按钮。
            if let onClose {
                Button {
                    guard !isCollecting else { return }
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(WATheme.cream.opacity(0.72))
                        .frame(width: 30, height: 30)
                        .background(WATheme.cream.opacity(0.08))
                        .clipShape(Circle())
                        .overlay(Circle().stroke(WATheme.cream.opacity(0.14), lineWidth: 1))
                }
                .buttonStyle(WAPressEffectStyle())
                .accessibilityLabel("关闭揭晓")
            }
        }
        .padding(.horizontal, WATheme.pagePadding)
        .frame(height: 46)
    }

    private func revealCard(_ place: Place) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Text(serialText)
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(1)
                    .monospacedDigit()
                    .foregroundStyle(WATheme.ink3)

                Spacer(minLength: 8)

                if isCurated {
                    curatedTag
                }
                WARarityBadge(rarity: place.rarity)
            }
            .padding(.bottom, 13)

            // 编辑精选的实景照片（后台策展数据里带的 photoUrl）
            // 只在揭晓页展示；加载失败时静默降级，不出现破图/红字。
            if let info = curatedInfo, let url = info.photoURL {
                curatedPhoto(url: url, credit: info.photoCredit)
                    .padding(.bottom, 12)
            }

            // 到达时的实拍：这是「我真的来过」的证据，也是这张卡最私人化的一层
            checkInPhotoSection(place)
                .padding(.bottom, 12)

            VStack(spacing: 7) {
                if curatedInfo?.photoURL == nil {
                    Text(place.emoji)
                        .font(.system(size: 46))
                }
                Text(place.name)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(WATheme.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(WAFormat.areaName(place.area)) · \(place.category)")
                    .font(.system(size: 12.5))
                    .tracking(0.8)
                    .foregroundStyle(WATheme.ink3)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 11)

            WAHairline()

            VStack(alignment: .leading, spacing: 6) {
                WAMicroLabel("为什么是这里：")
                Text(place.why)
                    .font(.system(size: 14))
                    .foregroundStyle(WATheme.ink2)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 12)

            WAHairline()

            taskCard(place)
                .padding(.top, 12)

            buttons
                .padding(.top, 14)

            if hasCollected {
                Text("它现在是你的了。")
                    .font(.system(size: 12))
                    .tracking(0.5)
                    .foregroundStyle(WATheme.ink3)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 9)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 17)
        .padding(.bottom, 18)
        .background(WATheme.paper)
        .clipShape(RoundedRectangle(cornerRadius: WATheme.cardRadius, style: .continuous))
        .shadow(color: WATheme.ink.opacity(0.30), radius: 32, x: 0, y: 20)
        .rotationEffect(.degrees(-1.2))
        .scaleEffect(isCollecting ? 0.26 : 1)
        .opacity(isCollecting ? 0 : 1)
        .offset(y: isCollecting ? 250 : 0)
    }

    private var curatedTag: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
            Text("编辑精选")
                .font(.system(size: 11.5, weight: .bold))
                .tracking(0.6)
        }
        .foregroundStyle(WATheme.amberDeep)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(WATheme.amber.opacity(0.14))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(WATheme.amber.opacity(0.40), lineWidth: 1))
        .accessibilityLabel("编辑精选地点")
    }

    /// 实景照片：16:9 左右的纸卡，左上角「编辑精选」，下方图片来源署名。
    @ViewBuilder
    private func curatedPhoto(url: URL, credit: String?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .topLeading) {
                AsyncImage(url: url, transaction: Transaction(animation: WAAnimation.regular)) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        photoPlaceholder(showProgress: false)
                    case .empty:
                        photoPlaceholder(showProgress: true)
                    @unknown default:
                        photoPlaceholder(showProgress: false)
                    }
                }
                .frame(height: 172)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(WATheme.line, lineWidth: 1)
                )
                .accessibilityLabel("编辑精选地点实景照片")

                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                    Text("编辑精选")
                        .font(.system(size: 11.5, weight: .bold))
                        .tracking(0.6)
                }
                .foregroundStyle(WATheme.ink)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(WATheme.amber)
                .clipShape(Capsule())
                .padding(10)
            }

            if let credit, !credit.isEmpty {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Text("图片：\(credit)")
                        .font(.system(size: 11))
                        .foregroundStyle(WATheme.ink3)
                }
                .padding(.trailing, 2)
            }
        }
    }

    private func photoPlaceholder(showProgress: Bool) -> some View {
        ZStack {
            WATheme.paper2
            if showProgress {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(WATheme.ink3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func taskCard(_ place: Place) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 3) {
                    Text("🎯").font(.system(size: 12))
                    WAMicroLabel("小任务：")
                }
                Text(place.task)
                    .font(.system(size: 13.5))
                    .foregroundStyle(WATheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button {
                guard !isCollecting else { return }
                taskDone.toggle()
                WAHaptics.light()
            } label: {
                Text(taskDone ? "已完成" : "完成后点一下")
                    .font(.system(size: 11.5))
                    .foregroundStyle(taskDone ? WATheme.teal : WATheme.ink3)
                    .padding(.top, 1)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WATheme.paper2)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(WATheme.line, lineWidth: 1)
        )
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Button(action: collectCard) {
                Text(hasCollected ? "去看看图鉴" : "收进图鉴")
                    .font(WAType.cta(14))
                    .foregroundStyle(WATheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(WATheme.amber)
                    .clipShape(Capsule())
                    .shadow(color: WATheme.amberDeep.opacity(0.28), radius: 12, x: 0, y: 6)
            }
            .buttonStyle(WAPressEffectStyle())
            .disabled(isCollecting)
            .layoutPriority(1.45)

            Button(action: shareToCircle) {
                Text(hasShared ? "已分享" : "分享")
                    .font(WAType.cta(14))
                    .foregroundStyle(WATheme.ink2)
                    .lineLimit(1)
                    .frame(width: 96)
                    .frame(height: 46)
                    .overlay(Capsule().stroke(WATheme.line, lineWidth: 1))
            }
            .buttonStyle(WAPressEffectStyle())
            .disabled(isCollecting || hasShared)
        }
    }

    // MARK: - 到达实拍（拍照上传）

    @ViewBuilder
    private func checkInPhotoSection(_ place: Place) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image = checkInImage {
                ZStack(alignment: .topLeading) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 168)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(WATheme.line, lineWidth: 1)
                        )

                    Text("你拍的")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(WATheme.ink.opacity(0.62))
                        .clipShape(Capsule())
                        .padding(10)
                }

                HStack(spacing: 10) {
                    Button {
                        showCamera = true
                    } label: {
                        Label("重拍", systemImage: "camera.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(WATheme.ink2)
                    }
                    .buttonStyle(.plain)

                    PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                        Label("换一张", systemImage: "photo.on.rectangle")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(WATheme.ink2)
                    }

                    Spacer(minLength: 0)

                    Text(uploadStatusText)
                        .font(.system(size: 11))
                        .foregroundStyle(checkInRemotePath != nil ? WATheme.teal : WATheme.ink3)
                }
            } else {
                HStack(spacing: 10) {
                    Button {
                        showCamera = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 13, weight: .semibold))
                            Text("拍一张 · 记下这一刻")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(WATheme.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(WATheme.amberSoft)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(WATheme.amber.opacity(0.35),
                                              style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        )
                    }
                    .buttonStyle(WAPressEffectStyle())

                    PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(WATheme.ink2)
                            .frame(width: 44, height: 44)
                            .background(WATheme.paper2)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(WATheme.line, lineWidth: 1)
                            )
                    }
                    .accessibilityLabel("从相册选择照片")
                }
            }

            if let status = photoGpsStatusText {
                Text(status)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(photoGpsStatusColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var uploadStatusText: String {
        if isUploadingPhoto { return "上传中…" }
        if checkInRemotePath != nil { return "已上传 · 换机可找回" }
        return AccountService.shared.isLoggedIn ? "仅存本机（稍后可再上传）" : "仅存本机 · 登录后可同步"
    }

    private func loadExistingCheckInPhoto() {
        guard let place, checkInImage == nil else { return }
        guard let photo = store.cardPhoto(for: place.id) else { return }
        checkInPhotoName = photo.local
        checkInRemotePath = photo.remote
        if let name = photo.local {
            checkInImage = PhotoLibraryService.load(named: name)
        }
    }

    /// 相册选中的**原始 Data**：先读 EXIF GPS，再压缩/落盘（重编码会丢 EXIF）
    private func handleCheckInPhotoData(_ data: Data) {
        guard let image = UIImage(data: data) else {
            photoGpsResult = .failed(reason: .notImage)
            photoGpsVerified = false
            photoGpsDistance = nil
            return
        }
        handleCheckInPhoto(image, data: data)
    }

    /// 拍完 / 选完：先读 EXIF 验证到达，再做落本机/上传
    private func handleCheckInPhoto(_ image: UIImage, data: Data? = nil) {
        checkInImage = image

        if let data {
            let result = PhotoGps.read(from: data)
            photoGpsResult = result
            if let target = place?.coordinate {
                let verification = PhotoGps.verify(target: target, photo: result)
                photoGpsDistance = verification.distance
                photoGpsVerified = verification.ok
            } else {
                // 演示 / 内置地点没有真实坐标 → 不参与到达验证
                photoGpsDistance = nil
                photoGpsVerified = false
            }
        } else {
            // UIImagePickerController 的 UIImage 通常已丢 EXIF（相机路径会提示重拍/选相册）
            photoGpsResult = .failed(reason: .noExif)
            photoGpsVerified = false
            photoGpsDistance = nil
        }

        if let name = try? PhotoLibraryService.save(image) {
            checkInPhotoName = name
        }
        if let place {
            store.attachCardPhoto(placeID: place.id, photoName: checkInPhotoName, remotePath: nil)
        }
        WAHaptics.light()
        uploadCheckInPhotoIfPossible(image)
    }

    private var photoGpsStatusText: String? {
        guard let result = photoGpsResult else { return nil }
        switch result {
        case .ok:
            guard let distance = photoGpsDistance else { return "照片位置已验证" }
            if photoGpsVerified {
                return "位置已验证 · 距目的地 \(Int(distance.rounded())) 米"
            }
            return PhotoGps.tooFarText(distance: distance)
        case .failed(let reason):
            return PhotoGps.reasonText(reason)
        }
    }

    private var photoGpsStatusColor: Color {
        if photoGpsVerified { return WATheme.teal }
        if photoGpsResult?.failure != nil || !photoGpsVerified { return WATheme.ember }
        return WATheme.ink3
    }

    private func uploadCheckInPhotoIfPossible(_ image: UIImage) {
        guard let place else { return }
        guard AccountService.shared.isLoggedIn else { return }
        guard let dataURL = PhotoLibraryService.checkInDataURL(image) else { return }
        isUploadingPhoto = true
        Task { @MainActor in
            let path = await AccountService.shared.uploadCheckInPhoto(placeID: place.id, dataURL: dataURL)
            isUploadingPhoto = false
            guard let path else {
                appendToast(WAToast(text: "照片已存本机，上传失败（网络或登录状态）", icon: "icloud.slash", tint: WATheme.ember))
                return
            }
            checkInRemotePath = path
            store.attachCardPhoto(placeID: place.id, photoName: checkInPhotoName, remotePath: path)
            appendToast(WAToast(text: "照片已上传到账号", icon: "checkmark.icloud", tint: WATheme.teal))
        }
    }

    // MARK: - Toast（贴底堆叠；成就 toast 用琥珀变体）

    private var toastLayer: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            ForEach(toasts) { toast in
                WAToastView(toast: toast) {
                    withAnimation(WAAnimation.quick) {
                        toasts.removeAll { $0.id == toast.id }
                    }
                }
                .id(toast.id)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, WATheme.pagePadding)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(WAAnimation.regular, value: toasts.map(\.id))
        .allowsHitTesting(false)
    }

    private func appendToast(_ toast: WAToast) {
        withAnimation(WAAnimation.regular) {
            toasts.append(toast)
        }
    }

    // MARK: - 动画时序

    private func elapsed(_ date: Date) -> TimeInterval {
        guard let startedAt = store.session?.startedAt else { return 0 }
        return date.timeIntervalSince(startedAt)
    }

    private func startOpening() {
        guard !didStart else { return }
        didStart = true
        WAHaptics.success()

        if reduceMotion {
            store.beginReveal()
            withAnimation(WAAnimation.regular) {
                showCard = true
            }
            return
        }

        // 盒子抖动 600ms（±6° 三次）
        withAnimation(.easeInOut(duration: 0.10).repeatCount(6, autoreverses: true)) {
            boxShake = true
        }

        // 盒盖弹开 + 暖光 + 纸屑
        waAfter(0.7) {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.65)) {
                lidUp = true
                lightOn = true
                particlesOut = true
            }
            waAfter(0.35) {
                withAnimation(WAAnimation.slow) {
                    particlesFade = true
                }
            }
        }

        // 1.2s 后切到卡片
        waAfter(1.2) {
            store.beginReveal()
            withAnimation(WAAnimation.slow) {
                showCard = true
            }
        }
    }

    // MARK: - 收进图鉴

    private func collectCard() {
        guard !isCollecting else { return }

        if hasCollected {
            dismissReveal()
            return
        }

        // 真实地点必须「拍照 + EXIF GPS ≤120m」才能收集；演示/无坐标地点跳过（保持旧行为）
        if let targetPlace = place, targetPlace.coordinate != nil, !photoGpsVerified {
            let issue: PhotoVerifyIssue
            if let result = photoGpsResult, case .ok = result, let distance = photoGpsDistance {
                issue = .tooFar(distance)
            } else if let failure = photoGpsResult?.failure {
                issue = .gps(failure)
            } else {
                issue = .needsPhoto
            }
            photoVerifyPrompt = PhotoVerifyPrompt(issue: issue)
            return
        }

        guard let result = store.collect() else {
            appendToast(WAToast(text: "这张卡已经在图鉴里了。", icon: "checkmark.seal"))
            return
        }

        hasCollected = true
        WAHaptics.success()

        // 把到达实拍挂到这张卡上（先拍后收 / 先收后拍都覆盖得到）
        if let place, checkInPhotoName != nil || checkInRemotePath != nil || photoGpsResult != nil {
            store.attachCardPhoto(
                placeID: place.id,
                photoName: checkInPhotoName,
                remotePath: checkInRemotePath,
                photoGps: photoGpsResult?.gps,
                photoDistance: photoGpsDistance
            )
        }

        // 卡片缩小飞向 Tab 图鉴，飞完再落回原位（web 同款：卡片留在原地并显示「它现在是你的了」）
        withAnimation(WAAnimation.openBox) {
            isCollecting = true
        }
        waAfter(0.62) {
            withAnimation(WAAnimation.slow) {
                isCollecting = false
            }
        }

        appendToast(WAToast(text: "已收录 · 惊喜值 +\(result.xpGained)", icon: "sparkles"))

        // 成就 toast 延后 600ms（web 640ms）
        if let achievement = result.newAchievements.first {
            waAfter(0.64) {
                appendToast(
                    WAToast(
                        text: "成就解锁 · \(achievement.name)",
                        icon: achievement.icon,
                        isAmber: true
                    )
                )
            }
        }

        // 不自动关：与 web 一致，收进图鉴后卡片停留并显示「它现在是你的了」，
        // toast 完整播完；用户点「去看看图鉴」或右上角关闭再返回。
        lastCollectedResult = result
    }

    private func dismissReveal() {
        guard !isCollecting else { return }
        if let lastCollectedResult {
            onCollected(lastCollectedResult)
            return
        }
        onCollected(
            CollectResult(
                card: store.card(for: place?.id ?? "") ?? PlaceCard(
                    placeID: place?.id ?? "",
                    serial: "",
                    collectedAt: Date(),
                    taskDone: taskDone
                ),
                xpGained: 0,
                newAchievements: []
            )
        )
    }

    // MARK: - 分享到圈子

    private func shareToCircle() {
        guard !isCollecting, !hasShared else { return }
        guard let place = place else { return }

        let caption = "今晚捡到一个地方：\(place.name)。"
        _ = store.share(caption: caption)
        hasShared = true
        WAHaptics.light()

        appendToast(WAToast(text: "已分享到圈子", icon: "paperplane.fill", tint: WATheme.teal))
    }
}

// MARK: - 拍照到达验证失败弹层

enum PhotoVerifyIssue {
    case needsPhoto
    case gps(PhotoGpsFailure)
    case tooFar(Double)

    var title: String {
        switch self {
        case .needsPhoto: return "先拍一张带位置信息的照片"
        case .gps(let reason): return PhotoGps.reasonText(reason)
        case .tooFar: return "拍摄地点离目的地太远"
        }
    }

    var message: String {
        switch self {
        case .needsPhoto:
            return "到达验证需要照片本身带 GPS：请用手机相机拍一张（不要用截图），或从相册选择一张原图。"
        case .gps(let reason):
            return PhotoGps.reasonHowto(reason)
        case .tooFar(let distance):
            return PhotoGps.tooFarText(distance: distance)
        }
    }
}

struct PhotoVerifyPrompt: Identifiable {
    let id = UUID()
    let issue: PhotoVerifyIssue
}

struct PhotoVerificationSheet: View {

    let issue: PhotoVerifyIssue
    var onRetry: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "camera.metering.unknown")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(WATheme.ember)
                    Text(issue.title)
                        .font(.headline)
                        .foregroundStyle(WATheme.ink)
                }

                Text(issue.message)
                    .font(.body)
                    .foregroundStyle(WATheme.ink2)
                    .fixedSize(horizontal: false, vertical: true)

                Text("验证规则：照片 EXIF 里的拍摄点与目的地直线距离 ≤ \(Int(PhotoGps.radiusMeters)) 米。")
                    .font(.caption)
                    .foregroundStyle(WATheme.ink3)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    dismiss()
                    onRetry()
                } label: {
                    Text("重新拍一张 / 换一张")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(WATheme.paper)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(WATheme.amberDeep)
                        .clipShape(Capsule())
                }
                .buttonStyle(WAPressEffectStyle())

                Button("先不收集") {
                    dismiss()
                }
                .font(.subheadline)
                .foregroundStyle(WATheme.ink3)
                .frame(maxWidth: .infinity)

                Spacer(minLength: 0)
            }
            .padding(20)
            .background(WATheme.cream)
            .navigationTitle("到达验证")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - 自检用 EXIF 测试图（仅 DEBUG；运行时用 ImageIO 写入真实 EXIF）

#if DEBUG
enum PhotoTestData {

    /// scenario: ok | nogps | far | noexif
    static func make(scenario: String, target: GeoPoint?) -> Data? {
        let base = target ?? GeoPoint(latitude: 31.2330, longitude: 121.4710)
        switch scenario {
        case "ok":
            let p = GeoMath.offset(from: base, meters: 20, bearingDegrees: 30)
            return jpeg(lat: p.latitude, lon: p.longitude, includeExif: true)
        case "far":
            let p = GeoMath.offset(from: base, meters: 500, bearingDegrees: 20)
            return jpeg(lat: p.latitude, lon: p.longitude, includeExif: true)
        case "nogps":
            return jpeg(lat: nil, lon: nil, includeExif: true)
        default:
            return jpeg(lat: nil, lon: nil, includeExif: false)
        }
    }

    private static func jpeg(lat: Double?, lon: Double?, includeExif: Bool) -> Data? {
        let size = CGSize(width: 240, height: 240)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let cg = context.cgContext
            cg.setFillColor(UIColor(WATheme.paper2).cgColor)
            cg.fill(CGRect(origin: .zero, size: size))
            cg.setFillColor(UIColor(WATheme.amber).cgColor)
            cg.fillEllipse(in: CGRect(x: 60, y: 50, width: 120, height: 120))
            cg.setFillColor(UIColor(WATheme.ink).withAlphaComponent(0.65).cgColor)
            cg.fill(CGRect(x: 0, y: 190, width: size.width, height: 50))
        }
        guard let cgImage = image.cgImage else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }

        var properties: [CFString: Any] = [:]
        if includeExif {
            properties[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifDateTimeOriginal: "2026:11:20 15:00:00"
            ] as [CFString: Any]
        }
        if let lat, let lon {
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: abs(lat),
                kCGImagePropertyGPSLatitudeRef: lat >= 0 ? "N" : "S",
                kCGImagePropertyGPSLongitude: abs(lon),
                kCGImagePropertyGPSLongitudeRef: lon >= 0 ? "E" : "W"
            ] as [CFString: Any]
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
#endif
