import DictatorCore
import SwiftUI

struct ProvidersView: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Speech to text").font(.dictatorDisplay)
                    Text("Choose the speech-to-text model used for your recordings.")
                        .font(.dictatorBodyLarge).foregroundStyle(DictatorDesign.textSecondary)
                }
                ProviderPicker(model: model, purpose: .speechToText, providers: model.sttMetadata)
            }
            .frame(maxWidth: DictatorDesign.contentWidth, alignment: .leading)
            .padding(.horizontal, 42).padding(.vertical, 36)
        }
    }
}
