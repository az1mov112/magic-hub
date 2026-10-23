import SwiftUI

/// Курсы: сколько рублей стоит 1 единица валюты.
struct CurrencyRates: Codable {
    var date: Date
    var fetched: Date
    var source: String
    var rub: [String: Double]
    var names: [String: String]
}

/// Загрузка курсов ЦБ РФ (запасной источник — open.er-api.com). Кэш в rates.json, обновление раз в 6 ч.
final class CurrencyService: ObservableObject {
    static let shared = CurrencyService()

    @Published private(set) var rates: CurrencyRates?
    @Published private(set) var loading = false
    @Published private(set) var failed = false

    private let fileName = "rates.json"

    static let fallbackNames: [String: String] = [
        "RUB": "Российский рубль", "USD": "Доллар США", "EUR": "Евро", "KZT": "Казахстанский тенге",
        "CNY": "Китайский юань", "TRY": "Турецкая лира", "GBP": "Фунт стерлингов", "AED": "Дирхам ОАЭ",
        "JPY": "Японская иена", "CHF": "Швейцарский франк", "UZS": "Узбекский сум", "KGS": "Киргизский сом",
        "BYN": "Белорусский рубль", "UAH": "Украинская гривна", "GEL": "Грузинский лари", "AMD": "Армянский драм",
        "AZN": "Азербайджанский манат", "INR": "Индийская рупия", "THB": "Таиландский бат", "KRW": "Вона Республики Корея",
        "CAD": "Канадский доллар", "AUD": "Австралийский доллар", "PLN": "Польский злотый", "SEK": "Шведская крона",
        "NOK": "Норвежская крона", "CZK": "Чешская крона", "HKD": "Гонконгский доллар", "SGD": "Сингапурский доллар"
    ]

    static let popular = ["USD", "EUR", "RUB", "KZT", "CNY", "TRY", "GBP", "AED", "UZS", "KGS", "BYN", "JPY", "CHF"]

    init() {
        rates = JSONStore.load(CurrencyRates.self, from: fileName)
    }

    func refreshIfNeeded() {
        if let r = rates, Date().timeIntervalSince(r.fetched) < 6 * 3600 { return }
        refresh()
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        failed = false
        Task {
            var result: CurrencyRates?
            do {
                result = try await CurrencyService.fetchCBR()
            } catch {
                result = try? await CurrencyService.fetchFallback()
            }
            let final = result
            await MainActor.run {
                self.loading = false
                if let final {
                    self.rates = final
                    JSONStore.save(final, to: self.fileName)
                } else {
                    self.failed = true
                }
            }
        }
    }

    func name(_ code: String) -> String {
        rates?.names[code] ?? CurrencyService.fallbackNames[code] ?? code
    }

    /// Сколько рублей в 1 единице.
    func rubPer(_ code: String) -> Double? {
        if code == "RUB" { return 1 }
        return rates?.rub[code]
    }

    func convert(_ amount: Double, from: String, to: String) -> Double? {
        guard let a = rubPer(from), let b = rubPer(to), b > 0 else { return nil }
        return amount * a / b
    }

    var codes: [String] {
        let all = Set((rates?.rub.keys.map { $0 } ?? []) + ["RUB"])
        let pop = CurrencyService.popular.filter { all.contains($0) }
        let rest = all.subtracting(pop).sorted()
        return pop + rest
    }

    private static func request(_ s: String) -> URLRequest {
        var r = URLRequest(url: URL(string: s)!)
        r.timeoutInterval = 15
        r.cachePolicy = .reloadIgnoringLocalCacheData
        return r
    }

