import SwiftUI

// MARK: - App 入口

@main
struct WalkaholicApp: App {

    /// 正式版默认走真实路径（从 UserDefaults 读回 Profile）；
    /// 只有带 `WA_PREVIEW` 的截图/走查模式才预置演示数据。
    private static var usesDemoData: Bool {
        !(ProcessInfo.processInfo.environment["WA_PREVIEW"] ?? "").isEmpty
    }

    @State private var store: WalkaholicStore = WalkaholicApp.makeStore()

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
                .preferredColorScheme(.light) // MVP 仅浅色（design-system §8）
        }
    }

    /// 真实的 init 路径保留在这里：不依赖任何演示数据。
    private static func makeStore() -> WalkaholicStore {
        if usesDemoData {
            let preview = ProcessInfo.processInfo.environment["WA_PREVIEW"] ?? ""
            // 疆域截图：先在真实地点目录里放 5 个上海真实 POI（不是虚构地点），
            // 让 Profile 的卡片与 CityMap 的多边形都有数据。仅 preview 模式调用。
            let previewEnv = ProcessInfo.processInfo.environment
            let seededPlaces = (preview == "profile" || preview.hasPrefix("territory"))
                ? seedTerritoryDemoPlaces(cappedMode: previewEnv["WA_PREVIEW_TERRITORY_CAPPED"] == "1")
                : []
            let store = WalkaholicStore.demo()
            if !seededPlaces.isEmpty {
                ensureTerritoryCards(store: store, places: seededPlaces)
            }
            if preview == "reveal" {
                _ = store.arriveNow()
                store.beginReveal()
            }
            // 真实定位链路自检：以当前（模拟器）定位为起点抽一个真实坐标的盲盒
            if preview == "live" {
                store.lastKnownOrigin = GeoPoint(latitude: 31.2304, longitude: 121.4737)
                _ = store.startQuest()
            }
            // 三端对齐自检：真实地点 + 迷雾路径（`WA_PREVIEW=parity`）
            if preview == "parity" {
                let origin = GeoPoint(latitude: 31.2304, longitude: 121.4737)
                let target = GeoPoint(latitude: 31.2330, longitude: 121.4710) // 人民公园（真实 POI，路线适合展示迷雾）
                store.lastKnownOrigin = origin
                let poi = POICandidate(
                    id: "amap-demo-museum",
                    name: "人民公园",
                    coordinate: target,
                    address: "黄浦区 · 人民公园",
                    category: .park,
                    source: "amap"
                )
                let place = RealPlaceFactory.scrub(RealPlaceFactory.makePlace(
                    from: poi, origin: origin, mood: .drift, hour: 10, startMeters: 480
                ))
                // 不依赖 PlaceDirectory 抽盒：模拟器冷装时目录是空的，startQuest 会返回 nil，
                // 截图走查就只剩「没有正在走的盲盒」空态（此前 parity 一直截不到导航页）。
                let distance = max(Double(QuestSession.arriveThreshold + 1), GeoMath.distance(from: origin, to: target))
                let total = max(Int(distance.rounded()), QuestSession.arriveThreshold + 1)
                let bearing = GeoMath.bearing(from: origin, to: target)
                store.session = QuestSession(
                    placeID: place.id,
                    totalMeters: total,
                    remainingMeters: total,
                    phase: .walking,
                    unlockedHintCount: 1,
                    target: target,
                    currentBearing: bearing
                )
                store.currentPlace = place
                PlaceDirectory.shared.remember(place)
                _ = store.updateLocation(distanceMeters: Double(total), bearingDegrees: bearing)
            }
            // 拍照 + EXIF GPS 到达验证自检：`WA_PREVIEW=photo-verify`
            // 配 `WA_PREVIEW_PHOTO=ok|nogps|far` + `WA_PREVIEW_COLLECT=1` 截三种结果
            if preview == "photo-verify" {
                let target = GeoPoint(latitude: 31.2330, longitude: 121.4710) // 人民公园（真实坐标）
                let poi = POICandidate(
                    id: "photo-verify-park",
                    name: "人民公园",
                    coordinate: target,
                    address: "黄浦区 · 人民公园",
                    category: .park,
                    source: "curated"
                )
                let place = RealPlaceFactory.scrub(RealPlaceFactory.makePlace(
                    from: poi,
                    origin: GeoPoint(latitude: 31.2304, longitude: 121.4737),
                    mood: .drift,
                    hour: 10,
                    startMeters: 480
                ))
                PlaceDirectory.shared.remember(place)
                store.session = QuestSession(
                    placeID: place.id,
                    totalMeters: 480,
                    remainingMeters: 0,
                    phase: .arrived,
                    unlockedHintCount: 3,
                    target: target,
                    currentBearing: nil
                )
                store.currentPlace = place
                store.reveal = Reveal(place: place, xpGained: 40 + place.rarity.xpBonus)
            }
            // 真实 POI 自检：用内置的一条真实 POI 直接建旅程（不走 MapKit，离线可复现）
            if preview == "realquest" {
                let origin = GeoPoint(latitude: 31.2304, longitude: 121.4737)
                store.lastKnownOrigin = origin
                _ = store.startQuest(origin: origin)
                let poi = POICandidate(
                    id: "apple-demo-1",
                    name: "南京东路的一家咖啡窗口",
                    coordinate: GeoMath.offset(from: origin, meters: 320, bearingDegrees: 45),
                    address: "黄浦区 · 南京东路",
                    category: .cafe,
                    source: "apple"
                )
                let realPlace = RealPlaceFactory.scrub(RealPlaceFactory.makePlace(
                    from: poi, origin: origin, mood: .drift, hour: 9, startMeters: 480
                ))
                store.session?.target = realPlace.coordinate
                store.currentPlace = realPlace
            }
            return store
        }
        let persistence = UserDefaultsProfileStore()
        let profile = persistence.loadProfile() ?? Profile()
        return WalkaholicStore(profile: profile, persistence: persistence)
    }

    // MARK: 疆域截图种子（仅 preview，真实坐标）

    private static func seedTerritoryDemoPlaces(cappedMode: Bool = false) -> [Place] {
        let origin = GeoPoint(latitude: 31.2304, longitude: 121.4737)
        // 点数门槛截图：4 个点围出 >0.3km² 的边界，但点数不够 → 被卡在下一档
        let cappedSeeds: [(id: String, name: String, lat: Double, lon: Double, category: RealPlaceCategory, address: String)] = [
            ("territory-demo-square", "人民广场", 31.2304, 121.4737, .plaza, "黄浦区 · 人民广场"),
            ("territory-demo-nanjing", "南京东路步行街", 31.2355, 121.4800, .plaza, "黄浦区 · 南京东路"),
            ("territory-demo-bund", "外滩", 31.2400, 121.4900, .river, "黄浦区 · 中山东一路"),
            ("territory-demo-yuyuan", "豫园", 31.2270, 121.4920, .garden, "黄浦区 · 豫园")
        ]
        let normalSeeds: [(id: String, name: String, lat: Double, lon: Double, category: RealPlaceCategory, address: String)] = [
            ("territory-demo-park", "人民公园", 31.2330, 121.4710, .park, "黄浦区 · 人民公园"),
            ("territory-demo-museum", "上海博物馆", 31.230278, 121.470556, .museum, "黄浦区 · 人民大道 201 号"),
            ("territory-demo-concert", "上海音乐厅", 31.228889, 121.473333, .venue, "黄浦区 · 延安东路 523 号"),
            ("territory-demo-square", "人民广场", 31.229564, 121.47438, .plaza, "黄浦区 · 人民广场"),
            ("territory-demo-nanjing", "南京东路步行街", 31.2355, 121.4800, .plaza, "黄浦区 · 南京东路")
        ]
        let seeds = cappedMode ? cappedSeeds : normalSeeds
        if cappedMode {
            // 预览专用：清掉历史目录，确保只有 4 个点（否则之前截图留下的点会让门槛不触发）
            PlaceDirectory.shared.removeAll()
        }
        var places: [Place] = []
        for seed in seeds {
            let candidate = POICandidate(
                id: seed.id,
                name: seed.name,
                coordinate: GeoPoint(latitude: seed.lat, longitude: seed.lon),
                address: seed.address,
                category: seed.category,
                source: "curated"
            )
            let place = RealPlaceFactory.scrub(RealPlaceFactory.makePlace(
                from: candidate, origin: origin, mood: .drift, hour: 10, startMeters: 480
            ))
            PlaceDirectory.shared.remember(place)
            places.append(place)
        }
        return places
    }

    private static func ensureTerritoryCards(store: WalkaholicStore, places: [Place]) {
        let existing = Set(store.profile.cards.map(\.placeID))
        var cards = store.profile.cards
        for (index, place) in places.enumerated() where !existing.contains(place.id) {
            cards.append(PlaceCard(
                placeID: place.id,
                serial: String(format: "T%04d", 700 + index * 13),
                collectedAt: Date().addingTimeInterval(-Double(index + 1) * 86_400)
            ))
        }
        store.profile.cards = cards
        store.profile.boxesOpened = max(store.profile.boxesOpened, cards.count)
    }
}

