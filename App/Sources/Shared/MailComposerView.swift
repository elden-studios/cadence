import SwiftUI
import MessageUI

/// SwiftUI wrapper for MFMailComposeViewController.
///
/// Presented as a sheet. Caller is responsible for calling
/// `MFMailComposeViewController.canSendMail()` BEFORE presenting and falling
/// back to a `mailto:` URL via `UIApplication.shared.open(...)` when it
/// returns false. Apple's MessageUI header explicitly documents this fallback
/// pattern — see MFMailComposeViewController.h on the iOS 26.5 SDK.
struct MailComposerView: UIViewControllerRepresentable {
    let recipients: [String]
    let subject: String
    let body: String
    let attachmentData: Data?
    let attachmentMimeType: String
    let attachmentFilename: String
    let onDismiss: @Sendable (MFMailComposeResult) -> Void

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

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onDismiss: @Sendable (MFMailComposeResult) -> Void
        init(onDismiss: @escaping @Sendable (MFMailComposeResult) -> Void) {
            self.onDismiss = onDismiss
        }
        nonisolated func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: (any Error)?
        ) {
            // UIKit guarantees this delegate runs on the main thread, but the
            // @objc protocol isn't @MainActor-annotated, so we hop explicitly
            // to call dismiss (a @MainActor API).
            let onDismiss = self.onDismiss
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Wrap BOTH the dismiss call AND the completion body in
                    // assumeIsolated. UIKit guarantees the completion runs on
                    // the main thread but its closure type isn't declared
                    // @MainActor — without this inner assumeIsolated, the
                    // consumer's onDismiss closure (which is @Sendable and
                    // typically touches @State) would be relying on the
                    // outer hop alone, which doesn't cover deferred work.
                    // Future-proofs against SDK annotation changes too.
                    controller.dismiss(animated: true) {
                        MainActor.assumeIsolated { onDismiss(result) }
                    }
                }
            }
        }
    }
}