    private static func fetchCBR() async throws -> CurrencyRates {
        let (data, _) = try await URLSession.shared.data(for: request("https://www.cbr-xml-daily.ru/daily_json.js"))
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let valute = obj["Valute"] as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        var rub: [String: Double] = ["RUB": 1]
        var names: [String: String] = ["RUB": "Российский рубль"]
        for (code, value) in valute {
            guard let d = value as? [String: Any],
                  let v = (d["Value"] as? NSNumber)?.doubleValue,
                  let nominal = (d["Nominal"] as? NSNumber)?.doubleValue, nominal > 0 else { continue }
            rub[code] = v / nominal
            names[code] = (d["Name"] as? String) ?? fallbackNames[code] ?? code
        }
        guard rub.count > 2 else { throw URLError(.cannotParseResponse) }
        let date = (obj["Date"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
        return CurrencyRates(date: date, fetched: Date(), source: "ЦБ РФ", rub: rub, names: names)
    }

    private static func fetchFallback() async throws -> CurrencyRates {
        let (data, _) = try await URLSession.shared.data(for: request("https://open.er-api.com/v6/latest/RUB"))
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["rates"] as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        var rub: [String: Double] = ["RUB": 1]
        var names: [String: String] = [:]
        for (code, value) in list {
            guard let perRub = (value as? NSNumber)?.doubleValue, perRub > 0 else { continue }
            rub[code] = 1 / perRub
            names[code] = fallbackNames[code] ?? code
        }
        let ts = (obj["time_last_update_unix"] as? NSNumber)?.doubleValue
        let date = ts.map { Date(timeIntervalSince1970: $0) } ?? Date()
        return CurrencyRates(date: date, fetched: Date(), source: "open.er-api", rub: rub, names: names)
    }
}

private enum CurrencySide { case from, to }

struct CurrencyTabView: View {
    @ObservedObject private var service = CurrencyService.shared
    @ObservedObject private var prefs = Prefs.shared
    @AppStorage("currency.amount") private var amount = "1"
    @State private var picker: CurrencySide?
    @State private var search = ""

    private var amountValue: Double {
        let cleaned = amount.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: ",", with: ".")
        return Double(cleaned) ?? 0
    }

    private func format(_ v: Double) -> String {
        Fmt.number(v, maxFraction: abs(v) < 1 && v != 0 ? 4 : 2)
    }

    private var resultText: String {
        guard let r = service.convert(amountValue, from: prefs.currencyFrom, to: prefs.currencyTo) else {
            return service.loading ? "…" : "—"
        }
        return format(r)
    }

    private var unitLine: String {
        guard let r = service.convert(1, from: prefs.currencyFrom, to: prefs.currencyTo) else {
            return service.failed ? "Не удалось загрузить курсы — проверьте интернет" : "Загружаю курсы…"
        }
        return "1 \(prefs.currencyFrom) = \(format(r)) \(prefs.currencyTo)"
    }

    private var meta: String {
        if service.loading { return "обновление…" }
        guard let r = service.rates else { return "" }
        let f = DateFormatter()
        f.locale = Fmt.ru
        f.dateFormat = "dd.MM.yyyy"
        return "\(r.source) · \(f.string(from: r.date))"
    }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    column(side: .from) {
                        TextField("0", text: $amount)
                            .textFieldStyle(.plain)
                            .font(.system(size: 38, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(MH.t1)
                    }
                    Button {
                        let a = prefs.currencyFrom
                        prefs.currencyFrom = prefs.currencyTo
                        prefs.currencyTo = a
                        picker = nil
                    } label: {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(MH.card2))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(MH.t1)
                    .help("Поменять местами")
                    column(side: .to) {
                        Text(resultText)
                            .font(.system(size: 38, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(MH.t1)
                            .lineLimit(1)
                            .minimumScaleFactor(0.4)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxHeight: .infinity)
                HStack(spacing: 8) {
                    Spacer()
                    Text(unitLine).font(.system(size: 12)).foregroundStyle(MH.t3)
                    Button {
                        service.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(MH.t3)
                    .help("Обновить курсы")
                    Spacer()
                }
            }

            if let side = picker {
                pickerList(side: side)
                    .frame(maxWidth: .infinity, alignment: side == .from ? .leading : .trailing)
                    .padding(.top, 38)
            }
        }
        .onAppear { service.refreshIfNeeded() }
        .panelMeta(meta)
    }

    private func column<Content: View>(side: CurrencySide, @ViewBuilder content: () -> Content) -> some View {
        let code = side == .from ? prefs.currencyFrom : prefs.currencyTo
        return VStack(spacing: 8) {
            Button {
                search = ""
                picker = picker == side ? nil : side
            } label: {
                HStack(spacing: 8) {
                    Text(code).font(.system(size: 12, weight: .bold)).foregroundStyle(MH.t1)
                    Text(service.name(code)).font(.system(size: 12)).foregroundStyle(MH.t3).lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: picker == side ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(MH.t2)
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(MH.card2))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            content()
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 12).fill(MH.card))
        }
        .frame(maxWidth: .infinity)
    }

    private func pickerList(side: CurrencySide) -> some View {
        let q = search.trimmingCharacters(in: .whitespaces)
        let codes = service.codes.filter { code in
            q.isEmpty || code.localizedCaseInsensitiveContains(q) || service.name(code).localizedCaseInsensitiveContains(q)
        }
        let current = side == .from ? prefs.currencyFrom : prefs.currencyTo
        return VStack(spacing: 6) {
            MHSearchField(text: $search, placeholder: "Валюта")
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(codes, id: \.self) { code in
                        Button {
                            pick(code, side: side)
                        } label: {
                            HStack(spacing: 8) {
                                Text(code).font(.system(size: 12, weight: .bold)).frame(width: 36, alignment: .leading)
                                Text(service.name(code)).font(.system(size: 12)).foregroundStyle(MH.t2).lineLimit(1)
                                Spacer(minLength: 0)
                                if code == current {
                                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(MH.accent)
                                }
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: 6).fill(code == current ? MH.card3 : Color.clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(MH.t1)
                    }
                }
            }
        }
        .padding(6)
        .frame(width: 280, height: 220)
        .background(RoundedRectangle(cornerRadius: 10).fill(MH.card2))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
    }

    private func pick(_ code: String, side: CurrencySide) {
        if side == .from {
            if code == prefs.currencyTo { prefs.currencyTo = prefs.currencyFrom }
            prefs.currencyFrom = code
        } else {
            if code == prefs.currencyFrom { prefs.currencyFrom = prefs.currencyTo }
            prefs.currencyTo = code
        }
        picker = nil
    }
}
