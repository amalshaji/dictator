import DictatorCore
import SwiftUI

struct LibraryView: View {
    let model: AppModel
    @AppStorage("library.segment") private var segment = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DictatorSegmentedSwitcher(
                label: "Library section",
                options: [
                    .init(title: "Vocabulary", icon: "text.book.closed"),
                    .init(title: "Snippets", icon: "curlybraces"),
                ],
                selection: $segment
            )
            .padding(.horizontal, 42)
            .padding(.top, 28)

            if segment == 0 {
                VocabularyView(model: model)
            } else {
                SnippetsView(model: model)
            }
        }
    }
}
