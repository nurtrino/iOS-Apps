import Foundation

/// Which instance is selected and who, if anyone, is signed in.
///
/// Sign-in is optional throughout: PeerTube serves its catalogue to anonymous
/// clients, so an account buys subscriptions and a library, not access. Nothing
/// in the app gates on being signed in except the subscriptions tab.
@MainActor
final class AuthStore: ObservableObject {

    static let shared = AuthStore()

    private enum Key {
        static let instanceHost = "auth.instanceHost"
    }

    @Published private(set) var instance: Instance
    @Published private(set) var user: CurrentUser?
    @Published private(set) var instanceConfig: InstanceConfig?
    @Published var signInError: String?
    @Published private(set) var isSigningIn = false

    var isSignedIn: Bool { user != nil }

    private let defaults: UserDefaults

    // Not `nonisolated`: this assigns main-actor-isolated published state.
    // Only the App constructs it, and that is already on the main actor.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Key.instanceHost)
        let candidate = stored.map(Instance.init(host:))
        instance = (candidate?.isPlausible == true) ? candidate! : .fallback
    }

    /// Point the client at the stored instance and restore any saved session.
    /// Called once at launch, before any screen loads.
    func restore() async {
        await PeerTubeAPI.shared.use(instance: instance)

        if let session = await SessionKeychain.shared.load() {
            await PeerTubeAPI.shared.restore(
                accessToken: session.accessToken,
                refreshToken: session.refreshToken
            )
            // Verifying against the server rather than trusting the stored
            // expiry: the token may have been revoked from another device, and
            // a stale "signed in" state is worse than a prompt.
            user = try? await PeerTubeAPI.shared.me()
            if user == nil {
                await clearSession()
            }
        }

        instanceConfig = try? await PeerTubeAPI.shared.config()
    }

    func switchTo(_ newInstance: Instance) async {
        guard newInstance.isPlausible, newInstance != instance else { return }
        // Signing out first: the session belongs to the instance that issued it.
        await clearSession()
        instance = newInstance
        defaults.set(newInstance.host, forKey: Key.instanceHost)
        await PeerTubeAPI.shared.use(instance: newInstance)
        instanceConfig = try? await PeerTubeAPI.shared.config()
    }

    func signIn(username: String, password: String) async {
        guard !isSigningIn else { return }
        isSigningIn = true
        signInError = nil
        defer { isSigningIn = false }

        do {
            let session = try await PeerTubeAPI.shared.signIn(
                username: username, password: password
            )
            await SessionKeychain.shared.save(session)
            user = try await PeerTubeAPI.shared.me()
        } catch {
            let apiError = APIError.from(error)
            signInError = apiError == .unauthorized
                ? "Wrong username or password."
                : apiError.message
            await clearSession()
        }
    }

    func signOut() async {
        await clearSession()
    }

    private func clearSession() async {
        await PeerTubeAPI.shared.signOut()
        await SessionKeychain.shared.clear()
        user = nil
    }
}
