import BuilderKit
import SwiftUI

/// Who's signed in. Nothing in the Builder works until HG SSO says yes.
@MainActor
final class Auth: ObservableObject {
    enum State: Equatable {
        case checking
        case signedOut(String?)   // optional message
        case signedIn(SSOUser)
    }

    @Published var state: State = .checking
    let client = SSOClient.fromBundle()
    private var recheck: Task<Void, Never>?

    var user: SSOUser? { if case .signedIn(let u) = state { return u } else { return nil } }

    init() {
        Task { await restore() }
    }

    /// Uses the stored token if HG SSO still accepts it.
    func restore() async {
        guard client.isConfigured else { state = .signedOut(SSOError.notConfigured.localizedDescription); return }
        guard let token = TokenStore.load() else { state = .signedOut(nil); return }
        do {
            state = .signedIn(try await client.verify(token: token))
            startRechecking()
        } catch let e as SSOError {
            TokenStore.clear()
            state = .signedOut(e.localizedDescription)
        } catch {
            // Offline: keep working until the token would have expired anyway.
            if let exp = SSOClient.expiry(ofToken: token), exp > Date(), let cached = Self.cachedUser() {
                state = .signedIn(cached)
                startRechecking()
            } else {
                state = .signedOut("Couldn't reach HG SSO (\(error.localizedDescription)).")
            }
        }
    }

    func signIn(username: String, password: String) async -> String? {
        do {
            let (token, user) = try await client.login(username: username, password: password)
            TokenStore.save(token)
            Self.cache(user)
            state = .signedIn(user)
            startRechecking()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func signOut() {
        recheck?.cancel()
        TokenStore.clear()
        UserDefaults.standard.removeObject(forKey: "sso.user")
        state = .signedOut(nil)
    }

    /// Every 30 minutes: a revoked, expired or de-granted account is signed out.
    private func startRechecking() {
        recheck?.cancel()
        recheck = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000)
                guard let self, let token = TokenStore.load() else { return }
                do {
                    let u = try await self.client.verify(token: token)
                    Self.cache(u)
                } catch let e as SSOError {
                    TokenStore.clear()
                    self.state = .signedOut(e.localizedDescription)
                    return
                } catch {
                    if let exp = SSOClient.expiry(ofToken: token), exp < Date() {
                        self.state = .signedOut("Your session ended. Sign in again.")
                        return
                    }
                }
            }
        }
    }

    private static func cache(_ user: SSOUser) {
        if let d = try? JSONEncoder().encode(user) { UserDefaults.standard.set(d, forKey: "sso.user") }
    }

    private static func cachedUser() -> SSOUser? {
        guard let d = UserDefaults.standard.data(forKey: "sso.user") else { return nil }
        return try? JSONDecoder().decode(SSOUser.self, from: d)
    }
}

struct SignInView: View {
    @EnvironmentObject var auth: Auth
    @State private var username = ""
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84)
            VStack(spacing: 4) {
                Text("HG Deploy Builder").font(.title.bold())
                Text("Sign in with your HG account").foregroundStyle(.secondary)
            }
            VStack(spacing: 10) {
                TextField("Username", text: $username)
                    .textContentType(.username)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .onSubmit(submit)
            }
            .textFieldStyle(.roundedBorder)
            .frame(width: 280)
            .disabled(busy || !auth.client.isConfigured)

            if let msg = error ?? initialMessage {
                Text(msg).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center).frame(maxWidth: 340)
            }
            Button(action: submit) {
                if busy { ProgressView().controlSize(.small).frame(width: 80) } else { Text("Sign In").frame(width: 80) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(busy || username.isEmpty || password.isEmpty || !auth.client.isConfigured)
            Text("HG Deploy is for HG Cellular staff. Access is managed in HG SSO.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var initialMessage: String? {
        if case .signedOut(let m) = auth.state { return m }
        return nil
    }

    private func submit() {
        guard !username.isEmpty, !password.isEmpty, !busy else { return }
        busy = true
        error = nil
        Task {
            error = await auth.signIn(username: username.trimmingCharacters(in: .whitespaces), password: password)
            if error == nil { password = "" }
            busy = false
        }
    }
}
