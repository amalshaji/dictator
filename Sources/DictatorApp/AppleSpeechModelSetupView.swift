import DictatorCore
import SwiftUI

struct AppleSpeechModelSetupView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.appleSpeech.state.locales.isEmpty {
                DictatorMenuField(
                    label: "Language",
                    options: model.appleSpeech.state.locales.map {
                        .init(value: $0.identifier, label: localeDisplayName($0.identifier))
                    },
                    selection: Binding(
                        get: { model.appleSpeech.state.selectedLocaleIdentifier },
                        set: { model.selectAppleSpeechLocale($0) }
                    )
                )
            }

            Text(model.appleSpeech.statusText)
                .font(.dictatorBody(12, weight: .medium))
                .foregroundStyle(model.appleSpeech.state.readiness.isReady ? DictatorDesign.focus : .secondary)

            if case let .downloading(_, progress) = model.appleSpeech.state.readiness {
                ProgressView(value: progress)
            }
        }
        .task { await model.appleSpeech.refresh() }
    }

    private func localeDisplayName(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}
