//
//  ConvivaAnalytics.swift
//  BitmovinConvivaAnalytics
//
//  Created by Bitmovin on 02.10.18.
//  Copyright (c) 2018 Bitmovin. All rights reserved.
//

import Foundation
import BitmovinPlayer
import ConvivaSDK

public final class ConvivaAnalytics: NSObject {
    // MARK: - Bitmovin Player attributes
    let player: Player

    // MARK: - Conviva related attributes
    let customerKey: String
    let config: ConvivaConfiguration
    var client: CISClientProtocol
    var playerStateManager: CISPlayerStateManagerProtocol!
    var sessionKey: Int32 = NO_SESSION_KEY
    let contentMetadataBuilder: ContentMetadataBuilder
    var isSessionActive: Bool {
        return sessionKey != NO_SESSION_KEY
    }

    // The BitmovinPlayerListener is used to prevent listener methods to be public and therefore
    // preventing calling from outside.
    var listener: BitmovinPlayerListener?

    // MARK: - Helper
    let logger: Logger
    let playerHelper: BitmovinPlayerHelper
    // Workaround for player issue when onPlay is sent while player is stalled
    var isStalled: Bool = false
    var playbackStarted: Bool = false

    // MARK: - Public Attributes
    /**
     Set the PlayerView to enable view triggered events like fullscreen state changes
     */
    public var playerView: PlayerView? {
        didSet {
            playerView?.remove(listener: self)
            playerView?.add(listener: self)
        }
    }

    public var version: String {
        var options: NSDictionary?
        if let path = Bundle(for: ConvivaAnalytics.self).path(forResource: "BitmovinConviva-Info", ofType: "plist") {
            options = NSDictionary(contentsOfFile: path)

            if let version = options?["CFBundleShortVersionString"] as? String {
                return version
            }
        }
        // Should not happen but keep it failsafe
        return ""
    }

    // MARK: - initializer
    /**
     Initialize a new Bitmovin Conviva Analytics object to track metrics from Bitmovin Player

     - Parameters:
        - player: Bitmovin Player instance to track
        - customerKey: Conviva customerKey
        - config: ConvivaConfiguration object (see ConvivaConfiguration for more information)

     - Throws: Convivas `CISClientProtocol` and `CISClientSettingsProtocol` if an error occurs
     */
    public init?(player: Player,
                 customerKey: String,
                 config: ConvivaConfiguration = ConvivaConfiguration()) throws {
        self.player = player
        self.playerHelper = BitmovinPlayerHelper(player: player)
        self.customerKey = customerKey
        self.config = config

        let systemInterFactory: CISSystemInterfaceProtocol = IOSSystemInterfaceFactory.initializeWithSystemInterface()
        let setting: CISSystemSettings = CISSystemSettings()

        logger = Logger(loggingEnabled: config.debugLoggingEnabled)
        self.contentMetadataBuilder = ContentMetadataBuilder(logger: logger)

        if config.debugLoggingEnabled {
            setting.logLevel = LogLevel.LOGLEVEL_DEBUG
        }

        let systemFactory = CISSystemFactoryCreator.create(withCISSystemInterface: systemInterFactory, setting: setting)
        let clientSetting: CISClientSettingProtocol = try CISClientSettingCreator.create(withCustomerKey: customerKey)
        if let gatewayUrl = config.gatewayUrl {
            clientSetting.setGatewayUrl(gatewayUrl.absoluteString)
        }

        self.client = try CISClientCreator.create(withClientSettings: clientSetting, factory: systemFactory)

        super.init()

        listener = BitmovinPlayerListener(player: player)
        listener?.delegate = self
    }

    deinit {
        internalEndSession()
    }

    // MARK: - event handling
    /**
     Sends a custom application-level event to Conviva's Player Insight. An application-level event can always
     be sent and is not tied to a specific video.

     - Parameters:
        - name: The name of the event
        - attributes: A dictionary with custom event attributes
     */
    public func sendCustomApplicationEvent(name: String, attributes: [String: String] = [:]) {
        client.sendCustomEvent(NO_SESSION_KEY, eventname: name, withAttributes: attributes)
    }

