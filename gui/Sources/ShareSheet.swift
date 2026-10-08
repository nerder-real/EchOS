import SwiftUI

/// 服务器分享：勾选要导出的服务器 → 存成 .json 文件。
/// 只列点过「保存」的真实服务器，没保存的空壳不出现、也导不出去。
struct ShareSheet: View {
    @EnvironmentObject var app: AppState
    @Binding var show: Bool
    @State private var selection: Set<UUID> = []

    /// 可分享的服务器 = 已保存的（避免把没填完的空壳发出去）
    private var savable: [ServerConfig] {
        app.config.servers.filter { app.isServerSaved($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择要分享的服务器")
                .font(.system(size: 14, weight: .semibold))

            HStack(spacing: 10) {
                Button("全选") { selection = Set(savable.map(\.id)) }
                Button("清空") { selection.removeAll() }
                Spacer()
                Text("已选 \(selection.count) / \(savable.count)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .controlSize(.small)

            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(savable) { s in
                        let checked = selection.contains(s.id)
                        HStack(spacing: 8) {
                            Image(systemName: checked ? "checkmark.square.fill" : "square")
                                .foregroundColor(checked ? .accentColor : .secondary)
                            Text(s.name.isEmpty ? "未命名" : s.name)
                                .font(.system(size: 12.5))
                                .lineLimit(1)
                            Spacer()
                            Text("\(s.server):\(s.serverPort)")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(checked ? Color.accentColor.opacity(0.1) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if checked { selection.remove(s.id) } else { selection.insert(s.id) }
                        }
                    }
                    if savable.isEmpty {
                        Text("还没有已保存的服务器\n先填写参数点「保存」后再分享")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 200)

            HStack {
                Spacer()
                Button("取消") { show = false }
                Button("导出…") { export() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selection.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 400)
        .onAppear {
            // 默认全选：多数情况用户就是想把现有的都带走
            selection = Set(savable.map(\.id))
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "EchOS-服务器分享.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        app.exportSelectedServers(selection, to: url)
        show = false
    }
}
