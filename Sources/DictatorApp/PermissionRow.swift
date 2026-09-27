import SwiftUI

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    var actionTitle: String?
    var action: (() -> Void)?

    init(title: String, detail: String, granted: Bool, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.detail = detail
        self.granted = granted
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        if let actionTitle, let action {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.dictatorBodyLarge(weight: .medium))
                    Text(detail).font(.dictatorBody).foregroundStyle(DictatorDesign.textSecondary)
                }
                Spacer()
                Button(actionTitle, action: action)
                    .disabled(granted).dictatorButton(.secondary)
            }.padding(.vertical, 11)
        } else {
            HStack(spacing: 13) {
                Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(granted ? .green : .secondary).font(DictatorDesign.glyphFont(size: 19, weight: .regular))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.dictatorBodyLarge(weight: .semibold))
                    Text(detail).font(.dictatorBody).foregroundStyle(DictatorDesign.textSecondary)
                }
            }
        }
    }
}