    /**
     Sends a custom playback-level event to Conviva's Player Insight. A playback-level event can only be sent
     during an active video session.

     - Parameters:
        - name: The name of the event
        - attributes: A dictionary with custom event attributes
     */
    public func sendCustomPlaybackEvent(name: String, attributes: [String: String] = [:]) {
        if !isSessionActive {
            logger.debugLog(message: "Cannot send playback event, no active monitoring session")
            return
        }
        client.sendCustomEvent(sessionKey, eventname: name, withAttributes: attributes)
    }

    // MARK: - external session handling

    /**
     Will update the contentMetadata which are tracked with conviva.

     If there is an active session only permitted values will be updated and propagated immediately.
     If there is no active session the values will be set on session creation.

     Attributes set via this method will override automatic tracked once.
     - Parameters:
        - metadataOverrides: Metadata attributes which will be used to track to conviva.
                             @see ContentMetadataBuilder for more information about permitted attributes
     */
    public func updateContentMetadata(metadataOverrides: MetadataOverrides) {
        contentMetadataBuilder.setOverrides(metadataOverrides)

        if !isSessionActive {
            logger.debugLog(
                message: "[ ConvivaAnalytics ] no active session; Don\'t propagate content metadata to conviva."
            )
            return
        }

        buildContentMetadata()
        updateSession()
    }

    /**
     Initializes a new conviva tracking session.

     Warning: The integration can only be validated without external session managing. So when using this method we can
     no longer ensure that the session is managed at the correct time. Additional: Since some metadata attributes
     relies on the players source we can't ensure that all metadata attributes are present at session creation.
     Therefore it could be that there will be a 'ContentMetadata created late' issue after conviva validation.

     If no source was loaded (or the itemTitle is missing) and no assetName was set via updateContentMetadata
     this method will throw an error.
     */
    public func initializeSession() throws {
        if isSessionActive {
            logger.debugLog(message: "There is already a session running. Returning …")
            return
        }

        if player.source?.sourceConfig.title == nil && contentMetadataBuilder.assetName == nil {
            throw ConvivaAnalyticsError(
                "AssetName is missing. Load player source (with title) first or set assetName via updateContentMetadata"
            )
        }

        internalInitializeSession()
    }

    /**
     Ends the current conviva tracking session.
     Results in a no-opt if there is no active session.

     Warning: The integration can only be validated without external session managing.
     So when using this method we can no longer ensure that the session is managed at the correct time.
     */
    public func endSession() {
        if !isSessionActive {
            logger.debugLog(message: "No session running. Returning …")
            return
        }

        internalEndSession()
    }

    /**
     Sends a custom deficiency event during playback to Conviva's Player Insight. If no session is active it will NOT
     create one.

     - Parameters:
        - message: Message which will be send to conviva
        - severity: One of FATAL or WARNING
        - endSession: Boolean flag if session should be closed after reporting the deficiency (Default: true)
     */
    public func reportPlaybackDeficiency(message: String,
                                         severity: ErrorSeverity,
                                         endSession: Bool = true) {
        if !isSessionActive {
            return
        }

        client.reportError(sessionKey, errorMessage: message, errorSeverity: severity)
        if endSession {
            internalEndSession()
        }
    }

    /**
     Puts the session state in a notMonitored state.
     */
    public func pauseTracking() {
        // AdStart is the preferred way to pause tracking according to conviva.
        client.adStart(sessionKey,
                       adStream: .ADSTREAM_SEPARATE,
                       adPlayer: .ADPLAYER_SEPARATE,
                       adPosition: .ADPOSITION_PREROLL)
        client.detachPlayer(sessionKey)
        logger.debugLog(message: "Tracking paused.")
    }

    /**
     Puts the session state from a notMonitored state into the last one tracked.
     */
    public func resumeTracking() {
        client.attachPlayer(sessionKey, playerStateManager: playerStateManager)
        // AdEnd is the preferred way to resume tracking according to conviva.
        client.adEnd(sessionKey)
        logger.debugLog(message: "Tracking resumed.")
    }

