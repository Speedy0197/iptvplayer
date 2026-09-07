import AVFoundation
import AVKit
import Flutter
import UIKit

final class AirPlayPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private static let methodChannelName = "streampilot/airplay"
  private static let eventChannelName = "streampilot/airplay/events"
  private static let routePickerViewType = "streampilot/airplay/route_picker"

  private let player = AVPlayer()
  private var eventSink: FlutterEventSink?
  private var observations: [NSKeyValueObservation] = []
  private var itemStatusObservation: NSKeyValueObservation?
  private var routeChangeToken: NSObjectProtocol?
  private var positionObserver: Any?
  private var activeDevice: AirPlayDevice?
  private var mediaId: String?
  private var canSeek = false
  private var intendsToPlay = false
  private var hadExternalPlayback = false
  private var routeSelectionPending = false
  private var initialized = false
  private var playbackGeneration: UInt = 0
  private var routeSelectionGeneration: UInt = 0
  private var routeAtPickerOpening: String?
  private var phoneReturnRequested = false
  private var ownsAudioSession = false
  private var previousAudioConfiguration: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?

  static func register(with registrar: FlutterPluginRegistrar) {
    let plugin = AirPlayPlugin()
    let methodChannel = FlutterMethodChannel(
      name: methodChannelName,
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(plugin, channel: methodChannel)

    let eventChannel = FlutterEventChannel(
      name: eventChannelName,
      binaryMessenger: registrar.messenger()
    )
    eventChannel.setStreamHandler(plugin)

    registrar.register(
      AirPlayRoutePickerFactory(plugin: plugin, messenger: registrar.messenger()),
      withId: routePickerViewType
    )
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "initialize":
      initializeIfNeeded()
      result(true)
    case "startDiscovery", "stopDiscovery":
      initializeIfNeeded()
      result(true)
    case "connect":
      connect(arguments: call.arguments, result: result)
    case "load":
      load(arguments: call.arguments, result: result)
    case "play":
      play(result: result)
    case "pause":
      pause(result: result)
    case "seek":
      seek(arguments: call.arguments, result: result)
    case "stop":
      stopPlayback()
      result(true)
    case "disconnect":
      disconnect()
      result(true)
    case "preparePhoneOutput":
      phoneReturnRequested = true
      result(hasBuiltinOutput())
    case "dispose":
      disposeBridge()
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  fileprivate func pickerWillOpen(channel: FlutterMethodChannel) {
    initializeIfNeeded()
    routeSelectionGeneration &+= 1
    routeSelectionPending = true
    routeAtPickerOpening = currentAirPlayDevice()?.id
    channel.invokeMethod("pickerOpening", arguments: nil)
  }

  fileprivate func pickerDidClose(channel: FlutterMethodChannel) {
    channel.invokeMethod("pickerClosed", arguments: nil)
    let generation = routeSelectionGeneration
    // AVKit dismisses before AVAudioSession always finishes publishing the
    // selected output, so inspect on the next run-loop turns as well as through
    // the route-change notification.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      guard
        let self,
        self.initialized,
        self.routeSelectionPending,
        self.routeSelectionGeneration == generation
      else { return }
      if self.phoneReturnRequested && self.hasBuiltinOutput() {
        self.handleRouteLoss()
      } else if let device = self.currentAirPlayDevice(), device.id != self.routeAtPickerOpening {
        self.acceptSelectedRoute(device)
      } else if self.currentAirPlayDevice() == nil && self.activeDevice != nil {
        self.handleRouteLoss()
      } else {
        self.routeSelectionPending = false
        self.phoneReturnRequested = false
        self.send(["event": "selectionCancelled"])
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
      guard
        let self,
        self.initialized,
        self.routeSelectionGeneration == generation
      else { return }
      self.routeSelectionPending = false
    }
  }

  fileprivate func attachPlayer(to layer: AVPlayerLayer) {
    initializeIfNeeded()
    layer.player = player
  }

  private func initializeIfNeeded() {
    guard !initialized else { return }
    initialized = true
    player.allowsExternalPlayback = true
    player.usesExternalPlaybackWhileExternalScreenIsActive = true
    player.audiovisualBackgroundPlaybackPolicy = .pauses

    observations = [
      player.observe(\.timeControlStatus, options: [.initial, .new]) {
        [weak self] _, _ in
        self?.publishPlaybackState()
      },
      player.observe(\.isExternalPlaybackActive, options: [.initial, .new]) {
        [weak self] player, _ in
        self?.externalPlaybackChanged(player.isExternalPlaybackActive)
      },
    ]

    routeChangeToken = NotificationCenter.default.addObserver(
      forName: AVAudioSession.routeChangeNotification,
      object: AVAudioSession.sharedInstance(),
      queue: .main
    ) { [weak self] _ in
      self?.audioRouteChanged()
    }

    positionObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 1, preferredTimescale: 1_000),
      queue: .main
    ) { [weak self] time in
      self?.publishPosition(time)
    }
  }

  private func connect(arguments: Any?, result: @escaping FlutterResult) {
    initializeIfNeeded()
    guard
      let arguments = arguments as? [String: Any],
      let requestedId = arguments["deviceId"] as? String,
      !requestedId.isEmpty,
      let route = currentAirPlayDevice(),
      route.id == requestedId
    else {
      result(
        FlutterError(
          code: "AIRPLAY_ROUTE_UNAVAILABLE",
          message: "The selected AirPlay route is no longer available.",
          details: nil
        )
      )
      return
    }
    activeDevice = route
    emitRoute(connected: true, device: route)
    result(true)
  }

  private func load(arguments: Any?, result: @escaping FlutterResult) {
    initializeIfNeeded()
    guard activeDevice != nil else {
      reject(result, code: "AIRPLAY_NOT_CONNECTED", message: "No AirPlay route is connected.")
      return
    }
    guard
      let arguments = arguments as? [String: Any],
      let id = arguments["id"] as? String,
      !id.isEmpty,
      let source = arguments["url"] as? String,
      let url = URL(string: source),
      let scheme = url.scheme?.lowercased(),
      scheme == "https" || scheme == "http"
    else {
      reject(result, code: "AIRPLAY_INVALID_MEDIA", message: "The AirPlay media request is invalid.")
      return
    }

    mediaId = id
    canSeek = !(arguments["isLive"] as? Bool ?? true)
    intendsToPlay = true
    playbackGeneration &+= 1
    let generation = playbackGeneration
    let item = AVPlayerItem(url: url)
    if let title = arguments["title"] as? String, !title.isEmpty {
      let titleMetadata = AVMutableMetadataItem()
      titleMetadata.identifier = .commonIdentifierTitle
      titleMetadata.value = title as NSString
      titleMetadata.extendedLanguageTag = "und"
      item.externalMetadata = [titleMetadata]
    }
    observe(item: item)
    player.replaceCurrentItem(with: item)
    emitPlayback(state: "loading")

    let positionMilliseconds = (arguments["positionMilliseconds"] as? NSNumber)?.int64Value ?? 0
    let beginPlayback = { [weak self, weak item] in
      guard
        let self,
        let item,
        self.playbackGeneration == generation,
        self.player.currentItem === item,
        self.intendsToPlay,
        self.activeDevice != nil
      else { return }
      guard self.activatePlaybackSession() else { return }
      self.player.play()
    }
    if positionMilliseconds > 0 {
      let target = CMTime(
        seconds: Double(positionMilliseconds) / 1_000,
        preferredTimescale: 1_000
      )
      player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) {
        finished in
        if finished { beginPlayback() }
      }
    } else {
      beginPlayback()
    }
    // This acknowledges that AVPlayer accepted the request. KVO is the only
    // path that reports confirmed external playback.
    result(true)
  }

  private func play(result: @escaping FlutterResult) {
    guard player.currentItem != nil, activeDevice != nil else {
      reject(result, code: "AIRPLAY_NO_MEDIA", message: "No AirPlay media is loaded.")
      return
    }
    playbackGeneration &+= 1
    intendsToPlay = true
    guard activatePlaybackSession() else {
      reject(
        result,
        code: "AIRPLAY_AUDIO_SESSION_FAILED",
        message: "AirPlay playback could not start."
      )
      return
    }
    player.play()
    result(true)
  }

  private func pause(result: @escaping FlutterResult) {
    guard player.currentItem != nil else {
      reject(result, code: "AIRPLAY_NO_MEDIA", message: "No AirPlay media is loaded.")
      return
    }
    playbackGeneration &+= 1
    intendsToPlay = false
    player.pause()
    deactivatePlaybackSession()
    publishPlaybackState()
    result(true)
  }

  private func seek(arguments: Any?, result: @escaping FlutterResult) {
    guard
      let item = player.currentItem,
      let arguments = arguments as? [String: Any],
      let milliseconds = arguments["positionMilliseconds"] as? NSNumber,
      milliseconds.int64Value >= 0
    else {
      reject(result, code: "AIRPLAY_INVALID_SEEK", message: "The AirPlay seek request is invalid.")
      return
    }
    let target = CMTime(
      seconds: milliseconds.doubleValue / 1_000,
      preferredTimescale: 1_000
    )
    let generation = playbackGeneration
    player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) {
      [weak self, weak item]
      finished in
      DispatchQueue.main.async {
        guard
          let self,
          let item,
          self.playbackGeneration == generation,
          self.player.currentItem === item
        else {
          result(false)
          return
        }
        result(finished)
      }
    }
  }

  private func stopPlayback() {
    playbackGeneration &+= 1
    intendsToPlay = false
    player.pause()
    itemStatusObservation?.invalidate()
    itemStatusObservation = nil
    player.replaceCurrentItem(with: nil)
    mediaId = nil
    canSeek = false
    deactivatePlaybackSession()
  }

  private func disconnect() {
    stopPlayback()
    activeDevice = nil
    hadExternalPlayback = false
    routeSelectionPending = false
    phoneReturnRequested = false
    emitRoute(connected: false, device: nil)
  }

  private func observe(item: AVPlayerItem) {
    itemStatusObservation?.invalidate()
    itemStatusObservation = item.observe(\.status, options: [.initial, .new]) {
      [weak self] item, _ in
      guard let self, self.player.currentItem === item else { return }
      switch item.status {
      case .failed:
        self.failPlayback()
      case .readyToPlay:
        self.publishPlaybackState()
      case .unknown:
        self.emitPlayback(state: "loading")
      @unknown default:
        self.emitPlayback(state: "loading")
      }
    }
  }

  private func externalPlaybackChanged(_ active: Bool) {
    if active {
      hadExternalPlayback = true
      if activeDevice == nil, let device = currentAirPlayDevice() {
        acceptSelectedRoute(device)
      }
      publishPlaybackState()
      return
    }
    if hadExternalPlayback {
      if currentAirPlayDevice() == nil {
        // Pause before the system can continue the same AVPlayer item locally.
        handleRouteLoss()
      } else {
        // Removing or stopping an item ends external video playback without
        // disconnecting the system-selected AirPlay route.
        hadExternalPlayback = false
        publishPlaybackState()
      }
    } else {
      publishPlaybackState()
    }
  }

  private func audioRouteChanged() {
    let route = currentAirPlayDevice()
    if let route {
      if (activeDevice != nil && activeDevice?.id != route.id) ||
          (routeSelectionPending && route.id != routeAtPickerOpening) {
        acceptSelectedRoute(route)
      }
    } else if activeDevice != nil || (phoneReturnRequested && hasBuiltinOutput()) {
      handleRouteLoss()
    }
  }

  private func acceptSelectedRoute(_ device: AirPlayDevice) {
    routeSelectionPending = false
    phoneReturnRequested = false
    activeDevice = device
    emitRoute(connected: true, device: device)
    publishPlaybackState()
  }

  private func handleRouteLoss() {
    let confirmedPhoneReturn = phoneReturnRequested && hasBuiltinOutput()
    playbackGeneration &+= 1
    player.pause()
    intendsToPlay = false
    hadExternalPlayback = false
    activeDevice = nil
    deactivatePlaybackSession()
    routeSelectionPending = false
    phoneReturnRequested = false
    emitRoute(connected: false, device: nil, phoneOutputConfirmed: confirmedPhoneReturn)
  }

  private func hasBuiltinOutput() -> Bool {
    let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
    return !outputs.isEmpty && outputs.allSatisfy { output in
      output.portType == .builtInSpeaker || output.portType == .builtInReceiver
    }
  }

  private func currentAirPlayDevice() -> AirPlayDevice? {
    let output = AVAudioSession.sharedInstance().currentRoute.outputs.first {
      $0.portType == .airPlay
    }
    guard let output else { return nil }
    let id = output.uid.isEmpty ? "airplay:\(output.portName)" : output.uid
    return AirPlayDevice(id: id, name: output.portName)
  }

  private func publishPlaybackState() {
    guard mediaId != nil, activeDevice != nil else { return }
    guard player.currentItem?.status != .failed else {
      failPlayback()
      return
    }
    guard player.isExternalPlaybackActive else {
      emitPlayback(state: "loading")
      return
    }
    switch player.timeControlStatus {
    case .playing:
      emitPlayback(state: "playing")
    case .waitingToPlayAtSpecifiedRate:
      emitPlayback(state: "loading")
    case .paused:
      emitPlayback(state: intendsToPlay ? "loading" : "paused")
    @unknown default:
      emitPlayback(state: "loading")
    }
  }

  private func publishPosition(_ time: CMTime) {
    guard
      player.isExternalPlaybackActive,
      player.currentItem != nil,
      mediaId != nil,
      time.isNumeric
    else { return }
    send([
      "event": "position",
      "positionMilliseconds": Int64(max(0, time.seconds) * 1_000),
    ])
  }

  private func emitPlayback(state: String) {
    guard let mediaId else { return }
    let seconds = player.currentTime().isNumeric ? player.currentTime().seconds : 0
    send([
      "event": "playback",
      "state": state,
      "mediaId": mediaId,
      "positionMilliseconds": Int64(max(0, seconds) * 1_000),
      "canSeek": canSeek,
    ])
  }

  private func emitRoute(connected: Bool, device: AirPlayDevice?, phoneOutputConfirmed: Bool = false) {
    var event: [String: Any] = [
      "event": "route",
      "connected": connected,
      "phoneOutputConfirmed": phoneOutputConfirmed,
    ]
    if let device {
      event["deviceId"] = device.id
      event["deviceName"] = device.name
    }
    send(event)
  }

  private func failPlayback() {
    playbackGeneration &+= 1
    player.pause()
    intendsToPlay = false
    deactivatePlaybackSession()
    send(["event": "error", "code": "AVPlayerItemFailed"])
  }

  @discardableResult
  private func activatePlaybackSession() -> Bool {
    let session = AVAudioSession.sharedInstance()
    if ownsAudioSession {
      player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
      return true
    }
    previousAudioConfiguration = (session.category, session.mode, session.categoryOptions)
    do {
      try session.setCategory(.playback, mode: .moviePlayback)
      try session.setActive(true)
      ownsAudioSession = true
      player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
      return true
    } catch {
      restoreAudioConfiguration()
      failPlaybackWithoutDeactivation()
      return false
    }
  }

  private func deactivatePlaybackSession() {
    player.audiovisualBackgroundPlaybackPolicy = .pauses
    guard ownsAudioSession else { return }
    ownsAudioSession = false
    try? AVAudioSession.sharedInstance().setActive(
      false,
      options: .notifyOthersOnDeactivation
    )
    restoreAudioConfiguration()
  }

  private func restoreAudioConfiguration() {
    guard let configuration = previousAudioConfiguration else { return }
    previousAudioConfiguration = nil
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(configuration.0, mode: configuration.1, options: configuration.2)
    // The host configures an active shared session for local media_kit playback.
    try? session.setActive(true)
  }

  private func failPlaybackWithoutDeactivation() {
    playbackGeneration &+= 1
    player.pause()
    intendsToPlay = false
    player.audiovisualBackgroundPlaybackPolicy = .pauses
    send(["event": "error", "code": "AVAudioSessionFailed"])
  }

  private func send(_ event: [String: Any]) {
    guard let eventSink else { return }
    if Thread.isMainThread {
      eventSink(event)
    } else {
      DispatchQueue.main.async { eventSink(event) }
    }
  }

  private func reject(
    _ result: @escaping FlutterResult,
    code: String,
    message: String
  ) {
    result(FlutterError(code: code, message: message, details: nil))
  }

  private func disposeBridge() {
    phoneReturnRequested = false
    stopPlayback()
    observations.forEach { $0.invalidate() }
    observations.removeAll()
    if let routeChangeToken {
      NotificationCenter.default.removeObserver(routeChangeToken)
    }
    routeChangeToken = nil
    if let positionObserver {
      player.removeTimeObserver(positionObserver)
    }
    positionObserver = nil
    activeDevice = nil
    hadExternalPlayback = false
    routeSelectionPending = false
    routeSelectionGeneration &+= 1
    initialized = false
  }

  deinit {
    disposeBridge()
  }
}

