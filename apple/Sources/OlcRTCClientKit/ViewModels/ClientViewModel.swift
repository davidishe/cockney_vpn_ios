import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit) && !canImport(UIKit)
import AppKit
#endif

private enum RunningMode {
    case localProxy
    #if os(iOS)
    case packetTunnel
    #endif
}

private let portConflictRetryAttempts = 10
private let portConflictRetryDelayNanoseconds: UInt64 = 200_000_000
private let linkWatchIntervalNanoseconds: UInt64 = 2_000_000_000
private let reconnectBackoffCapSeconds: Double = 30

private enum SubscriptionRefreshTrigger {
    case manual
    case automatic
}

private struct SubscriptionRefreshRequest {
    var id: UUID
    var sourceURL: URL
}

private struct AutomaticSubscriptionRefreshState {
    var id: UUID
    var sourceURL: URL
    var intervalSeconds: TimeInterval
    var lastFetchedAtUnix: TimeInterval?
}

private struct AutomaticSubscriptionRefreshConfiguration: Equatable {
    var id: UUID
    var sourceURL: String
    var intervalSeconds: TimeInterval
}

@MainActor
public final class ClientViewModel: ObservableObject {
    @Published public private(set) var profiles: [ConnectionProfile]
    @Published public var selectedProfileID: UUID?
    @Published public var draft: ConnectionProfile
    @Published public private(set) var status: ClientStatus = .stopped
    @Published public private(set) var logs: [String] = []
    @Published public var useSystemProxy: Bool {
        didSet {
            store.saveUseSystemProxy(useSystemProxy)
        }
    }
    @Published public var sendDiagnostics: Bool {
        didSet {
            store.saveSendDiagnostics(sendDiagnostics)
            DiagnosticLogUploader.shared.setEnabled(sendDiagnostics)
        }
    }
    @Published public var selectedNetworkService: String {
        didSet {
            store.saveSelectedNetworkService(selectedNetworkService)
        }
    }
    @Published public private(set) var networkServices: [String] = ["Wi-Fi"]
    @Published public private(set) var isImporting = false
    @Published public private(set) var importErrorMessage: String?
    @Published public private(set) var refreshingSubscriptionIDs: Set<UUID> = []
    @Published public private(set) var pingingProfileIDs: Set<UUID> = []
    @Published public private(set) var pingResults: [UUID: ProfilePingState] = [:]

    private let engine: OlcRTCEngine
    private let store: ProfileStore
    private let uriParser: OlcRTCURIParser
    private let subscriptionParser: OlcRTCSubscriptionParser
    private let subscriptionFetcher: SubscriptionFetcher
    private let profilePinger: any ProfilePinging
    private let systemProxyManager: SystemProxyManager
    #if os(iOS)
    private let packetTunnelManager = PacketTunnelManager()
    private let backgroundRuntimeKeeper = BackgroundRuntimeKeeper()
    #endif
    private var eventTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var linkWatchTask: Task<Void, Never>?
    private var wantsConnection = false
    private var reconnectAttempt = 0
    private var importTask: Task<Void, Never>?
    private var refreshTasks: [UUID: Task<Void, Never>] = [:]
    private var refreshTaskTokens: [UUID: UUID] = [:]
    private var automaticRefreshTasks: [UUID: Task<Void, Never>] = [:]
    private var automaticRefreshTaskTokens: [UUID: UUID] = [:]
    private var automaticRefreshConfigurations: [UUID: AutomaticSubscriptionRefreshConfiguration] = [:]
    private var automaticRefreshAttemptedAt: [UUID: Date] = [:]
    private var pingTasks: [UUID: Task<Void, Never>] = [:]
    private var subscriptionPingTasks: [UUID: Task<Void, Never>] = [:]
    private var runningMode: RunningMode?
    private var diagnosticSessionId: UUID?
    private var foregroundObserver: NSObjectProtocol?
    private let diagnosticUploader = DiagnosticLogUploader.shared