    // MARK: - session handling
    private func setupPlayerStateManager() {
        playerStateManager = client.getPlayerStateManager()
        playerStateManager.setPlayerState!(PlayerState.CONVIVA_STOPPED)
        playerStateManager.setPlayerType!("Bitmovin Player iOS")

        playerStateManager.setCISIClientMeasureInterface?(self)

        if let bitmovinPlayerVersion = playerHelper.version {
            playerStateManager.setPlayerVersion!(bitmovinPlayerVersion)
        }
    }

    private func internalInitializeSession() {
        buildContentMetadata()

        sessionKey = client.createSession(with: contentMetadataBuilder.build())
        if !isSessionActive {
            logger.debugLog(message: "Something went wrong, could not obtain session key")
            return
        }

        setupPlayerStateManager()
        updateSession()

        client.attachPlayer(sessionKey, playerStateManager: playerStateManager)
        logger.debugLog(message: "Session started")
    }

    private func updateSession() {
        // Update metadata
        if !isSessionActive {
            return
        }
        buildDynamicContentMetadata()

        if let videoQuality = player.videoQuality {
            let bitrate = Int(videoQuality.bitrate) / 1000 // in kbps
            playerStateManager.setBitrateKbps!(bitrate)
            playerStateManager.setVideoResolutionWidth!(videoQuality.width)
            playerStateManager.setVideoResolutionHeight!(videoQuality.height)
        }

        client.updateContentMetadata(sessionKey, metadata: contentMetadataBuilder.build())
    }

    private func internalEndSession() {
        if !isSessionActive {
            return
        }

        client.detachPlayer(sessionKey)
        client.cleanupSession(sessionKey)
        playerStateManager.reset?()
        client.releasePlayerStateManager(playerStateManager)
        sessionKey = NO_SESSION_KEY
        contentMetadataBuilder.reset()
        playbackStarted = false
        logger.debugLog(message: "Session ended")
    }

    // MARK: - meta data handling
    private func buildContentMetadata() {
        let sourceConfig = player.source?.sourceConfig
        contentMetadataBuilder.assetName = sourceConfig?.title

        let customInternTags: [String: Any] = [
            "streamType": playerHelper.streamType,
            "integrationVersion": version
        ]

        contentMetadataBuilder.custom = customInternTags
        buildDynamicContentMetadata()
    }

    private func buildDynamicContentMetadata() {
        if !player.isLive && player.duration.isFinite {
            contentMetadataBuilder.duration = Int(player.duration)
        }
        contentMetadataBuilder.streamType = player.isLive ? .CONVIVA_STREAM_LIVE : .CONVIVA_STREAM_VOD
        contentMetadataBuilder.streamUrl = player.source?.sourceConfig.url.absoluteString
    }

    private func customEvent(event: PlayerEvent, args: [String: String] = [:]) {
        if !isSessionActive {
            return
        }

        sendCustomPlaybackEvent(name: event.name, attributes: args)
    }

    private func onPlaybackStateChanged(playerState: PlayerState) {
        // do not report any playback state changes while player isStalled except buffering
        if !isSessionActive || isStalled && playerState != .CONVIVA_BUFFERING {
            return
        }

        playerStateManager.setPlayerState!(playerState)
        logger.debugLog(message: "Player state changed: \(playerState.rawValue)")
    }
}

// MARK: - PlayerListener
extension ConvivaAnalytics: BitmovinPlayerListenerDelegate {
    func onEvent(_ event: Event) {
        logger.debugLog(message: "[ Player Event ] \(event.name)")
    }

    func onSourceUnloaded() {
        internalEndSession()
    }

    func onTimeChanged() {
        updateSession()
    }

    func onPlayerError(_ event: PlayerErrorEvent) {
        trackError(errorCode: event.code.rawValue, errorMessage: event.message)
    }

    func onSourceError(_ event: SourceErrorEvent) {
        trackError(errorCode: event.code.rawValue, errorMessage: event.message)
    }

