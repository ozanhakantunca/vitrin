import Foundation
import Security

/// Accepts a socket peer only if it runs as our user and is the same code as this process.
/// Used by both ends: the app checks the CLI, the CLI checks the app.
enum CLIPeerVerification {
    @Sendable static func verify(_ fd: Int32) -> Bool {
        var uid = uid_t()
        var gid = gid_t()
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else { return false }
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0,
              Int(length) == MemoryLayout<audit_token_t>.size
        else { return false }
        if let requirement = SelfIdentity.shared.requirement {
            return peer(token, satisfies: requirement)
        }
        return DevelopmentFallback.peerHasOurExecutable(token)
    }

    /// The peer's running code (looked up by audit token, so pid reuse cannot fool it) must
    /// satisfy our own designated requirement.
    private static func peer(_ token: audit_token_t, satisfies requirement: SecRequirement) -> Bool {
        var token = token
        let tokenData = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}

/// This process's designated requirement, or nil when it has no usable signature.
private final class SelfIdentity: @unchecked Sendable {
    static let shared = SelfIdentity()
    let requirement: SecRequirement?

    private init() {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
              SecCodeCheckValidity(code, [], requirement) == errSecSuccess
        else { self.requirement = nil; return }
        self.requirement = requirement
    }
}

/// DEVELOPMENT ONLY. Used solely when this process has no usable code signature (e.g. an
/// unsigned `swift build` binary): the peer must run the exact executable file we run.
/// Signed builds, including ad-hoc ones, never take this path.
private enum DevelopmentFallback {
    static let pathBufferSize = 4 * Int(MAXPATHLEN) // PROC_PIDPATHINFO_MAXSIZE, a macro Swift does not import
    static let ownExecutable: String? = {
        var buffer = [CChar](repeating: 0, count: pathBufferSize)
        guard proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return resolved(String(cString: buffer))
    }()

    static func peerHasOurExecutable(_ token: audit_token_t) -> Bool {
        var token = token
        var buffer = [CChar](repeating: 0, count: pathBufferSize)
        guard let ownExecutable, proc_pidpath_audittoken(&token, &buffer, UInt32(buffer.count)) > 0 else { return false }
        return resolved(String(cString: buffer)) == ownExecutable
    }

    private static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}
