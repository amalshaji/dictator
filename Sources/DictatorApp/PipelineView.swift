import DictatorCore
import SwiftUI

struct PipelineView: View {
    let model: AppModel
    @AppStorage("pipeline.segment") private var segment = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DictatorSegmentedSwitcher(
                label: "Pipeline stage",
                options: [
                    .init(title: "Speech to text", icon: "waveform"),
                    .init(title: "Cleanup", icon: "wand.and.stars"),
                ],
                selection: $segment
            )
            .padding(.horizontal, 42)
            .padding(.top, 28)

            if segment == 0 {
                ProvidersView(model: model)
            } else {
                CleanupView(model: model)
            }
        }
    }
}