    func trackError(errorCode: Int, errorMessage: String) {
         if !isSessionActive {
             internalInitializeSession()
         }

         let message = "\(errorCode) \(errorMessage)"
         reportPlaybackDeficiency(message: message, severity: .ERROR_FATAL)
    }

    func onMuted(_ event: MutedEvent) {
        customEvent(event: event)
    }

    func onUnmuted(_ event: UnmutedEvent) {
        customEvent(event: event)
    }

    // MARK: - Playback state events
    func onPlay() {
        if !isSessionActive {
            internalInitializeSession()
        }
    }

    func onPlaying() {
        playbackStarted = true
        contentMetadataBuilder.setPlaybackStarted(true)
        updateSession()
        onPlaybackStateChanged(playerState: .CONVIVA_PLAYING)
    }

    func onPaused() {
        onPlaybackStateChanged(playerState: .CONVIVA_PAUSED)
    }

    func onPlaybackFinished() {
        onPlaybackStateChanged(playerState: .CONVIVA_STOPPED)
        internalEndSession()
    }

    func onStallStarted() {
        isStalled = true
        onPlaybackStateChanged(playerState: .CONVIVA_BUFFERING)
    }

    func onStallEnded() {
        isStalled = false

        guard playbackStarted else { return }
        if player.isPlaying {
            onPlaybackStateChanged(playerState: .CONVIVA_PLAYING)
        } else if player.isPaused {
            onPlaybackStateChanged(playerState: .CONVIVA_PAUSED)
        }
    }

    // MARK: - Seek / Timeshift events
    func onSeek(_ event: SeekEvent) {
        if !isSessionActive {
            // Handle the case that the User seeks on the UI before play was triggered.
            // This also handles startTime feature. The same applies for onTimeShift.
            return
        }

        playerStateManager.setSeekStart!(Int64(event.to.time * 1000))
    }

    func onSeeked() {
        if !isSessionActive {
            // See comment in onSeek
            return
        }

        playerStateManager.setSeekEnd!(Int64(player.currentTime * 1000))
    }

    func onTimeShift(_ event: TimeShiftEvent) {
        if !isSessionActive {
            // See comment in onSeek
            return
        }

        // According to conviva it is valid to pass -1 for seeking in live streams
        playerStateManager.setSeekStart!(-1)
    }

    func onTimeShifted() {
        if !isSessionActive {
            // See comment in onSeek
            return
        }

        playerStateManager.setSeekEnd!(-1)
    }

    #if !os(tvOS)
    // MARK: - Ad events
    func onAdStarted(_ event: AdStartedEvent) {
        let adPosition: AdPosition = AdEventUtil.parseAdPosition(event: event, contentDuration: player.duration)
        client.adStart(sessionKey, adStream: .ADSTREAM_SEPARATE, adPlayer: .ADPLAYER_CONTENT, adPosition: adPosition)
    }

    func onAdFinished() {
        client.adEnd(sessionKey)
    }

    func onAdSkipped(_ event: AdSkippedEvent) {
        customEvent(event: event)
        client.adEnd(sessionKey)
    }

    func onAdError(_ event: AdErrorEvent) {
        customEvent(event: event)
        client.adEnd(sessionKey)
    }

    func onAdBreakStarted(_ event: AdBreakStartedEvent) {
        customEvent(event: event)
        client.detachPlayer(sessionKey)
    }

    func onAdBreakFinished(_ event: AdBreakFinishedEvent) {
        customEvent(event: event)
        if !client.isPlayerAttached(sessionKey) {
            client.attachPlayer(sessionKey, playerStateManager: playerStateManager)
        }
    }
    #endif

    func onDestroy() {
        internalEndSession()
    }
}

// MARK: - UserInterfaceListener
extension ConvivaAnalytics: UserInterfaceListener {
    public func onFullscreenEnter(_ event: FullscreenEnterEvent) {
        customEvent(event: event)
    }

    public func onFullscreenExit(_ event: FullscreenExitEvent) {
        customEvent(event: event)
    }
}

extension ConvivaAnalytics: CISIClientMeasureInterface {
    public func getAverageFrames() -> Int {
        return Int(player.currentVideoFrameRate)
    }
}
