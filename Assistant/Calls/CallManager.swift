@preconcurrency import AVFoundation
@preconcurrency import CallKit
@preconcurrency import PushKit
@preconcurrency import TwilioVoice
import Observation
import UIKit

/// Incoming calls end to end: VoIP push → CallKit ring → Twilio call → voice agent → saved message.
@MainActor
@Observable
final class CallManager: NSObject {
    static let shared = CallManager()

    enum Registration: Equatable {
        case notConfigured, waitingForPushToken, registering, registered, failed(String)
    }

    private(set) var registration: Registration = .notConfigured
    /// The agent handling the live call, so the app can show its transcript.
    private(set) var activeAgent: VoiceAgent?

    private let provider: CXProvider
    private let callController = CXCallController()
    private var pushRegistry: PKPushRegistry?
    private var deviceToken: Data?
    private var pendingPushCompletion: (() -> Void)?

    private var invites: [UUID: CallInvite] = [:]
    private var calls: [UUID: Call] = [:]
    private var audioDevices: [UUID: CallAudioDevice] = [:]
    private var callerNumbers: [UUID: String] = [:]

    override private init() {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.phoneNumber, .generic]
        configuration.iconTemplateImageData = UIImage(systemName: "waveform")?.pngData()
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    /// Must run at launch: iOS only delivers VoIP pushes after the registry exists.
    func startListeningForCalls() {
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        pushRegistry = registry
    }

    /// Registers this phone with Twilio so calls to your number ring here.
    func register() async {
        guard TokenService.isConfigured else {
            registration = .notConfigured
            return
        }
        guard let deviceToken else {
            registration = .waitingForPushToken
            return
        }
        registration = .registering
        do {
            let token = try await TokenService.fetch()
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                TwilioVoiceSDK.register(accessToken: token, deviceToken: deviceToken) { error in
                    if let error { done.resume(throwing: error) } else { done.resume() }
                }
            }
            registration = .registered
        } catch {
            registration = .failed(error.localizedDescription)
        }
    }

    // MARK: Call lifecycle

    private func reportIncoming(_ invite: CallInvite) {
        let number = invite.customParameters?["caller"] ?? invite.from ?? "Unknown"
        invites[invite.uuid] = invite
        callerNumbers[invite.uuid] = number

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .phoneNumber, value: number)
        update.localizedCallerName = number
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsDTMF = false
        update.supportsGrouping = false
        update.supportsUngrouping = false

        provider.reportNewIncomingCall(with: invite.uuid, update: update) { [weak self] error in
            Task { @MainActor in
                if error != nil { self?.invites[invite.uuid] = nil }
                self?.pendingPushCompletion?()
                self?.pendingPushCompletion = nil
            }
        }
    }

    private func answer(_ uuid: UUID) -> Bool {
        guard let invite = invites.removeValue(forKey: uuid) else { return false }
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat)

        let device = CallAudioDevice(listenIn: AppSettings.shared.listenIn)
        audioDevices[uuid] = device
        TwilioVoiceSDK.audioDevice = device

        let options = AcceptOptions(callInvite: invite) { builder in
            builder.uuid = invite.uuid
        }
        calls[uuid] = invite.accept(options: options, delegate: self)
        return true
    }

    private func runAgent(for uuid: UUID) {
        guard let device = audioDevices[uuid], activeAgent == nil else { return }
        let number = callerNumbers[uuid]
        let agent = VoiceAgent(io: device, owner: AppSettings.shared.ownerName, callerNumber: number)
        activeAgent = agent

        Task {
            let transcript = await agent.run()
            // The agent finished (message taken): hang up our side.
            if calls[uuid] != nil {
                callController.request(CXTransaction(action: CXEndCallAction(call: uuid))) { _ in }
            }
            activeAgent = nil
            await MessageStore.shared.save(
                transcript: transcript, callerNumber: number, startedAt: agent.startedAt, isTest: false)
        }
    }

    private func cleanUp(_ uuid: UUID) {
        invites[uuid] = nil
        calls[uuid] = nil
        audioDevices[uuid] = nil
        callerNumbers[uuid] = nil
    }
}

// MARK: - PushKit

extension CallManager: @preconcurrency PKPushRegistryDelegate {
    func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
        deviceToken = credentials.token
        Task { await register() }
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        deviceToken = nil
        registration = .waitingForPushToken
    }

    func pushRegistry(
        _ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType, completion: @escaping () -> Void
    ) {
        // iOS requires every VoIP push to report a call before `completion` runs.
        pendingPushCompletion = completion
        if !TwilioVoiceSDK.handleNotification(payload.dictionaryPayload, delegate: self, delegateQueue: .main) {
            pendingPushCompletion = nil
            completion()
        }
    }
}

// MARK: - Twilio

extension CallManager: @preconcurrency NotificationDelegate {
    func callInviteReceived(callInvite: CallInvite) {
        reportIncoming(callInvite)
    }

    func cancelledCallInviteReceived(cancelledCallInvite: CancelledCallInvite, error: Error) {
        // The caller hung up before anyone answered.
        guard let (uuid, _) = invites.first(where: { $0.value.callSid == cancelledCallInvite.callSid }) else { return }
        provider.reportCall(with: uuid, endedAt: .now, reason: .remoteEnded)
        cleanUp(uuid)
    }
}

extension CallManager: @preconcurrency CallDelegate {
    func callDidConnect(call: Call) {
        guard let uuid = call.uuid else { return }
        runAgent(for: uuid)
    }

    func callDidFailToConnect(call: Call, error: Error) {
        guard let uuid = call.uuid else { return }
        provider.reportCall(with: uuid, endedAt: .now, reason: .failed)
        cleanUp(uuid)
    }

    func callDidDisconnect(call: Call, error: Error?) {
        guard let uuid = call.uuid else { return }
        // The caller hung up mid-conversation; the agent saves what it has.
        activeAgent?.hangUp()
        if calls[uuid] != nil {
            provider.reportCall(with: uuid, endedAt: .now, reason: error == nil ? .remoteEnded : .failed)
        }
        cleanUp(uuid)
    }
}

// MARK: - CallKit

extension CallManager: @preconcurrency CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        activeAgent?.hangUp()
        for call in calls.values { call.disconnect() }
        for uuid in Array(invites.keys) + Array(calls.keys) { cleanUp(uuid) }
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        answer(action.callUUID) ? action.fulfill() : action.fail()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        let uuid = action.callUUID
        if let invite = invites[uuid] {
            invite.reject()
        } else if let call = calls[uuid] {
            activeAgent?.hangUp()
            call.disconnect()
        }
        cleanUp(uuid)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        for device in audioDevices.values { device.audioSessionActivated() }
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        for device in audioDevices.values { device.audioSessionDeactivated() }
    }
}