// MARK: - 底部 Tab

enum AppTab: Hashable {
    case home
    case cards
    case social
    case profile
}

// MARK: - 根视图
// 4 个 Tab：今日 / 图鉴 / 圈子 / 我的（design-system §4）。
// 旅程与揭晓用 fullScreenCover 全屏承载，盖住 Tab。

struct RootView: View {
    let store: WalkaholicStore

    /// 是否处于「演示 / 截图」运行：这种模式下不连账号、不上传、不写真实存档
    static var isPreviewRun: Bool {
        !(ProcessInfo.processInfo.environment["WA_PREVIEW"] ?? "").isEmpty
    }

    @State private var selectedTab: AppTab = .home
    @State private var isSetupPresented = false
    @State private var isJourneyPresented = false

    /// iPhone → Apple Watch 同步（Shared/Core/WatchSessionSummary 共用 Schema）。
    /// 与 RootView 同层持有，全 App 只有这一个实例。
    @State private var watchSync = WatchSyncService()
    @Environment(\.scenePhase) private var scenePhase

    /// 仅用于截图/演示：SIMCTL_CHILD_WA_PREVIEW=journey|reveal|cards|social|profile
    private let previewScreen: String

    init(store: WalkaholicStore) {
        self.store = store
        let preview = ProcessInfo.processInfo.environment["WA_PREVIEW"] ?? ""
        self.previewScreen = preview
        let tab: AppTab
        switch preview {
        case "cards": tab = .cards
        case "social": tab = .social
        case "profile": tab = .profile
        default: tab = .home
        }
        _selectedTab = State(initialValue: tab)
        _isJourneyPresented = State(initialValue: ["journey", "reveal", "live", "realquest", "parity", "photo-verify"].contains(preview))
    }

