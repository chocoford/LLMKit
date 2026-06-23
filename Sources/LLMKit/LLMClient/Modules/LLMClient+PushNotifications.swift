//
//  LLMClient+PushNotifications.swift
//  LLMKit
//

import Foundation
import LLMCore
import Logging

public extension LLMClient {
    /// Restore auth/credits and then register this device's APNs token.
    ///
    /// This is a convenience for app launch when the app already has a device token. If APNs returns
    /// or refreshes the token later, call `registerPushDeviceToken(_:environment:)` directly.
    /// Push registration failure is logged and does not undo a successful restore.
    func restore(
        registeringPushDeviceToken deviceToken: Data,
        environment: PushEnvironment? = nil
    ) async {
        await restore()
        do {
            _ = try await registerPushDeviceToken(deviceToken, environment: environment)
        } catch {
            Logger(label: "LLMClient.PushNotifications")
                .error("Failed to register push device token after restore: \(error)")
        }
    }

    /// Restore auth/credits and then register this device's APNs token.
    ///
    /// Use this string overload when the app already stores the APNs token as a hexadecimal string.
    func restore(
        registeringPushDeviceToken deviceToken: String,
        environment: PushEnvironment? = nil
    ) async {
        await restore()
        do {
            _ = try await registerPushDeviceToken(deviceToken, environment: environment)
        } catch {
            Logger(label: "LLMClient.PushNotifications")
                .error("Failed to register push device token after restore: \(error)")
        }
    }

    /// Register this device's APNs token with LLMServer.
    ///
    /// This method only performs LLMServer registration. The app still owns the system
    /// notification flow:
    ///
    /// ```swift
    /// let granted = try await UNUserNotificationCenter.current().requestAuthorization(
    ///     options: [.alert, .badge, .sound]
    /// )
    /// if granted {
    ///     UIApplication.shared.registerForRemoteNotifications()
    /// }
    /// ```
    ///
    /// Then pass the APNs token from the app delegate callback to LLMKit:
    ///
    /// ```swift
    /// func application(
    ///     _ application: UIApplication,
    ///     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    /// ) {
    ///     Task {
    ///         try await llmClient.registerPushDeviceToken(deviceToken)
    ///     }
    /// }
    /// ```
    ///
    /// On macOS, use `NSApplication.shared.registerForRemoteNotifications(matching:)` and forward
    /// the `NSApplicationDelegate` APNs token callback in the same way.
    ///
    /// Call this after the client has restored or otherwise established auth. If APNs returns the
    /// token before auth is ready, cache the token and register it after `restore()`, or use
    /// `restore(registeringPushDeviceToken:environment:)` when launching with a cached token.
    ///
    /// The operation is idempotent: LLMServer upserts the token and refreshes its owner, topic,
    /// environment, and last-seen timestamp.
    ///
    /// The default environment follows the client build: `.sandbox` for DEBUG builds and
    /// `.production` otherwise. TestFlight and App Store builds use production APNs tokens.
    @discardableResult
    func registerPushDeviceToken(
        _ deviceToken: Data,
        environment: PushEnvironment? = nil
    ) async throws -> PushDeviceTokenResponse {
        try await registerPushDeviceToken(
            deviceToken.llmAPNsTokenString,
            environment: environment
        )
    }

    /// Register this device's APNs token with LLMServer.
    ///
    /// Use this string overload when the app already stores the APNs token as a hexadecimal string.
    /// See the `Data` overload for the complete App/APNs integration flow.
    @discardableResult
    func registerPushDeviceToken(
        _ deviceToken: String,
        environment: PushEnvironment? = nil
    ) async throws -> PushDeviceTokenResponse {
        let body = RegisterPushDeviceTokenRequest(
            token: deviceToken,
            platform: .apns,
            environment: environment ?? Self.defaultPushEnvironment,
            topic: nil
        )
        return try await networking.post("/push/device-tokens", body: body)
    }

    /// Disable this device's APNs token on LLMServer.
    ///
    /// Call this when the app wants to stop receiving server pushes for the current authenticated
    /// identity, for example during an explicit sign-out or notification opt-out flow.
    func unregisterPushDeviceToken(_ deviceToken: Data) async throws {
        try await unregisterPushDeviceToken(deviceToken.llmAPNsTokenString)
    }

    /// Disable this device's APNs token on LLMServer.
    ///
    /// Use this string overload when the app already stores the APNs token as a hexadecimal string.
    func unregisterPushDeviceToken(_ deviceToken: String) async throws {
        let body = UnregisterPushDeviceTokenRequest(
            token: deviceToken,
            platform: .apns
        )
        try await networking.delete("/push/device-tokens", body: body)
    }

    private static var defaultPushEnvironment: PushEnvironment {
        #if DEBUG
        return .sandbox
        #else
        return .production
        #endif
    }
}

private extension Data {
    var llmAPNsTokenString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
