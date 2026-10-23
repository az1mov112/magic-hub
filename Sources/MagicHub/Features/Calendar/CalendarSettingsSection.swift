import SwiftUI

struct CalendarSettingsSection: View {
    @ObservedObject private var prefs = Prefs.shared
    @State private var tokenInput = ""
    @State private var hasToken = NotionService.shared.token != nil
    @State private var checkOK = false
    @State private var checkText = ""
    @State private var checking = false

    var body: some View {
        SettingsSection("Календарь") {
            SettingsSegmentRow("Источник",
                               options: [(CalendarSource.notion, "Notion"), (CalendarSource.mac, "Календарь Mac")],
                               selection: $prefs.calendarSource)

            SettingsRow("Токен Notion",
                        subtitle: hasToken ? "Сохранён в Связке ключей" : "Не задан",
                        subtitleColor: hasToken ? MH.green : MH.t3) {
                HStack(spacing: 6) {
                    SecureField(hasToken ? "Заменить токен" : "ntn_… или secret_…", text: $tokenInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 8)
                        .frame(width: 180, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7).fill(MH.card2))
                    Button("Сохранить") { saveToken() }
                        .buttonStyle(MHButtonStyle(kind: .prominent))
                        .disabled(tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if hasToken {
                        Button("Удалить") {
                            Keychain.set(nil, for: NotionService.tokenAccount)
                            hasToken = false
                            checkText = ""
                        }
                        .buttonStyle(MHButtonStyle(kind: .destructive))
                    }
                }
            }

            SettingsRow("База задач", subtitle: "Ссылка на базу в Notion: ••• → Copy link") {
                TextField("https://www.notion.so/…", text: $prefs.notionDatabase)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .frame(width: 260, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7).fill(MH.card2))
            }

            SettingsRow("Подключение",
                        subtitle: checkText.isEmpty ? "Проверьте, что задачи загружаются" : checkText,
                        subtitleColor: checkText.isEmpty ? MH.t3 : (checkOK ? MH.green : MH.red)) {
                Button(checking ? "Проверяю…" : "Проверить") { check() }
                    .buttonStyle(MHButtonStyle())
                    .disabled(checking)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Как подключить Notion")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MH.t1)
                Text("1. Откройте notion.so/my-integrations → New integration → скопируйте Internal Integration Secret и вставьте в поле «Токен Notion».\n2. В базе задач: ••• → Connections → добавьте эту интеграцию.\n3. Скопируйте ссылку на базу и вставьте в поле «База задач».")
                    .font(.system(size: 11))
                    .foregroundStyle(MH.t3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func saveToken() {
        let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        Keychain.set(token, for: NotionService.tokenAccount)
        hasToken = true
        tokenInput = ""
        AppModel.shared.flash("Токен сохранён")
        NotionService.shared.refresh(force: true)
    }

    private func check() {
        checking = true
        checkText = ""
        Task {
            let result = await NotionService.shared.testConnection()
            await MainActor.run {
                checkOK = result.0
                checkText = result.1
                checking = false
            }
        }
    }
}