    var body: some View {
        coreTabs
            .tint(WATheme.amberDeep)
            .toolbarBackground(WATheme.paper, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
            .sheet(isPresented: $isSetupPresented) { setupSheet }
            .fullScreenCover(isPresented: $isJourneyPresented) { journeyCover }
            .onAppear(perform: activateWatchSync)
            .onAppear {
                Task {
                    // 演示/截图模式下不连账号、不上传：演示数据绝不能进生产库
                    guard !Self.isPreviewRun else { return }
                    await AccountService.shared.refresh()
                    uploadPendingSurprises()
                    // 冷启动先拿一次定位：图鉴的距离、「去探秘」、抽盒都要用它
                    await LocationBootstrap.seedIfNeeded(store)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                watchSync.forceSync(store: store)
            }
            .onChange(of: store.session?.placeID ?? "") { _, _ in pushWatch() }
            .onChange(of: store.session?.remainingMeters ?? -1) { _, _ in pushWatch() }
            .onChange(of: store.session?.phase.rawValue ?? "") { _, _ in pushWatch() }
            .onChange(of: store.session?.unlockedHintCount ?? 0) { _, _ in pushWatch() }
            .onChange(of: store.profile.boxesOpened) { _, _ in pushWatch() }
            .onChange(of: store.profile.streakDays) { _, _ in pushWatch() }
    }

    // 拆成独立属性，避免 body 表达式过大导致 type-check 超时
    private var coreTabs: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                HomeView(
                    store: store,
                    onOpenSetup: { isSetupPresented = true },
                    onOpenJourney: { isJourneyPresented = true },
                    onOpenCards: { selectedTab = .cards }
                )
            }
            .tabItem { Label("今日", systemImage: "shippingbox") }
            .tag(AppTab.home)

            NavigationStack { CardsView(store: store) }
                .tabItem { Label("图鉴", systemImage: "rectangle.stack") }
                .tag(AppTab.cards)

            NavigationStack { SocialView(store: store) }
                .tabItem { Label("圈子", systemImage: "person.2") }
                .tag(AppTab.social)

            NavigationStack { ProfileView(store: store) }
                .tabItem { Label("我的", systemImage: "person.crop.circle") }
                .tag(AppTab.profile)
        }
    }

    private var setupSheet: some View {
        BoxSetupSheet(
            store: store,
            onStart: {
                // 先关 sheet，稍等 dismiss 动画结束再全屏推入旅程
                isSetupPresented = false
                waAfter(0.45) { isJourneyPresented = true }
            },
            onCancel: { isSetupPresented = false }
        )
    }

    private var journeyCover: some View {
        JourneyView(
            store: store,
            onClose: { isJourneyPresented = false },
            onCollected: { _ in
                // 收录完成：关闭旅程，切到图鉴页看新卡
                isJourneyPresented = false
                selectedTab = .cards
            }
        )
    }

    // MARK: 手表同步

    /// start(store:) = activateIfNeeded() + 立即推首帧。
    /// 只用 activateIfNeeded() 时，冷启动已有进行中旅程不会触发任何 onChange，
    /// 手表会永远停在它自己的本地演示数据上（sync-dev 实测：推送 0 次）。
    private func activateWatchSync() {
        watchSync.start(store: store)
        watchSync.onCheckIn = { date in
            // 手表上「轻点打卡」= 用户确认到达
            _ = store.arriveNow(now: date)
        }
    }

    private func pushWatch() {
        watchSync.sync(store: store)
    }

    // MARK: 补传（登录后 / 冷启动）

    /// 本机埋了但没上传成功的惊喜，在登录后自动补传，让它真的能被别人找到。
    private func uploadPendingSurprises() {
        Task { @MainActor in
            await SurpriseService.shared.flushPending(store: store)
            // 顺便收一次「被找到」的回执：红点不该等用户点进我的惊喜才出现
            await SurpriseService.shared.syncMine(store: store)
        }
    }
}
