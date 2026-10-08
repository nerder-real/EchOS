import SwiftUI
import UniformTypeIdentifiers

/// WebDAV 备份目标设置。地址和用户名进配置，密码存钥匙串。
struct WebDAVSettingsView: View {
    @EnvironmentObject var app: AppState
    @Binding var show: Bool
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var directory = ""
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("WebDAV 设置")
                .font(.system(size: 14, weight: .semibold))

            TextField("服务器地址", text: $url)
                .textFieldStyle(.roundedBorder)
            TextField("用户名", text: $username)
                .textFieldStyle(.roundedBorder)
            SecureField("密码（存系统钥匙串）", text: $password)
                .textFieldStyle(.roundedBorder)
            TextField("备份目录（留空默认 EchOS_Backup）", text: $directory)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("删除 WebDAV 服务器…", role: .destructive) { confirmDelete = true }
                    .disabled(app.config.webdav == nil)
                Spacer()
                Button("取消") { show = false }
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 400)
        .alert("删除 WebDAV 服务器？", isPresented: $confirmDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                app.removeWebDAVServer()
                show = false
            }
        } message: {
            Text("将移除已保存的 WebDAV 服务器设置，并清除钥匙串中的密码，不可撤销。")
        }
        .onAppear {
            if let w = app.config.webdav {
                url = w.url
                username = w.username
                password = app.webdavPassword ?? ""
                directory = w.directory
            }
        }
    }

    private func save() {
        app.saveWebDAV(url: url, username: username, password: password, directory: directory)
        show = false
    }
}
