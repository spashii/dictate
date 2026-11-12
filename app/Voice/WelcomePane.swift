import SwiftUI
import VoiceCore

/// The first thing a Mac sees until it is activated, including an install that just updated.
struct WelcomePane: View {
    @Environment(AppModel.self) private var model
    @State private var code = ""

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("Thanks for joining the Dictate beta")
                .font(.title2.weight(.semibold))
            Text("It is free during the beta, and beta users keep it.")
                .foregroundStyle(.secondary)
            if case .pending = model.activation.state {
                pending
            } else {
                Button("Activate in Browser") { model.beginActivation() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            if let message = model.activationMessage {
                Text(message).font(.callout).foregroundStyle(.red)
            }
            Spacer()
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var pending: some View {
        VStack(spacing: 12) {
            Text("Finish in your browser")
            HStack {
                TextField("Paste activation code", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .onSubmit(submit)
                Button("Continue", action: submit)
                    .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Button("Open the page again") { model.beginActivation() }
                .buttonStyle(.link)
            if model.activation.canOfferGrace {
                Button("Can\u{2019}t reach the site? Use Dictate for 7 days") { model.useGrace() }
                    .buttonStyle(.link)
            }
        }
    }

    private func submit() {
        model.acceptActivation(text: code)
    }
}
