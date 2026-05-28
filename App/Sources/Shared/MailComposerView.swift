import SwiftUI
import MessageUI

/// SwiftUI wrapper for MFMailComposeViewController.
///
/// Presented as a sheet. Caller is responsible for calling
/// `MFMailComposeViewController.canSendMail()` BEFORE presenting and falling
/// back to a `mailto:` URL via `UIApplication.shared.open(...)` when it
/// returns false. Apple's MessageUI header explicitly documents this fallback
/// pattern — see MFMailComposeViewController.h on the iOS 26.5 SDK.
///
/// Concurrency: the view + Coordinator are `@MainActor`, so `onDismiss` is a
/// plain main-isolated closure (NOT `@Sendable`) and call sites need no
/// `assumeIsolated` wrap. The single unavoidable bridge lives in the delegate
/// method, which MUST stay `nonisolated` because
/// `MFMailComposeViewControllerDelegate` is not `@MainActor`-annotated on the
/// iOS 26.5 SDK. UIKit invokes it on the main thread, so `assumeIsolated`
/// recovers the MainActor context the compiler can't prove through the
/// nonisolated protocol requirement.
@MainActor
struct MailComposerView: UIViewControllerRepresentable {
    let recipients: [String]
    let subject: String
    let body: String
    let attachmentData: Data?
    let attachmentMimeType: String
    let attachmentFilename: String
    let onDismiss: (MFMailComposeResult) -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.setToRecipients(recipients)
        vc.setSubject(subject)
        vc.setMessageBody(body, isHTML: false)
        if let data = attachmentData {
            vc.addAttachmentData(data, mimeType: attachmentMimeType, fileName: attachmentFilename)
        }
        vc.mailComposeDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss)
    }

    @MainActor
    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onDismiss: (MFMailComposeResult) -> Void
        init(onDismiss: @escaping (MFMailComposeResult) -> Void) {
            self.onDismiss = onDismiss
        }

        nonisolated func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: (any Error)?
        ) {
            // Required nonisolated to satisfy the (non-@MainActor) MessageUI
            // delegate protocol. UIKit guarantees this runs on the main thread,
            // so assumeIsolated recovers the MainActor context to dismiss and
            // invoke onDismiss.
            MainActor.assumeIsolated {
                controller.dismiss(animated: true) {
                    self.onDismiss(result)
                }
            }
        }
    }
}