private struct AirPlayDevice {
  let id: String
  let name: String
}

private final class AirPlayRoutePickerFactory: NSObject, FlutterPlatformViewFactory {
  private let plugin: AirPlayPlugin
  private let messenger: FlutterBinaryMessenger

  init(plugin: AirPlayPlugin, messenger: FlutterBinaryMessenger) {
    self.plugin = plugin
    self.messenger = messenger
    super.init()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    AirPlayRoutePickerPlatformView(
      frame: frame,
      viewId: viewId,
      plugin: plugin,
      messenger: messenger
    )
  }
}

private final class AirPlayRoutePickerPlatformView: NSObject, FlutterPlatformView,
  AVRoutePickerViewDelegate
{
  private let container: AirPlayRoutePickerContainer
  private let plugin: AirPlayPlugin
  private let channel: FlutterMethodChannel

  init(
    frame: CGRect,
    viewId: Int64,
    plugin: AirPlayPlugin,
    messenger: FlutterBinaryMessenger
  ) {
    self.plugin = plugin
    channel = FlutterMethodChannel(
      name: "streampilot/airplay/route_picker/\(viewId)",
      binaryMessenger: messenger
    )
    container = AirPlayRoutePickerContainer(frame: frame)
    super.init()
    container.routePicker.delegate = self
    plugin.attachPlayer(to: container.playerLayer)
  }

  func view() -> UIView { container }

  func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
    plugin.pickerWillOpen(channel: channel)
  }

  func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
    plugin.pickerDidClose(channel: channel)
  }

  deinit {
    container.routePicker.delegate = nil
    container.playerLayer.player = nil
  }
}

private final class AirPlayRoutePickerContainer: UIView {
  let routePicker = AVRoutePickerView(frame: .zero)

  override class var layerClass: AnyClass { AVPlayerLayer.self }

  var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    playerLayer.backgroundColor = UIColor.clear.cgColor
    routePicker.backgroundColor = .clear
    routePicker.tintColor = .white
    routePicker.activeTintColor = .systemBlue
    routePicker.prioritizesVideoDevices = true
    addSubview(routePicker)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    routePicker.frame = bounds
  }
}
