import SwiftUI

struct OnboardingView: View {
    @ObservedObject var permissions: PermissionManager
    var onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "Welcome to Vitrin"))
                .font(.title2.bold())
            Text(String(localized: "Vitrin needs a couple of permissions to list and switch between your windows."))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            PermissionRow(
                title: String(localized: "Accessibility"),
                badge: String(localized: "Required"),
                detail: String(localized: "Lets Vitrin see your windows and bring the one you choose to the front."),
                granted: permissions.accessibilityGranted,
                action: permissions.requestAccessibility
            )

            PermissionRow(
                title: String(localized: "Screen Recording"),
                badge: String(localized: "Optional"),
                detail: String(localized: "Used for live window thumbnails. Without it, Vitrin falls back to app icons."),
                granted: permissions.screenRecordingGranted,
                action: permissions.requestScreenRecording
            ) {
                if permissions.screenRecordingRequested && !permissions.screenRecordingGranted
                    && Bundle.main.bundlePath.hasSuffix(".app") {
                    HStack {
                        Text(String(localized: "After granting, Vitrin must restart for this to take effect."))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(String(localized: "Restart Vitrin")) { permissions.relaunch() }
                    }
                }
            }

            HStack {
                Spacer()
                Button(String(localized: "Continue"), action: onContinue)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!permissions.accessibilityGranted)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

private struct PermissionRow<Extra: View>: View {
    let title: String
    let badge: String
    let detail: String
    let granted: Bool
    let action: () -> Void
    let extra: Extra

    init(title: String, badge: String, detail: String, granted: Bool,
         action: @escaping () -> Void, @ViewBuilder extra: () -> Extra) {
        self.title = title
        self.badge = badge
        self.detail = detail
        self.granted = granted
        self.action = action
        self.extra = extra()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundColor(granted ? .green : .orange)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(title).font(.headline)
                        Text(badge).font(.caption).foregroundColor(.secondary)
                    }
                    Text(detail)
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if granted {
                    Text(String(localized: "Granted")).foregroundColor(.green)
                } else {
                    Button(String(localized: "Grant…"), action: action)
                }
            }
            extra
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
    }
}

extension PermissionRow where Extra == EmptyView {
    init(title: String, badge: String, detail: String, granted: Bool, action: @escaping () -> Void) {
        self.init(title: title, badge: badge, detail: detail, granted: granted, action: action) {
            EmptyView()
        }
    }
}