    public init(
        engine: OlcRTCEngine = OlcRTCEngineFactory.makeDefault(),
        store: ProfileStore = ProfileStore(),
        uriParser: OlcRTCURIParser = OlcRTCURIParser(),
        subscriptionParser: OlcRTCSubscriptionParser? = nil,
        subscriptionFetcher: SubscriptionFetcher = SubscriptionFetcher(),
        profilePinger: any ProfilePinging = ProfilePinger(),
        systemProxyManager: SystemProxyManager = SystemProxyManager()
    ) {
        self.engine = engine
        self.store = store
        self.uriParser = uriParser
        self.subscriptionParser = subscriptionParser ?? OlcRTCSubscriptionParser(uriParser: uriParser)
        self.subscriptionFetcher = subscriptionFetcher
        self.profilePinger = profilePinger
        self.systemProxyManager = systemProxyManager

        #if os(iOS)
        let defaultUseSystemProxy = false
        #else
        let defaultUseSystemProxy = true
        #endif
        let hasStoredUseSystemProxy = store.hasUseSystemProxyPreference()
        useSystemProxy = store.loadUseSystemProxy(defaultValue: defaultUseSystemProxy)
        sendDiagnostics = store.loadSendDiagnostics(defaultValue: true)
        selectedNetworkService = store.loadSelectedNetworkService()

        let storedProfiles = store.loadProfiles()
        var loadedProfiles = storedProfiles.map { $0.normalizedForCurrentDefaults() }
        loadedProfiles = Self.initializedSubscriptionFetchTimes(in: loadedProfiles, now: Date())
        if loadedProfiles != storedProfiles {
            store.saveProfiles(loadedProfiles)
        }
        let selected = store.loadSelectedProfileID()
        let initialProfile = loadedProfiles.first(where: { $0.id == selected }) ?? loadedProfiles.first

        profiles = loadedProfiles
        selectedProfileID = initialProfile?.id
        draft = initialProfile ?? .empty
        logs = DiagnosticJournal.shared.recentUILines()

        observeEngineEvents()
        loadNetworkServices()
        rescheduleAutomaticSubscriptionRefreshes()
        diagnosticUploader.setEnabled(sendDiagnostics)
        #if os(iOS)
        if !hasStoredUseSystemProxy {
            enableSystemVPNByDefaultIfAvailable()
        }
        #endif
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: {
                #if os(iOS)
                return UIApplication.willEnterForegroundNotification
                #else
                return NSApplication.didBecomeActiveNotification
                #endif
            }(),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleAppBecameActive()
            }
        }
    }

    deinit {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
        eventTask?.cancel()
        startTask?.cancel()
        importTask?.cancel()
        refreshTasks.values.forEach { $0.cancel() }
        automaticRefreshTasks.values.forEach { $0.cancel() }
        pingTasks.values.forEach { $0.cancel() }
        subscriptionPingTasks.values.forEach { $0.cancel() }
        #if os(iOS)
        Task { @MainActor [backgroundRuntimeKeeper] in
            backgroundRuntimeKeeper.stop()
        }
        #endif
    }

    public var selectedProfileName: String {
        guard selectedProfileID != nil else {
            return AppLocalization.string("No profile")
        }

        return draft.name.isEmpty ? AppLocalization.string("Untitled") : draft.name
    }

    public var canStart: Bool {
        selectedProfileID != nil && !status.isRunning && validationMessage == nil
    }

    public var validationMessage: String? {
        validate(profile: draft)
    }

    public func validationMessage(for profile: ConnectionProfile) -> String? {
        validate(profile: profile)
    }

    public func selectProfile(_ id: UUID?) {
        saveDraft()
        guard let id, let profile = profiles.first(where: { $0.id == id }) else {
            return
        }

        selectedProfileID = id
        draft = profile
        store.saveSelectedProfileID(id)
    }

    public func addProfile() {
        saveDraft()

        var profile = ConnectionProfile.empty
        profile.name = AppLocalization.format("Profile %d", profiles.count + 1)
        profiles.append(profile)
        selectedProfileID = profile.id
        draft = profile
        persistProfiles()
    }

    public func createProfile(_ profile: ConnectionProfile) {
        saveDraft()

        var newProfile = profile.normalizedForCurrentDefaults()
        newProfile.id = UUID()
        newProfile.subscription = nil
        if newProfile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            newProfile.name = AppLocalization.format("Profile %d", profiles.count + 1)
        }

        replacePlaceholderIfNeeded()
        profiles.append(newProfile)
        selectedProfileID = newProfile.id
        draft = newProfile
        persistProfiles()
    }

    public func deleteProfiles(at offsets: IndexSet) {
        let removedIDs = offsets.compactMap { profiles.indices.contains($0) ? profiles[$0].id : nil }
        for offset in offsets.sorted(by: >) {
            if profiles.indices.contains(offset) {
                profiles.remove(at: offset)
            }
        }
        store.deleteSecrets(profileIDs: removedIDs)
        selectProfileAfterDeletion()
        rescheduleAutomaticSubscriptionRefreshes()
    }

    public func deleteProfiles(ids: [UUID]) {
        let removedIDs = profiles.compactMap { ids.contains($0.id) ? $0.id : nil }
        profiles.removeAll { ids.contains($0.id) }
        store.deleteSecrets(profileIDs: removedIDs)
        selectProfileAfterDeletion()
        rescheduleAutomaticSubscriptionRefreshes()
    }

    public func deleteSubscription(_ id: UUID) {
        let ids = profiles.compactMap { profile in
            profile.subscription?.id == id ? profile.id : nil
        }
        deleteProfiles(ids: ids)
    }

    public func refreshSubscription(_ id: UUID) {
        saveDraft()
        startSubscriptionRefresh(id, trigger: .manual)
    }

    public func updateSubscriptionSource(_ id: UUID, sourceURL: String?) {
        let normalizedURL = sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedURL = normalizedURL?.isEmpty == true ? nil : normalizedURL
        let fetchBaseline = Date().timeIntervalSince1970

        for index in profiles.indices where profiles[index].subscription?.id == id {
            profiles[index].subscription?.sourceURL = storedURL
            if storedURL != nil, profiles[index].subscription?.lastFetchedAtUnix == nil {
                profiles[index].subscription?.lastFetchedAtUnix = fetchBaseline
            }
        }

        if draft.subscription?.id == id {
            draft.subscription?.sourceURL = storedURL
            if storedURL != nil, draft.subscription?.lastFetchedAtUnix == nil {
                draft.subscription?.lastFetchedAtUnix = fetchBaseline
            }
        }

        persistProfiles()
        rescheduleAutomaticSubscriptionRefreshes()
    }

    public func pingProfile(_ id: UUID) {
        saveDraft()
        guard let profile = profiles.first(where: { $0.id == id }) else {
            appendLog(AppLocalization.string("Could not ping: profile was not found."))
            return
        }
        startPing(profile)
    }

    public func pingSubscription(_ id: UUID) {
        saveDraft()
        let profilesToPing = profiles.filter { $0.subscription?.id == id }
        guard !profilesToPing.isEmpty else {
            appendLog(AppLocalization.string("Could not ping subscription: no profiles found."))
            return
        }

        guard subscriptionPingTasks[id] == nil else {
            return
        }

        let subscriptionName = profilesToPing.first?.subscription?.name ?? AppLocalization.string("subscription")
        appendLog(AppLocalization.format("Pinging subscription %@: %d profile(s).", subscriptionName, profilesToPing.count))

        // Probe profiles one at a time: a single olcRTC tunnel at a time avoids the local
        // contention that made concurrent pings time out. Every queued profile is marked as
        // pinging up front, so the UI spins a circle on all of them immediately; each
        // performPing then clears its own spinner and publishes its result as it finishes.
        subscriptionPingTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { subscriptionPingTasks[id] = nil }

            // Validate up front; queue only the profiles worth pinging and mark them pinging.
            var queue: [ConnectionProfile] = []
            for profile in profilesToPing {
                // Skip profiles already being pinged on their own to avoid double work.
                if pingTasks[profile.id] != nil { continue }

                if let validationMessage = validate(profile: profile) {
                    pingResults[profile.id] = .failure(message: validationMessage)
                    appendLog(
                        AppLocalization.format(
                            "Ping for %@ was not started: %@",
                            profileLogName(profile),
                            validationMessage
                        )
                    )
                    continue
                }

                pingingProfileIDs.insert(profile.id)
                pingResults[profile.id] = nil
                queue.append(profile)
            }

            for profile in queue {
                if Task.isCancelled { break }
                await performPing(profile)
            }

            // Drop spinners for any profiles left unprobed (e.g. cancelled mid-run).
            for profile in queue where pingingProfileIDs.contains(profile.id) {
                pingingProfileIDs.remove(profile.id)
            }
        }
    }

    public func importValue(_ value: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return
        }

        importTask?.cancel()
        importTask = Task { [weak self] in
            guard let self else { return }
            importErrorMessage = nil
            isImporting = true
            defer { isImporting = false }

            do {
                if let url = subscriptionURL(from: value) {
                    let content = try await fetchSubscription(from: url)
                    try importSubscription(content, sourceURL: url)
                    return
                }

                if value.lowercased().hasPrefix("olcrtc://") && !value.contains("\n") {
                    importURI(value)
                    return
                }

                try importSubscription(value, sourceURL: nil)
            } catch {
                let message = AppLocalization.format(
                    "Could not import subscription: %@",
                    error.localizedDescription
                )
                importErrorMessage = message
                appendLog(message)
            }
        }
    }

    public func importURI(_ value: String) {
        do {
            importErrorMessage = nil
            saveDraft()
            var profile = try uriParser.parse(value, into: .empty)
            profile.id = UUID()
            profile.subscription = nil
            replacePlaceholderIfNeeded()
            profiles.append(profile)
            selectedProfileID = profile.id
            draft = profile
            persistProfiles()
            appendLog(AppLocalization.string("Imported olcRTC profile link."))
        } catch {
            let message = AppLocalization.format("Could not import profile: %@", error.localizedDescription)
            importErrorMessage = message
            appendLog(message)
        }
    }

    public func clearImportError() {
        importErrorMessage = nil
    }

    public func saveDraft() {
        guard let index = profiles.firstIndex(where: { $0.id == draft.id }) else {
            return
        }

        profiles[index] = draft
        persistProfiles()
    }

    public func start() {
        saveDraft()
        startTask?.cancel()
        linkWatchTask?.cancel()
        wantsConnection = true
        reconnectAttempt = 0

        var profileToStart = draft.normalizedForCurrentDefaults()
        if profileToStart != draft {
            draft = profileToStart
            saveDraft()
        }

        if let validationMessage = validate(profile: profileToStart) {
            wantsConnection = false
            status = .failed(validationMessage)
            appendLog(AppLocalization.format("Profile is incomplete: %@", validationMessage))
            return
        }

        if !PortAvailability.isLocalTCPPortAvailable(profileToStart.socksPort) {
            appendLog(
                AppLocalization.format(
                    "SOCKS port %d appears busy; trying olcRTC start anyway.",
                    profileToStart.socksPort
                )
            )
        }

        status = .starting
        #if os(iOS)
        beginDiagnosticSession(for: profileToStart, mode: useSystemProxy ? "packetTunnel" : "localSocks")
        #else
        beginDiagnosticSession(for: profileToStart, mode: "localSocks")
        #endif
        appendLog(AppLocalization.format("Connecting: %@.", selectedProfileName), level: .checkpoint)

        startTask = Task { [weak self] in
            guard let self else { return }
            await self.runLocalProxyConnect(profile: profileToStart, isReconnect: false)
        }
    }

    private func runLocalProxyConnect(profile: ConnectionProfile, isReconnect: Bool) async {
        var profileToStart = profile
        do {
            if let subscriptionID = profileToStart.subscription?.id,
               profileToStart.subscription?.sourceURL != nil {
                appendLog("checkpoint: sub refresh before start", level: .checkpoint)
                if let refreshTask = startSubscriptionRefresh(subscriptionID, trigger: .manual) {
                    await refreshTask.value
                }
                if let refreshed = profiles.first(where: { $0.id == profileToStart.id }) {
                    profileToStart = refreshed
                    draft = refreshed
                } else if let selectedID = selectedProfileID,
                          let selected = profiles.first(where: { $0.id == selectedID }) {
                    profileToStart = selected
                    draft = selected
                }
                let expires = profileToStart.subscription?.accessExpiresAtUtc ?? "unknown"
                appendLog(
                    "checkpoint: profile applied device=\(profileToStart.clientID) expires=\(expires) jwt=\(profileToStart.accessToken.isEmpty ? "missing" : "present") carrierAuth=\(profileToStart.carrierAuthToken.isEmpty ? "missing" : "present")",
                    level: .checkpoint
                )
                if let validationMessage = validate(profile: profileToStart) {
                    wantsConnection = false
                    status = .failed(validationMessage)
                    appendLog(AppLocalization.format("Profile is incomplete: %@", validationMessage), level: .error)
                    flushDiagnostics(reason: "validation")
                    return
                }
            }

            #if os(iOS)
            if useSystemProxy {
                startPacketTunnel(profile: profileToStart)
                return
            }
            #endif

            let options = OlcRTCStartOptions(profile: profileToStart)
            runningMode = .localProxy
            beginDiagnosticSession(for: profileToStart, mode: "localSocks")
            appendLog(
                "checkpoint: MobileStart carrier=\(options.carrierName) transport=\(options.transportName) room=\(options.roomID) socks=\(options.socksPort) jwt=\(options.accessToken.isEmpty ? "missing" : "present") carrierAuth=\(options.carrierAuthToken.isEmpty ? "missing" : "present")",
                level: .checkpoint
            )
            let activePort = try await startEngineUntilReady(options: options)
            guard wantsConnection, !Task.isCancelled else {
                await engine.stop()
                return
            }
            status = .ready
            reconnectAttempt = 0
            appendLog(AppLocalization.format("SOCKS proxy is ready on 127.0.0.1:%d.", activePort))
            appendLog("checkpoint: SOCKS ready port=\(activePort)", level: .checkpoint)
            appendLog(
                "checkpoint: Happ → SOCKS5 127.0.0.1:\(activePort) — в журнале будут строки socks: accept/request/tunnel",
                level: .checkpoint
            )
            if isReconnect {
                appendLog("checkpoint: auto-reconnect succeeded", level: .checkpoint)
            }
            startDiagnosticsUpload(for: profileToStart, mode: "localSocks")
            #if os(iOS)
            startLocalProxyBackgroundRuntime()
            #endif
            await enableSystemProxyIfNeeded(port: activePort)
            startLinkWatchIfNeeded()
        } catch {
            if error is CancellationError {
                await engine.stop()
                return
            }

            runningMode = nil
            #if os(iOS)
            backgroundRuntimeKeeper.stop()
            #endif
            await engine.stop()

            if wantsConnection {
                appendLog(AppLocalization.format("Could not connect: %@", error.localizedDescription), level: .error)
                appendLog("checkpoint: WaitReady/error \(error.localizedDescription)", level: .error)
                flushDiagnostics(reason: "waitready_error")
                await scheduleAutoReconnect(afterFailure: true)
                return
            }

            status = .failed(error.localizedDescription)
            appendLog(AppLocalization.format("Could not connect: %@", error.localizedDescription), level: .error)
            appendLog("checkpoint: WaitReady/error \(error.localizedDescription)", level: .error)
            flushDiagnostics(reason: "connect_failed")
        }
    }

    private func startLinkWatchIfNeeded() {
        #if os(iOS)
        guard runningMode == .localProxy else { return }
        #else
        guard runningMode == .localProxy else { return }
        #endif
        linkWatchTask?.cancel()
        linkWatchTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: linkWatchIntervalNanoseconds)
                guard !Task.isCancelled, wantsConnection else { return }
                guard runningMode == .localProxy, status == .ready else { continue }
                let running = await engine.isRunning
                if running {
                    reconnectAttempt = 0
                    continue
                }
                appendLog("checkpoint: engine stopped while Connected — auto-reconnect", level: .warn)
                flushDiagnostics(reason: "link_drop")
                await scheduleAutoReconnect(afterFailure: false)
                return
            }
        }
    }

    private func scheduleAutoReconnect(afterFailure: Bool) async {
        guard wantsConnection else { return }

        reconnectAttempt += 1
        let exponent = min(reconnectAttempt, 5)
        let backoff = min(reconnectBackoffCapSeconds, pow(2.0, Double(exponent)))
        status = .starting
        runningMode = .localProxy
        appendLog(
            "checkpoint: auto-reconnect attempt=\(reconnectAttempt) backoff=\(Int(backoff))s",
            level: .checkpoint
        )
        #if os(iOS)
        backgroundRuntimeKeeper.stop()
        #endif
        await engine.stop()
        try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
        guard wantsConnection, !Task.isCancelled else { return }

        var profile = draft.normalizedForCurrentDefaults()
        if let selectedID = selectedProfileID,
           let selected = profiles.first(where: { $0.id == selectedID }) {
            profile = selected
        }
        await runLocalProxyConnect(profile: profile, isReconnect: true)
    }

    private func startEngineUntilReady(options: OlcRTCStartOptions) async throws -> Int {
        for attempt in 0...portConflictRetryAttempts {
            do {
                try await engine.start(options: options)
                try await engine.waitReady(
                    timeoutMillis: max(options.startTimeoutMillis, ConnectionProfile.defaultStartTimeoutMillis)
                )
                return await engine.activeSocksPort ?? options.socksPort
            } catch {
                await engine.stop()

                guard !(error is CancellationError) else {
                    throw error
                }

                guard attempt < portConflictRetryAttempts,
                      isSocksPortConflict(error, port: options.socksPort) else {
                    throw error
                }

                appendLog(
                    AppLocalization.format(
                        "SOCKS port %d is still being released; retrying.",
                        options.socksPort
                    )
                )
                try await Task.sleep(nanoseconds: portConflictRetryDelayNanoseconds)
            }
        }

        throw OlcRTCEngineError.invalidProfile(
            AppLocalization.format(
                "SOCKS port %d is busy. Stop the existing process or choose another port.",
                options.socksPort
            )
        )
    }

    private func isSocksPortConflict(_ error: Error, port: Int) -> Bool {
        let message = error.localizedDescription.lowercased()
        let localizedBusyPort = AppLocalization.format(
            "SOCKS port %d is busy. Stop the existing process or choose another port.",
            port
        ).lowercased()

        return message.contains(localizedBusyPort) ||
            message.contains("address already in use") ||
            message.contains("failed to listen") ||
            message.contains("bind")
    }

    public func stop() {
        wantsConnection = false
        reconnectAttempt = 0
        startTask?.cancel()
        linkWatchTask?.cancel()
        linkWatchTask = nil
        status = .stopping
        appendLog(AppLocalization.format("Disconnecting: %@.", selectedProfileName), level: .checkpoint)
        flushDiagnostics(reason: "disconnect")
        diagnosticUploader.stopPeriodicUpload()

        Task { [weak self] in
            guard let self else { return }
            switch runningMode {
            #if os(iOS)
            case .packetTunnel:
                await packetTunnelManager.stop()
                appendLog(AppLocalization.string("iOS VPN tunnel stopped."), level: .checkpoint)
            #endif
            case .localProxy, nil:
                #if os(iOS)
                backgroundRuntimeKeeper.stop()
                #endif
                await disableSystemProxyIfNeeded()
                await engine.stop()
            }
            runningMode = nil
            status = .stopped
            DiagnosticJournal.shared.clearSession()
        }
    }

    public func shutdownForAppTermination() {
        wantsConnection = false
        linkWatchTask?.cancel()
        flushDiagnostics(reason: "app_terminate")
        guard status.isRunning || runningMode != nil else {
            return
        }
        stop()
    }

    public func clearLogs() {
        DiagnosticJournal.shared.clearUI()
        logs.removeAll()
    }

    private func persistProfiles() {
        store.saveProfiles(profiles)
        store.saveSelectedProfileID(selectedProfileID)
    }

    private func startPing(_ profile: ConnectionProfile) {
        guard pingTasks[profile.id] == nil else {
            return
        }

        if let validationMessage = validate(profile: profile) {
            pingResults[profile.id] = .failure(message: validationMessage)
            appendLog(
                AppLocalization.format(
                    "Ping for %@ was not started: %@",
                    profileLogName(profile),
                    validationMessage
                )
            )
            return
        }

        let profileID = profile.id
        pingTasks[profileID] = Task { [weak self] in
            guard let self else { return }
            defer { pingTasks[profileID] = nil }
            await performPing(profile)
        }
    }

    private func performPing(_ profile: ConnectionProfile) async {
        let profileID = profile.id
        let profileName = profileLogName(profile)
        pingingProfileIDs.insert(profileID)
        pingResults[profileID] = nil
        defer { pingingProfileIDs.remove(profileID) }

        do {
            let result = try await profilePinger.ping(profile: profile)
            guard !Task.isCancelled else { return }
            pingResults[profileID] = .success(milliseconds: result.milliseconds)
            appendLog(AppLocalization.format("Ping %@: %d ms.", profileName, result.milliseconds))
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            pingResults[profileID] = .failure(message: error.localizedDescription)
            appendLog(AppLocalization.format("Ping %@ failed: %@", profileName, error.localizedDescription))
        }
    }

    private func profileLogName(_ profile: ConnectionProfile) -> String {
        profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? AppLocalization.string("Untitled")
            : profile.name
    }

    private func selectProfileAfterDeletion() {
        if let selectedProfileID, profiles.contains(where: { $0.id == selectedProfileID }) {
            persistProfiles()
            return
        }

        if let profile = profiles.first {
            selectedProfileID = profile.id
            draft = profile
        } else {
            selectedProfileID = nil
            draft = .empty
        }
        persistProfiles()
    }

    private func importSubscription(_ value: String, sourceURL: URL?) throws {
        saveDraft()

        let imported = try subscriptionParser.parse(value, sourceURL: sourceURL)
        let importedProfiles = profilesWithSubscriptionFetchTime(imported.profiles, fetchedAt: Date())
        let existingIDs: Set<UUID>
        if let sourceURL {
            existingIDs = Set(
                profiles.compactMap { profile in
                    profile.subscription?.sourceURL == sourceURL.absoluteString ? profile.id : nil
                }
            )
        } else {
            existingIDs = []
        }

        if !existingIDs.isEmpty {
            profiles.removeAll { existingIDs.contains($0.id) }
            store.deleteSecrets(profileIDs: Array(existingIDs))
        }

        replacePlaceholderIfNeeded()
        profiles.append(contentsOf: importedProfiles)
        if let firstProfile = importedProfiles.first {
            selectedProfileID = firstProfile.id
            draft = firstProfile
        }
        persistProfiles()
        rescheduleAutomaticSubscriptionRefreshes()
        appendLog(AppLocalization.format("Imported subscription %@: %d server(s).", imported.name, importedProfiles.count))
        if let first = importedProfiles.first {
            let expires = first.subscription?.accessExpiresAtUtc ?? "n/a"
            appendLog(
                "checkpoint: sub fetch ok device=\(first.clientID) expires=\(expires) jwt=\(first.accessToken.isEmpty ? "missing" : "present") carrierAuth=\(first.carrierAuthToken.isEmpty ? "missing" : "present") socks=\(first.socksPort) room=\(first.roomID)"
            )
        }
    }

    private func refreshSubscription(
        _ value: String,
        sourceURL: URL,
        existingSubscriptionID: UUID,
        fetchedAt: Date
    ) throws {
        saveDraft()

        let imported = try subscriptionParser.parse(value, sourceURL: sourceURL)
        let importedProfiles = profilesWithSubscriptionFetchTime(imported.profiles, fetchedAt: fetchedAt)
        let existingIndices = profiles.indices.filter { index in
            profiles[index].subscription?.id == existingSubscriptionID
        }
        let existingProfiles = existingIndices.map { profiles[$0] }
        guard let insertionIndex = existingIndices.min() else {
            try importSubscription(value, sourceURL: sourceURL)
            return
        }

        var existingByKey: [String: ConnectionProfile] = [:]
        for profile in existingProfiles {
            for key in subscriptionProfileKeys(profile) where existingByKey[key] == nil {
                existingByKey[key] = profile
            }
        }

        var matchedExistingIDs: Set<UUID> = []
        var refreshedProfiles: [ConnectionProfile] = []
        for importedProfile in importedProfiles {
            var profile = importedProfile
            profile.subscription?.id = existingSubscriptionID

            if let existingProfile = subscriptionProfileKeys(importedProfile).compactMap({ existingByKey[$0] }).first {
                profile = mergeImportedSubscriptionProfile(profile, preservingLocalSettingsFrom: existingProfile)
                matchedExistingIDs.insert(existingProfile.id)
            }

            refreshedProfiles.append(profile)
        }

        let deletedIDs = existingProfiles
            .map(\.id)
            .filter { !matchedExistingIDs.contains($0) }

        profiles.removeAll { profile in
            profile.subscription?.id == existingSubscriptionID
        }
        profiles.insert(contentsOf: refreshedProfiles, at: min(insertionIndex, profiles.count))

        if !deletedIDs.isEmpty {
            store.deleteSecrets(profileIDs: deletedIDs)
        }

        if let selectedProfileID, let selectedProfile = profiles.first(where: { $0.id == selectedProfileID }) {
            draft = selectedProfile
        } else if let firstProfile = refreshedProfiles.first {
            selectedProfileID = firstProfile.id
            draft = firstProfile
        }

        persistProfiles()
        rescheduleAutomaticSubscriptionRefreshes()
        appendLog(
            AppLocalization.format(
                "Subscription %@ refreshed: %d updated, %d added, %d removed.",
                imported.name,
                matchedExistingIDs.count,
                refreshedProfiles.count - matchedExistingIDs.count,
                deletedIDs.count
            )
        )
    }

    @discardableResult
    private func startSubscriptionRefresh(
        _ id: UUID,
        trigger: SubscriptionRefreshTrigger
    ) -> Task<Void, Never>? {
        if trigger == .automatic, refreshTasks[id] != nil {
            return nil
        }

        guard let request = subscriptionRefreshRequest(for: id, shouldLogFailures: trigger == .manual) else {
            return nil
        }

        if trigger == .manual {
            refreshTasks[id]?.cancel()
        } else if refreshTasks[id] != nil {
            return nil
        }

        let token = UUID()
        refreshTaskTokens[id] = token
        let task = Task { [weak self] in
            guard let self else { return }
            await performSubscriptionRefresh(request, token: token)
        }
        refreshTasks[id] = task
        return task
    }

    private func subscriptionRefreshRequest(
        for id: UUID,
        shouldLogFailures: Bool
    ) -> SubscriptionRefreshRequest? {
        guard let metadata = profiles.compactMap(\.subscription).first(where: { $0.id == id }) else {
            if shouldLogFailures {
                appendLog(AppLocalization.string("Could not refresh subscription: subscription was not found."))
            }
            return nil
        }

        guard let sourceURLValue = metadata.sourceURL, let sourceURL = URL(string: sourceURLValue) else {
            if shouldLogFailures {
                appendLog(AppLocalization.format("Subscription %@ has no refresh URL.", metadata.name))
            }
            return nil
        }

        return SubscriptionRefreshRequest(id: id, sourceURL: sourceURL)
    }

    private func performSubscriptionRefresh(_ request: SubscriptionRefreshRequest, token: UUID) async {
        refreshingSubscriptionIDs.insert(request.id)
        defer {
            if refreshTaskTokens[request.id] == token {
                refreshingSubscriptionIDs.remove(request.id)
                refreshTasks[request.id] = nil
                refreshTaskTokens[request.id] = nil
            }
        }

        do {
            let content = try await fetchSubscription(from: request.sourceURL)
            guard !Task.isCancelled else {
                return
            }
            try refreshSubscription(
                content,
                sourceURL: request.sourceURL,
                existingSubscriptionID: request.id,
                fetchedAt: Date()
            )
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else {
                return
            }
            appendLog(AppLocalization.format("Could not refresh subscription: %@", error.localizedDescription))
        }
    }

    private func mergeImportedSubscriptionProfile(
        _ importedProfile: ConnectionProfile,
        preservingLocalSettingsFrom existingProfile: ConnectionProfile
    ) -> ConnectionProfile {
        var profile = importedProfile
        profile.id = existingProfile.id
        profile.socksPort = existingProfile.socksPort
        profile.socksUser = existingProfile.socksUser
        profile.socksPass = existingProfile.socksPass
        profile.dnsServer = existingProfile.dnsServer
        profile.debugLogging = existingProfile.debugLogging
        profile.startTimeoutMillis = existingProfile.startTimeoutMillis
        return profile
    }

    private func subscriptionProfileKeys(_ profile: ConnectionProfile) -> [String] {
        let nodeURI = profile.subscription?.nodeURI?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullConnectionKey = [
            profile.carrier.rawValue,
            profile.transport.rawValue,
            profile.roomID,
            profile.keyHex,
        ].joined(separator: "|")
        let connectionKey = [
            profile.carrier.rawValue,
            profile.transport.rawValue,
            profile.roomID,
        ].joined(separator: "|")

        var keys: [String] = []
        if let nodeURI, !nodeURI.isEmpty {
            keys.append("uri:\(nodeURI)")
        }
        keys.append("connection-full:\(fullConnectionKey)")
        keys.append("connection:\(connectionKey)")
        return keys
    }

    private func rescheduleAutomaticSubscriptionRefreshes() {
        let states = automaticSubscriptionRefreshStates()
        let desiredIDs = Set(states.map(\.id))

        for id in Array(automaticRefreshTasks.keys) where !desiredIDs.contains(id) {
            automaticRefreshTasks[id]?.cancel()
            automaticRefreshTasks[id] = nil
            automaticRefreshTaskTokens[id] = nil
            automaticRefreshConfigurations[id] = nil
            automaticRefreshAttemptedAt[id] = nil
        }

        for state in states {
            let configuration = AutomaticSubscriptionRefreshConfiguration(
                id: state.id,
                sourceURL: state.sourceURL.absoluteString,
                intervalSeconds: state.intervalSeconds
            )
            if automaticRefreshConfigurations[state.id] == configuration,
               automaticRefreshTasks[state.id] != nil {
                continue
            }

            automaticRefreshTasks[state.id]?.cancel()
            automaticRefreshAttemptedAt[state.id] = nil

            let token = UUID()
            automaticRefreshTaskTokens[state.id] = token
            automaticRefreshConfigurations[state.id] = configuration
            automaticRefreshTasks[state.id] = Task { [weak self] in
                await self?.runAutomaticSubscriptionRefreshLoop(subscriptionID: state.id, token: token)
            }
        }
    }

    private func runAutomaticSubscriptionRefreshLoop(subscriptionID id: UUID, token: UUID) async {
        defer {
            if automaticRefreshTaskTokens[id] == token {
                automaticRefreshTasks[id] = nil
                automaticRefreshTaskTokens[id] = nil
                automaticRefreshConfigurations[id] = nil
                automaticRefreshAttemptedAt[id] = nil
            }
        }

        while !Task.isCancelled {
            guard let state = automaticSubscriptionRefreshState(for: id) else {
                return
            }

            let delay = automaticRefreshDelay(for: state, now: Date())
            guard await sleepForAutomaticRefresh(seconds: delay) else {
                return
            }
            guard !Task.isCancelled, automaticRefreshTaskTokens[id] == token else {
                return
            }

            guard automaticSubscriptionRefreshState(for: id) != nil else {
                return
            }
            automaticRefreshAttemptedAt[id] = Date()

            if let refreshTask = startSubscriptionRefresh(id, trigger: .automatic) {
                await refreshTask.value
            }
        }
    }

    private func automaticSubscriptionRefreshState(for id: UUID) -> AutomaticSubscriptionRefreshState? {
        automaticSubscriptionRefreshStates().first { $0.id == id }
    }

    private func automaticSubscriptionRefreshStates() -> [AutomaticSubscriptionRefreshState] {
        var seenIDs: Set<UUID> = []
        var states: [AutomaticSubscriptionRefreshState] = []

        for profile in profiles {
            guard let metadata = profile.subscription,
                  !seenIDs.contains(metadata.id),
                  let sourceURLValue = metadata.sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !sourceURLValue.isEmpty,
                  let sourceURL = URL(string: sourceURLValue),
                  let intervalSeconds = SubscriptionRefreshInterval.seconds(from: metadata.refreshInterval),
                  SubscriptionRefreshInterval.nanoseconds(from: intervalSeconds) != nil else {
                continue
            }

            seenIDs.insert(metadata.id)
            states.append(
                AutomaticSubscriptionRefreshState(
                    id: metadata.id,
                    sourceURL: sourceURL,
                    intervalSeconds: intervalSeconds,
                    lastFetchedAtUnix: metadata.lastFetchedAtUnix
                )
            )
        }

        return states
    }

    private func automaticRefreshDelay(
        for state: AutomaticSubscriptionRefreshState,
        now: Date
    ) -> TimeInterval {
        let anchors = [
            state.lastFetchedAtUnix.map(Date.init(timeIntervalSince1970:)),
            automaticRefreshAttemptedAt[state.id],
        ].compactMap { $0 }

        guard let anchor = anchors.max() else {
            return state.intervalSeconds
        }

        return max(0, anchor.addingTimeInterval(state.intervalSeconds).timeIntervalSince(now))
    }

    private func sleepForAutomaticRefresh(seconds: TimeInterval) async -> Bool {
        guard seconds > 0 else {
            return !Task.isCancelled
        }
        guard let nanoseconds = SubscriptionRefreshInterval.nanoseconds(from: seconds) else {
            return false
        }

        do {
            try await Task.sleep(nanoseconds: nanoseconds)
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    private func profilesWithSubscriptionFetchTime(
        _ profiles: [ConnectionProfile],
        fetchedAt: Date
    ) -> [ConnectionProfile] {
        let fetchedAtUnix = fetchedAt.timeIntervalSince1970
        return profiles.map { profile in
            var profile = profile
            profile.subscription?.lastFetchedAtUnix = fetchedAtUnix
            return profile
        }
    }

    private static func initializedSubscriptionFetchTimes(
        in profiles: [ConnectionProfile],
        now: Date
    ) -> [ConnectionProfile] {
        let fetchedAtUnix = now.timeIntervalSince1970
        return profiles.map { profile in
            var profile = profile
            let sourceURL = profile.subscription?.sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines)
            if profile.subscription?.lastFetchedAtUnix == nil,
               sourceURL?.isEmpty == false,
               SubscriptionRefreshInterval.seconds(from: profile.subscription?.refreshInterval) != nil {
                profile.subscription?.lastFetchedAtUnix = fetchedAtUnix
            }
            return profile
        }
    }

    private func replacePlaceholderIfNeeded() {
        guard profiles.count == 1, isEmptyPlaceholder(profiles[0]) else {
            return
        }

        let profileID = profiles[0].id
        profiles.removeAll()
        store.deleteSecrets(profileIDs: [profileID])
    }

    private func isEmptyPlaceholder(_ profile: ConnectionProfile) -> Bool {
        let empty = ConnectionProfile.empty
        var comparable = profile
        comparable.id = empty.id
        return comparable == empty
    }

    private func subscriptionURL(from value: String) -> URL? {
        if let url = URL(string: value),
           let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme),
           url.host(percentEncoded: false) != nil {
            return url
        }

        guard !value.contains("\n"),
              !value.lowercased().hasPrefix("olcrtc://"),
              value.contains("."),
              let url = URL(string: "https://\(value)"),
              url.host(percentEncoded: false) != nil else {
            return nil
        }
        return url
    }

    private func fetchSubscription(from url: URL) async throws -> String {
        appendLog(AppLocalization.format("Loading subscription: %@.", DiagnosticLogRedactor.redactURL(url)))
        appendLog("checkpoint: sub fetch")
        do {
            return try await subscriptionFetcher.fetchWithURLSession(from: url)
        } catch {
            guard subscriptionFetcher.shouldRetryThroughResolvedEndpoint(error),
                  let host = url.host(percentEncoded: false),
                  url.scheme?.lowercased() == "https" else {
                throw error
            }

            appendLog(AppLocalization.format("DNS lookup for %@ failed; retrying through DNS-over-HTTPS.", host))
            do {
                return try await subscriptionFetcher.fetchThroughResolvedEndpoint(from: url)
            } catch {
                appendLog(AppLocalization.format("Retry through DNS-over-HTTPS failed: %@", error.localizedDescription))
                throw error
            }
        }
    }

    private func observeEngineEvents() {
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await message in engine.events {
                appendLog(message)
            }
        }
    }

    private func appendLog(_ message: String, level: DiagnosticLogLevel = .info) {
        let resolvedLevel: DiagnosticLogLevel
        if level == .info, message.hasPrefix("checkpoint:") {
            resolvedLevel = .checkpoint
        } else {
            resolvedLevel = level
        }
        DiagnosticJournal.shared.append(message, level: resolvedLevel)
        logs = DiagnosticJournal.shared.recentUILines()
    }

    private func beginDiagnosticSession(for profile: ConnectionProfile, mode: String) {
        let sessionId = diagnosticSessionId ?? UUID()
        diagnosticSessionId = sessionId
        DiagnosticJournal.shared.configureSession(
            sessionId: sessionId,
            mode: mode,
            deviceId: profile.clientID
        )
    }

    private func startDiagnosticsUpload(for profile: ConnectionProfile, mode: String) {
        guard sendDiagnostics else {
            diagnosticUploader.stopPeriodicUpload()
            return
        }
        let sessionId = diagnosticSessionId ?? UUID()
        diagnosticSessionId = sessionId
        let subscriptionURL = profile.subscription?.sourceURL.flatMap(URL.init(string:))
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        #if os(iOS)
        let platform = "ios"
        #else
        let platform = "macos"
        #endif
        diagnosticUploader.updateContext(
            DiagnosticLogUploadContext(
                accessToken: profile.accessToken,
                deviceId: profile.clientID,
                sessionId: sessionId,
                mode: mode,
                uploadURL: DiagnosticLogUploader.uploadURL(fromSubscriptionURL: subscriptionURL),
                appVersion: appVersion,
                build: build,
                platform: platform
            )
        )
        diagnosticUploader.setEnabled(true)
        diagnosticUploader.startPeriodicUpload(intervalSeconds: 60)
        diagnosticUploader.uploadNow(reason: "connected")
    }

    private func flushDiagnostics(reason: String) {
        guard sendDiagnostics else { return }
        let profile = profiles.first(where: { $0.id == selectedProfileID }) ?? draft
        if !profile.accessToken.isEmpty {
            let mode: String
            #if os(iOS)
            mode = runningMode == .packetTunnel ? "packetTunnel" : "localSocks"
            #else
            mode = "localSocks"
            #endif
            startDiagnosticsUpload(for: profile, mode: mode)
        }
        diagnosticUploader.uploadNow(reason: reason)
    }

    private func handleAppBecameActive() {
        DiagnosticJournal.shared.mergeSharedLogIntoUI()
        logs = DiagnosticJournal.shared.recentUILines()
        if sendDiagnostics, status == .ready {
            diagnosticUploader.uploadNow(reason: "foreground")
        }
    }

    private func loadNetworkServices() {
        Task { [weak self] in
            guard let self else { return }
            let services = await systemProxyManager.networkServices()
            networkServices = services.isEmpty ? ["Wi-Fi"] : services
            if !networkServices.contains(selectedNetworkService) {
                selectedNetworkService = networkServices.first ?? "Wi-Fi"
            }
        }
    }

    #if os(iOS)
    private func enableSystemVPNByDefaultIfAvailable() {
        Task { [weak self] in
            guard let self,
                  await PacketTunnelManager.canAccessPacketTunnelPreferences() else {
                return
            }
            useSystemProxy = true
        }
    }

    private func startLocalProxyBackgroundRuntime() {
        do {
            try backgroundRuntimeKeeper.start()
            appendLog(AppLocalization.string("iOS background mode is active for local SOCKS."))
        } catch {
            appendLog(AppLocalization.format("Could not enable iOS background mode: %@", error.localizedDescription))
        }
    }

    private func startPacketTunnel(profile: ConnectionProfile) {
        status = .starting
        runningMode = .packetTunnel
        beginDiagnosticSession(for: profile, mode: "packetTunnel")
        appendLog(AppLocalization.format("Connecting %@ through iOS VPN.", selectedProfileName), level: .checkpoint)
        appendLog("checkpoint: VPN startTunnel requested", level: .checkpoint)

        startTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await packetTunnelManager.start(profile: profile)
                status = .ready
                appendLog(
                    AppLocalization.string("iOS VPN tunnel connected. System traffic is routed through olcRTC."),
                    level: .checkpoint
                )
                DiagnosticJournal.shared.mergeSharedLogIntoUI()
                logs = DiagnosticJournal.shared.recentUILines()
                startDiagnosticsUpload(for: profile, mode: "packetTunnel")
            } catch {
                if error is CancellationError {
                    await packetTunnelManager.stop()
                    return
                }

                runningMode = nil
                status = .failed(error.localizedDescription)
                appendLog(
                    AppLocalization.format("Could not start VPN: %@", vpnStartFailureMessage(error)),
                    level: .error
                )
                flushDiagnostics(reason: "vpn_start_failed")
                await packetTunnelManager.stop()            }
        }
    }

    private func vpnStartFailureMessage(_ error: Error) -> String {
        let message = error.localizedDescription
        guard message.localizedCaseInsensitiveContains("IPC failed") else {
            return message
        }

        #if targetEnvironment(simulator)
        return "\(message). Rebuild the simulator app with signing enabled so the Packet Tunnel extension gets simulated entitlements."
        #else
        return "\(message). Check that the app and Packet Tunnel extension profiles include the Network Extension packet-tunnel-provider entitlement."
        #endif
    }
    #endif

    private func enableSystemProxyIfNeeded(port: Int) async {
        #if os(macOS)
        guard useSystemProxy else {
            appendLog(
                AppLocalization.format(
                    "System SOCKS proxy is off. Configure apps manually for 127.0.0.1:%d.",
                    port
                )
            )
            return
        }

        do {
            try await systemProxyManager.enable(service: selectedNetworkService, host: "127.0.0.1", port: port)
            appendLog(
                AppLocalization.format(
                    "System SOCKS proxy is enabled for %@ on 127.0.0.1:%d.",
                    selectedNetworkService,
                    port
                )
            )
        } catch {
            appendLog(AppLocalization.format("Could not configure system proxy: %@", error.localizedDescription))
        }
        #else
        appendLog(
            AppLocalization.format(
                "iOS system traffic is not routed automatically. Configure apps manually for 127.0.0.1:%d.",
                port
            )
        )
        #endif
    }

    private func disableSystemProxyIfNeeded() async {
        #if os(macOS)
        guard useSystemProxy else {
            return
        }

        do {
            try await systemProxyManager.disable(service: selectedNetworkService)
            appendLog(AppLocalization.format("System SOCKS proxy is disabled for %@.", selectedNetworkService))
        } catch {
            appendLog(AppLocalization.format("Could not clear system proxy settings: %@", error.localizedDescription))
        }
        #endif
    }

    private func validate(profile: ConnectionProfile) -> String? {
        if profile.keyHex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return AppLocalization.string("Enter the encryption key.")
        }
        if profile.keyHex.count != 64 || !profile.keyHex.allSatisfy(\.isHexDigit) {
            return AppLocalization.string("The key must contain 64 hexadecimal characters.")
        }
        let sourceURL = profile.subscription?.sourceURL ?? ""
        if sourceURL.contains("/api/olcrtc/subscriptions/"),
           profile.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Cockney access token is missing. Re-import the subscription URL."
        }
        if profile.roomID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return profile.carrier == .jitsi
                ? AppLocalization.string("Enter a Room URL for Jitsi.")
                : AppLocalization.string("This provider requires a Room ID.")
        }
        if !ConnectionProfile.socksPortRange.contains(profile.socksPort) {
            return AppLocalization.string("SOCKS port must be between 1024 and 65535.")
        }
        if profile.transport == .videochannel {
            if !["qrcode", "tile"].contains(profile.videoCodec) {
                return AppLocalization.string("Video codec must be qrcode or tile.")
            }
            if profile.videoWidth <= 0 || profile.videoHeight <= 0 {
                return AppLocalization.string("Enter the videochannel size.")
            }
            if profile.videoFPS <= 0 {
                return AppLocalization.string("Enter the videochannel FPS.")
            }
            if profile.videoBitrate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return AppLocalization.string("Enter the videochannel bitrate.")
            }
            if !["none", "nvenc"].contains(profile.videoHardwareAcceleration) {
                return AppLocalization.string("Hardware acceleration must be none or nvenc.")
            }
            if !["low", "medium", "high", "highest"].contains(profile.videoQRRecovery) {
                return AppLocalization.string("QR correction must be low, medium, high, or highest.")
            }
            if profile.videoCodec == "tile" && (profile.videoWidth != 1080 || profile.videoHeight != 1080) {
                return AppLocalization.string("Tile codec requires 1080x1080 size.")
            }
        }

        return nil
    }
}
