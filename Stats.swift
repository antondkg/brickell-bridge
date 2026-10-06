import Foundation
import SwiftUI

// MARK: - Opening history (shared API)

/// One bridge opening. `end` is nil while the bridge is still up.
struct Opening: Codable, Equatable {
    var start: Date
    var end: Date?
}

/// FL511 has no history feed, so a small Cloudflare Worker (see `api/`) polls it every 15 seconds
/// and records every opening. Everyone running the app reads the same history from it.
final class EventLog: ObservableObject {
    @Published private(set) var openings: [Opening] = []
    @Published private(set) var trackingSince = Date()
    @Published private(set) var loaded = false
    private var timer: Timer?
    private let demo = ProcessInfo.processInfo.environment["BB_DEMO"] == "1"

    private struct Response: Decodable {
        var trackingSince: Date
        var openings: [Opening]
    }

    init() {
        if demo {
            (trackingSince, openings) = DemoData.make()
            loaded = true
        }
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        guard !demo else { return }
        var req = URLRequest(url: StatsAPI.openingsURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.setValue("BrickellBridge-macOS", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let data, let res = try? apiDecoder.decode(Response.self, from: data) else { return }
            DispatchQueue.main.async {
                self?.trackingSince = res.trackingSince
                self?.openings = res.openings
                self?.loaded = true
            }
        }.resume()
    }
}

/// The API sends ISO 8601 dates without fractional seconds.
let apiDecoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
}()

// MARK: - Forecast (federal schedule + boats on AIS)

struct Forecast: Decodable {
    struct Boat: Decodable {
        let name: String?
        let kind: String
        let etaMin: Int?
        let side: String
    }
    /// South Miami Avenue isn't on FL511; the server estimates it from Brickell, SW 2nd Ave and AIS.
    struct SouthMiami: Decodable {
        let state: String       // "likely-up" | "opening-soon" | "likely-down"
        let confidence: String
        let reason: String
    }
    /// An upstream bridge opened and Brickell hasn't yet: a boat is probably coming down the river.
    struct Upstream: Decodable {
        let from: String
        let openedAt: Date
        let brickellExpected: Date
    }
    let mode: String            // "on-signal" | "half-hourly" | "closed-to-boats"
    let reason: String
    let modeUntil: Date?
    let nextSlots: [Date]
    let boats: [Boat]?
    let southMiami: SouthMiami?
    let upstream: Upstream?
}

final class ForecastModel: ObservableObject {
    @Published private(set) var forecast: Forecast?
    private var timer: Timer?

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        var req = URLRequest(url: StatsAPI.base.appending(path: "v1/forecast"), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.setValue("BrickellBridge-macOS", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let data, let f = try? apiDecoder.decode(Forecast.self, from: data) else { return }
            DispatchQueue.main.async { self?.forecast = f }
        }.resume()
    }
}

// MARK: - Stats math

struct Span {
    let start: Date
    let end: Date
    var minutes: Double { end.timeIntervalSince(start) / 60 }
}

/// Everything the stats section shows, derived from the log at a point in time.
/// The bridge is in Miami, so days, hours and times are Miami's no matter where the Mac is.
let miamiTZ = TimeZone(identifier: "America/New_York")!
let miamiCalendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = miamiTZ
    return c
}()

struct StatsEngine {
    let now: Date
    let cal = miamiCalendar
    let today: Date
    let nowMinute: Double
    let closed: [Span]
    let ongoing: Span?
    let firstDay: Date
    let pastDays: [Date]
    let trackingSince: Date
    private let byDay: [Date: [Span]]

    init(log: EventLog, now: Date) {
        self.now = now
        today = cal.startOfDay(for: now)
        nowMinute = now.timeIntervalSince(today) / 60
        trackingSince = log.trackingSince
        closed = log.openings.compactMap { o in o.end.map { Span(start: o.start, end: $0) } }
        ongoing = log.openings.last.flatMap { $0.end == nil ? Span(start: $0.start, end: now) : nil }
        var all = closed
        if let ongoing { all.append(ongoing) }
        byDay = Dictionary(grouping: all) { miamiCalendar.startOfDay(for: $0.start) }

        // A partial first day would skew averages, so history starts at the first full day.
        let start = cal.startOfDay(for: log.trackingSince)
        firstDay = start == log.trackingSince ? start : cal.date(byAdding: .day, value: 1, to: start)!
        var days: [Date] = []
        var d = firstDay
        while d < today {
            days.append(d)
            d = cal.date(byAdding: .day, value: 1, to: d)!
        }
        pastDays = days
    }

    func spans(on day: Date) -> [Span] { byDay[day] ?? [] }
    func minute(_ date: Date, of day: Date) -> Double { date.timeIntervalSince(day) / 60 }
    func isWeekend(_ day: Date) -> Bool { cal.isDateInWeekend(day) }
    func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }

    var hasHistory: Bool { pastDays.count >= 2 && closed.count >= 3 }
    var sameTypeDays: [Date] { pastDays.filter { isWeekend($0) == isWeekend(today) } }
    var dayTypeName: String { isWeekend(today) ? "weekend" : "weekday" }

    var durations: [Double] { closed.map(\.minutes) }
    var medianDuration: Double? { durations.isEmpty ? nil : durations.sorted()[durations.count / 2] }

    // Right now
    func chanceOfOpening(within minutes: Double) -> Double? {
        let days = sameTypeDays
        guard days.count >= 3 else { return nil }
        let hits = days.filter { d in
            spans(on: d).contains { minute($0.start, of: d) < nowMinute + minutes && minute($0.end, of: d) > nowMinute }
        }
        return Double(hits.count) / Double(days.count)
    }

    var nextOpening: Date? {
        let starts = sameTypeDays.compactMap { d in spans(on: d).map { minute($0.start, of: d) }.first { $0 >= nowMinute } }
        guard starts.count >= 3 else { return nil }
        let median = starts.sorted()[starts.count / 2]
        return today.addingTimeInterval((median / 5).rounded() * 5 * 60)
    }

    // Today
    var todaySpans: [Span] { spans(on: today) }
    var todayMinutesUp: Double { todaySpans.reduce(0) { $0 + $1.minutes } }
    var todayLongest: Span? { todaySpans.max { $0.minutes < $1.minutes } }
    var typicalCountByNow: Double? {
        let days = sameTypeDays
        guard !days.isEmpty else { return nil }
        let total = days.reduce(0) { sum, d in sum + spans(on: d).filter { minute($0.start, of: d) < nowMinute }.count }
        return Double(total) / Double(days.count)
    }

    // History
    var avgPerDay: Double? {
        pastDays.isEmpty ? nil : Double(pastDays.reduce(0) { $0 + spans(on: $1).count }) / Double(pastDays.count)
    }

    /// Average openings per (weekday, hour), weekdays in Calendar order 1 = Sunday.
    var heatmap: [Int: [Double]] {
        var out: [Int: [Double]] = [:]
        for wd in 1...7 {
            let days = pastDays.filter { cal.component(.weekday, from: $0) == wd }
            out[wd] = (0..<24).map { h in
                guard !days.isEmpty else { return 0 }
                let n = days.reduce(0) { sum, d in sum + spans(on: d).filter { Int(minute($0.start, of: d) / 60) == h }.count }
                return Double(n) / Double(days.count)
            }
        }
        return out
    }

    var busiestDay: Date? { pastDays.max { spans(on: $0).count < spans(on: $1).count } }
    var quietestDay: Date? { pastDays.min { spans(on: $0).count < spans(on: $1).count } }

    var longestQuiet: (minutes: Double, from: Date)? {
        let sorted = closed.sorted { $0.start < $1.start }
        guard sorted.count >= 2 else { return nil }
        var best: (Double, Date)?
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            let gap = b.start.timeIntervalSince(a.end) / 60
            if gap < 24 * 60, gap > (best?.0 ?? 0) { best = (gap, a.end) } // longer gaps are app downtime
        }
        return best.map { (minutes: $0.0, from: $0.1) }
    }

    func trackedDays(last n: Int) -> [Date] { (0..<n).map { day(-$0) }.filter { $0 >= firstDay && $0 < today } }

    func averages(weekend: Bool) -> (perDay: Double, length: Double)? {
        let days = pastDays.filter { isWeekend($0) == weekend }
        let spans = days.flatMap { self.spans(on: $0) }
        guard !days.isEmpty, !spans.isEmpty else { return nil }
        return (Double(spans.count) / Double(days.count), spans.reduce(0) { $0 + $1.minutes } / Double(spans.count))
    }
}

// MARK: - Formatting

enum Fmt {
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.timeZone = miamiTZ
        return f
    }()
    static let day: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEMMMd")
        f.timeZone = miamiTZ
        return f
    }()
    static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE")
        f.timeZone = miamiTZ
        return f
    }()

    static func duration(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        return m < 60 ? "\(m) min" : "\(m / 60)h \(m % 60)m"
    }

    static func hour(_ h: Int) -> String { "\(h % 12 == 0 ? 12 : h % 12) \(h < 12 ? "AM" : "PM")" }
}

// MARK: - Stats UI

private let upColor = Color.red
private let downColor = Color.green
private let countColor = Color.blue

private func shade(_ t: Double) -> Color {
    t <= 0 ? Color.primary.opacity(0.06) : countColor.opacity(0.15 + 0.85 * t)
}

private extension View {
    func cardBackground() -> some View {
        background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.07)))
    }

    func card() -> some View {
        padding(12).frame(maxWidth: .infinity, alignment: .leading).cardBackground()
    }
}

private struct SectionLabel: View {
    let title: String
    var detail: String?
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.8)
            Spacer()
            if let detail { Text(detail).font(.system(size: 10.5)) }
        }
        .foregroundStyle(.secondary)
    }
}

private struct Tile: View {
    let value: String
    var unit: String = ""
    let label: String
    var note: String?
    var noteColor: Color = .secondary
    var size: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(Text(value).font(.system(size: size, weight: .bold, design: .rounded)))\(Text(unit).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(.secondary))")
                .monospacedDigit()
            Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary)
            if let note { Text(note).font(.system(size: 10, weight: .semibold)).foregroundStyle(noteColor) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardBackground()
    }
}

private struct HLine: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

struct StatsView: View {
    let s: StatsEngine
    let state: BridgeState
    let since: Date?
    var forecast: Forecast?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            RightNow(s: s, state: state, since: since, forecast: forecast)
            TodaySection(s: s)
            if s.hasHistory {
                WeekBars(s: s)
                HeatmapSection(s: s)
                DurationSection(s: s)
                CalendarSection(s: s)
                TollSection(s: s)
                WeekdayWeekend(s: s)
                RecordsSection(s: s)
            } else {
                CollectingCard(s: s)
            }
            Text("\(s.closed.count) openings logged since \(Fmt.day.string(from: s.trackingSince)) · shared history from FL511")
                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
        }
    }
}

private struct RightNow: View {
    let s: StatsEngine
    let state: BridgeState
    let since: Date?
    let forecast: Forecast?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Right now", detail: "\(Fmt.time.string(from: s.now)) in Miami")
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(headline).font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                        Text(caption).font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if state != .up { rings }
                }
                if let note { HStack(spacing: 8) { chip; Text(note).font(.system(size: 12)) } }
                if let sm = forecast?.southMiami { SouthMiamiRow(estimate: sm) }
                if let line = forecastLine {
                    HStack(alignment: .top, spacing: 8) {
                        Text(line.tag.uppercased())
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                        Text(line.text).font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .card()
        }
    }

    /// Same wording as brickellbridge.fun: an approaching boat beats the schedule.
    private var forecastLine: (tag: String, text: String)? {
        guard let f = forecast else { return nil }
        if let boat = f.boats?.first, let eta = boat.etaMin {
            let who = boat.name.map { "\(boat.kind.capitalized) \($0)" } ?? "A \(boat.kind)"
            return ("Boat coming", "\(who) is heading for the bridge from the \(boat.side), about \(eta) min out.")
        }
        if let up = f.upstream, state != .up {
            return ("Heads up", "\(up.from) opened at \(Fmt.time.string(from: up.openedAt)), so a boat is probably coming down the river. Brickell may open around \(Fmt.time.string(from: up.brickellExpected)).")
        }
        let until = f.modeUntil.map { Fmt.time.string(from: $0) }
        switch f.mode {
        case "closed-to-boats":
            return ("No openings", "It's the \(f.reason), so it won't open for boats until \(until ?? "later"), except tugs and emergencies.")
        case "half-hourly":
            let slots = f.nextSlots.prefix(2).map { Fmt.time.string(from: $0) }
            return ("Schedule", "Weekdays it only opens on the hour and half hour. Next possible: \(slots.joined(separator: ", then ")).")
        default:
            return ("On signal", "No schedule limits right now. It can open whenever a boat signals\(until.map { ", until \($0)" } ?? "").")
        }
    }

    private var elapsed: Double { since.map { s.now.timeIntervalSince($0) / 60 } ?? 0 }

    private var headline: String {
        switch state {
        case .up: return "Up \(Fmt.duration(elapsed))"
        case .down: return since == nil ? "Down" : "Down \(Fmt.duration(elapsed))"
        case .unknown: return "No signal"
        }
    }

    private var caption: String {
        let t = since.map { Fmt.time.string(from: $0) } ?? ""
        switch state {
        case .up: return "Raised at \(t). Closed to traffic."
        case .down: return since == nil ? "Open to traffic." : "Lowered at \(t). Open to traffic."
        case .unknown: return "Can't reach FL511 right now."
        }
    }

    private var chip: some View {
        Text(state == .up ? "Back down" : "Next opening")
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background((state == .up ? upColor : countColor).opacity(0.14), in: Capsule())
            .foregroundStyle(state == .up ? upColor : countColor)
    }

    private var note: String? {
        if state == .up, let median = s.medianDuration, let since {
            let eta = since.addingTimeInterval(median * 60)
            return eta > s.now
                ? "usually around \(Fmt.time.string(from: eta)), openings last about \(Fmt.duration(median))"
                : "any minute now, it's been up longer than the usual \(Fmt.duration(median))"
        }
        if state == .down, let next = s.nextOpening {
            return "usually around \(Fmt.time.string(from: next)), about \(Fmt.duration(next.timeIntervalSince(s.now) / 60)) from now"
        }
        return nil
    }

    @ViewBuilder private var rings: some View {
        let windows: [Double] = [15, 30, 60]
        if s.chanceOfOpening(within: 15) != nil {
            HStack(spacing: 8) {
                ForEach(windows, id: \.self) { w in
                    let p = s.chanceOfOpening(within: w) ?? 0
                    VStack(spacing: 2) {
                        ZStack {
                            Circle().stroke(Color.primary.opacity(0.08), lineWidth: 5)
                            Circle().trim(from: 0, to: p)
                                .stroke(upColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Text("\(Int((p * 100).rounded()))%").font(.system(size: 10.5, weight: .bold, design: .rounded))
                        }
                        .frame(width: 40, height: 40)
                        Text("\(Int(w)) min").font(.system(size: 9.5)).foregroundStyle(.tertiary)
                    }
                    .help("\(Int((p * 100).rounded()))% of past \(s.dayTypeName)s had an opening in the next \(Int(w)) minutes")
                }
            }
        }
    }
}

private struct SouthMiamiRow: View {
    let estimate: Forecast.SouthMiami

    var body: some View {
        let (label, color): (String, Color) = {
            switch estimate.state {
            case "likely-up": return ("likely up", upColor)
            case "opening-soon": return ("may open next", .orange)
            default: return ("likely down", downColor)
            }
        }()
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(Text("South Miami Ave bridge: ").foregroundColor(.secondary))\(Text(label).fontWeight(.semibold))")
                .font(.system(size: 12))
            Text("estimated").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
            Spacer()
        }
        .help(estimate.reason)
    }
}

private struct TodaySection: View {
    let s: StatsEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Today", detail: "\(s.todaySpans.count) openings so far")
            HStack(spacing: 8) {
                Tile(value: "\(s.todaySpans.count)", label: "Openings", note: vsTypical.text, noteColor: vsTypical.color)
                    .help(s.typicalCountByNow.map { String(format: "vs %.1f by this time on a typical %@", $0, s.dayTypeName) } ?? "")
                Tile(value: "\(Int(s.todayMinutesUp.rounded()))", unit: "m", label: "Minutes up")
                Tile(value: s.todayLongest.map { "\(Int($0.minutes.rounded()))" } ?? "0", unit: "m", label: "Longest",
                     note: s.todayLongest.map { "at \(Fmt.time.string(from: $0.start))" })
                Tile(value: String(format: "%.1f", s.nowMinute > 0 ? s.todayMinutesUp / s.nowMinute * 100 : 0), unit: "%", label: "Of day up")
            }
            .fixedSize(horizontal: false, vertical: true)
            Timeline(s: s)
        }
    }

    private var vsTypical: (text: String?, color: Color) {
        guard let typical = s.typicalCountByNow else { return (nil, .secondary) }
        let diff = Int((Double(s.todaySpans.count) - typical).rounded())
        if diff > 0 { return ("▲ \(diff) more", upColor) }
        if diff < 0 { return ("▼ \(-diff) fewer", downColor) }
        return ("about usual", .secondary)
    }
}

private struct Timeline: View {
    let s: StatsEngine
    private let dayMinutes = 1440.0

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                let x = { (m: Double) in w * m / dayMinutes }
                ZStack(alignment: .leading) {
                    downColor.opacity(0.16)
                    Color.primary.opacity(0.07)
                        .frame(width: max(0, w - x(s.nowMinute)))
                        .offset(x: x(s.nowMinute))
                    ForEach(Array(s.todaySpans.enumerated()), id: \.offset) { _, span in
                        RoundedRectangle(cornerRadius: 2).fill(upColor)
                            .frame(width: max(3, x(span.minutes)))
                            .offset(x: x(s.minute(span.start, of: s.today)))
                            .help("Up \(Fmt.time.string(from: span.start)) to \(Fmt.time.string(from: span.end)) · \(Fmt.duration(span.minutes))")
                    }
                    Capsule().fill(Color.primary).frame(width: 2).offset(x: x(s.nowMinute) - 1)
                        .help("Now · \(Fmt.time.string(from: s.now))")
                }
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            .frame(height: 30)
            HStack {
                Text("12a"); Spacer(); Text("6a"); Spacer(); Text("12p"); Spacer(); Text("6p"); Spacer(); Text("12a")
            }
            .font(.system(size: 9.5)).foregroundStyle(.tertiary)
        }
    }
}

private struct WeekBars: View {
    let s: StatsEngine
    private let plot: CGFloat = 76

    var body: some View {
        let days = (0..<7).map { s.day($0 - 6) }
        let counts = days.map { s.spans(on: $0).count }
        let avg = s.avgPerDay ?? 0
        let maxC = max(Double(counts.max() ?? 1), avg, 1) * 1.08
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Openings, last 7 days", detail: "\(counts.reduce(0, +)) total · avg \(String(format: "%.1f", avg)) a day")
            VStack(spacing: 4) {
                ZStack(alignment: .bottom) {
                    HStack(alignment: .bottom, spacing: 8) {
                        ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                            let isToday = i == 6
                            let mins = s.spans(on: d).reduce(0) { $0 + $1.minutes }
                            VStack(spacing: 3) {
                                Text("\(counts[i])").font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(countColor.opacity(barOpacity(isToday: isToday, isMax: counts[i] == counts.max())))
                                    .frame(height: max(2, plot * CGFloat(Double(counts[i]) / maxC)))
                            }
                            .frame(maxWidth: .infinity)
                            .help("\(Fmt.day.string(from: d)) · \(counts[i]) openings · \(Fmt.duration(mins)) up\(isToday ? " so far" : "")")
                        }
                    }
                    if avg > 0 {
                        HLine().stroke(Color.primary.opacity(0.35), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                            .frame(height: 1)
                            .offset(y: -plot * CGFloat(avg / maxC))
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: plot + 18, alignment: .bottom)
                HStack(spacing: 8) {
                    ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                        Text(i == 6 ? "Today" : Fmt.weekday.string(from: d))
                            .font(.system(size: 10, weight: i == 6 ? .semibold : .regular))
                            .foregroundStyle(i == 6 ? .primary : .tertiary)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .card()
        }
    }
}

private func barOpacity(isToday: Bool, isMax: Bool) -> Double {
    if isToday { return 0.45 }
    return isMax ? 1 : 0.55
}

private struct HeatmapSection: View {
    let s: StatsEngine
    private let rows = [2, 3, 4, 5, 6, 7, 1] // Mon ... Sun

    var body: some View {
        let grid = s.heatmap
        let maxV = max(grid.values.flatMap { $0 }.max() ?? 1, 0.01)
        let best = rows.flatMap { wd in (0..<24).map { (wd, $0, grid[wd]?[$0] ?? 0) } }.max { $0.2 < $1.2 }
        let rush = rows.prefix(5).reduce(0.0) { sum, wd in sum + [7, 8, 17].reduce(0.0) { $0 + (grid[wd]?[$1] ?? 0) } }
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "When it opens", detail: "avg openings per hour")
            VStack(alignment: .leading, spacing: 10) {
                VStack(spacing: 2) {
                    ForEach(rows, id: \.self) { wd in
                        HStack(spacing: 2) {
                            Text(miamiCalendar.shortWeekdaySymbols[wd - 1]).font(.system(size: 9.5)).foregroundStyle(.tertiary)
                                .frame(width: 28, alignment: .leading)
                            ForEach(0..<24, id: \.self) { h in
                                let v = grid[wd]?[h] ?? 0
                                RoundedRectangle(cornerRadius: 2.5).fill(shade(v / maxV))
                                    .aspectRatio(1, contentMode: .fit)
                                    .help("\(miamiCalendar.shortWeekdaySymbols[wd - 1]) \(Fmt.hour(h)) · \(String(format: "%.1f", v)) openings on average")
                            }
                        }
                    }
                    HStack(spacing: 0) {
                        Color.clear.frame(width: 30)
                        ForEach(["12a", "6a", "12p", "6p"], id: \.self) { Text($0).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                HStack(spacing: 3) {
                    Text("Less")
                    ForEach([0, 0.25, 0.5, 0.75, 1], id: \.self) { RoundedRectangle(cornerRadius: 2.5).fill(shade($0)).frame(width: 11, height: 11) }
                    Text("More")
                }
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                HStack(alignment: .top, spacing: 8) {
                    if let best {
                        Callout(title: "Busiest: \(miamiCalendar.shortWeekdaySymbols[best.0 - 1]) \(Fmt.hour(best.1))",
                                detail: String(format: "%.1f openings that hour on average", best.2))
                    }
                    Callout(title: rush < 0.05 ? "Safest: weekday rush hours" : "Rush hours",
                            detail: rush < 0.05 ? "No openings logged 7 to 9 AM or 5 to 6 PM" : String(format: "%.1f openings per weekday at rush hour", rush / 5))
                }
            }
            .card()
        }
    }
}

private struct Callout: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DurationSection: View {
    let s: StatsEngine
    private let labels = ["0-3", "3-6", "6-9", "9-12", "12-15", "15+ min"]

    var body: some View {
        let durs = s.durations
        let buckets = (0..<6).map { b in durs.filter { min(5, Int($0 / 3)) == b }.count }
        let maxB = Double(buckets.max() ?? 1)
        let median = s.medianDuration ?? 0
        let medianBucket = min(5, Int(median / 3))
        let p90 = durs.sorted()[min(durs.count - 1, Int(Double(durs.count) * 0.9))]
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "How long it stays up", detail: "\(durs.count) openings")
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(0..<6, id: \.self) { i in
                        let pct = Int((Double(buckets[i]) / Double(durs.count) * 100).rounded())
                        VStack(spacing: 3) {
                            Text("\(pct)%").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(upColor.opacity(i == medianBucket ? 1 : 0.5))
                                .frame(height: max(2, 64 * CGFloat(Double(buckets[i]) / maxB)))
                        }
                        .frame(maxWidth: .infinity)
                        .help("\(labels[i].replacingOccurrences(of: " min", with: "")) min · \(buckets[i]) openings (\(pct)%)")
                    }
                }
                .frame(height: 84, alignment: .bottom)
                HStack(spacing: 4) {
                    ForEach(labels, id: \.self) { Text($0).frame(maxWidth: .infinity) }
                }
                .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                HStack(spacing: 14) {
                    stat("Median", Fmt.duration(median))
                    stat("90% back down in", Fmt.duration(p90))
                    stat("Avg", String(format: "%.1f min", durs.reduce(0, +) / Double(durs.count)))
                }
                .padding(.top, 4)
            }
            .card()
        }
    }

    private func stat(_ k: String, _ v: String) -> some View {
        Text("\(Text("\(k) ").foregroundColor(.secondary))\(Text(v).fontWeight(.semibold))").font(.system(size: 11.5))
    }
}

private struct CalendarSection: View {
    let s: StatsEngine

    var body: some View {
        let cal = s.cal
        let weekStart = cal.dateInterval(of: .weekOfYear, for: s.today)!.start
        let start = cal.date(byAdding: .day, value: -28, to: weekStart)!
        let cells = (0..<35).map { cal.date(byAdding: .day, value: $0, to: start)! }
        let maxC = Double(max(1, cells.filter { $0 <= s.today }.map { s.spans(on: $0).count }.max() ?? 1))
        let total = s.pastDays.reduce(0) { $0 + s.spans(on: $1).count } + s.todaySpans.count
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Last 5 weeks", detail: "openings per day")
            HStack(alignment: .center, spacing: 16) {
                HStack(spacing: 3) {
                    ForEach(0..<5, id: \.self) { w in
                        VStack(spacing: 3) {
                            ForEach(0..<7, id: \.self) { d in
                                cell(cells[w * 7 + d], maxC: maxC)
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    side("\(total)", "openings logged", big: true)
                    if let b = s.busiestDay { side("\(s.spans(on: b).count) on \(Fmt.day.string(from: b))", "busiest day") }
                    if let q = s.quietestDay { side("\(s.spans(on: q).count) on \(Fmt.day.string(from: q))", "quietest day") }
                }
            }
            .card()
        }
    }

    @ViewBuilder private func cell(_ d: Date, maxC: Double) -> some View {
        let tracked = d >= s.cal.startOfDay(for: s.trackingSince) && d <= s.today
        let n = s.spans(on: d).count
        RoundedRectangle(cornerRadius: 3.5)
            .fill(cellColor(d, tracked: tracked, ratio: Double(n) / maxC))
            .frame(width: 15, height: 15)
            .overlay(RoundedRectangle(cornerRadius: 3.5).strokeBorder(Color.primary, lineWidth: d == s.today ? 1.5 : 0))
            .help(tracked ? "\(Fmt.day.string(from: d)) · \(n) openings\(d == s.today ? " so far" : "")" : "")
    }

    private func cellColor(_ d: Date, tracked: Bool, ratio: Double) -> Color {
        if tracked { return shade(ratio) }
        if d > s.today { return .clear }
        return Color.primary.opacity(0.03) // before tracking started
    }

    private func side(_ v: String, _ k: String, big: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(v).font(.system(size: big ? 22 : 14, weight: .bold, design: .rounded)).monospacedDigit()
            Text(k).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

private struct TollSection: View {
    let s: StatsEngine

    var body: some View {
        let days = s.trackedDays(last: 30)
        let spans = days.flatMap { s.spans(on: $0) }
        let upMin = spans.reduce(0) { $0 + $1.minutes }
        let frac = upMin / Double(max(1, days.count) * 1440)
        // Arriving at a random moment during an opening of length d leaves d/2 on average, weighted by d.
        let avgWait = upMin > 0 ? spans.reduce(0) { $0 + $1.minutes * $1.minutes / 2 } / upMin : 0
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "The toll", detail: "last \(days.count) days")
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Tile(value: Fmt.duration(upMin).replacingOccurrences(of: " min", with: "m"), label: "bridge up in total", size: 22)
                        .help("Total time the bridge was up")
                    Tile(value: frac > 0 ? "1 in \(Int((1 / frac).rounded()))" : "None", label: "random crossings hit it", size: 22)
                        .help("Chance a random arrival finds the bridge up")
                }
                GridRow {
                    Tile(value: String(format: "%.1f", avgWait), unit: "m", label: "avg wait if you hit it", size: 22)
                        .help("Average remaining wait if you arrive while it's up")
                    Tile(value: String(format: "%.1f", Double(spans.count) / Double(max(1, days.count))), label: "openings per day", size: 22)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct WeekdayWeekend: View {
    let s: StatsEngine

    var body: some View {
        let wd = s.averages(weekend: false)
        let we = s.averages(weekend: true)
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Weekdays vs weekends")
            VStack(alignment: .leading, spacing: 6) {
                group("Openings / day", wd?.perDay, we?.perDay, unit: "")
                group("Avg length", wd?.length, we?.length, unit: "m").padding(.top, 4)
            }
            .card()
        }
    }

    private func group(_ title: String, _ a: Double?, _ b: Double?, unit: String) -> some View {
        let m = max(a ?? 0, b ?? 0, 0.01) * 1.1
        return VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.tertiary)
            row("Weekdays", a, m, unit: unit, opacity: 1)
            row("Weekends", b, m, unit: unit, opacity: 0.5)
        }
    }

    private func row(_ k: String, _ v: Double?, _ m: Double, unit: String, opacity: Double) -> some View {
        HStack(spacing: 10) {
            Text(k).font(.system(size: 11.5)).frame(width: 64, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    Capsule().fill(countColor.opacity(opacity)).frame(width: geo.size.width * CGFloat((v ?? 0) / m))
                }
            }
            .frame(height: 8)
            Text(v.map { String(format: "%.1f", $0) + unit } ?? "n/a").font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                .frame(width: 40, alignment: .trailing)
        }
    }
}

private struct RecordsSection: View {
    let s: StatsEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Records", detail: "since \(Fmt.day.string(from: s.trackingSince))")
            VStack(spacing: 0) {
                if let l = s.closed.max(by: { $0.minutes < $1.minutes }) {
                    row("timer", upColor, "Longest opening", when(l.start), Fmt.duration(l.minutes))
                }
                if let b = s.busiestDay {
                    row("chart.bar.fill", countColor, "Busiest day", Fmt.day.string(from: b), "\(s.spans(on: b).count)×")
                }
                if let q = s.longestQuiet {
                    row("checkmark.seal.fill", downColor, "Longest quiet stretch", "from \(when(q.from))", Fmt.duration(q.minutes))
                }
                if let f = s.closed.min(by: { $0.minutes < $1.minutes }) {
                    row("bolt.fill", countColor, "Quickest opening", when(f.start), Fmt.duration(f.minutes), last: true)
                }
            }
            .card()
        }
    }

    private func when(_ d: Date) -> String { "\(Fmt.day.string(from: d)), \(Fmt.time.string(from: d))" }

    private func row(_ icon: String, _ color: Color, _ title: String, _ sub: String, _ value: String, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
                    .frame(width: 26, height: 26).background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12.5, weight: .semibold))
                    Text(sub).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(value).font(.system(size: 15, weight: .bold, design: .rounded)).monospacedDigit()
            }
            .padding(.vertical, 7)
            if !last { Divider() }
        }
    }
}

private struct CollectingCard: View {
    let s: StatsEngine
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "History")
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "chart.bar.xaxis").font(.system(size: 22)).foregroundStyle(countColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Building your stats").font(.system(size: 13, weight: .semibold))
                    Text("FL511 doesn't keep history, so our server logs every opening around the clock. Weekly charts, patterns and records show up after a couple of days.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .card()
        }
    }
}

// MARK: - Demo data (BB_DEMO=1), used for screenshots and UI work

enum DemoData {
    static func make(now: Date = Date()) -> (Date, [Opening]) {
        var rng = SplitMix(seed: 511253)
        let cal = miamiCalendar
        let today = cal.startOfDay(for: now)
        let weekday: [Double] = [0.2, 0.1, 0.05, 0.05, 0.05, 0.15, 0.35, 0, 0, 0.7, 1, 1.1, 1.2, 1.3, 1.3, 1.1, 0.45, 0, 0.5, 0.9, 0.8, 0.6, 0.45, 0.3]
        let weekend: [Double] = [0.4, 0.25, 0.1, 0.05, 0.05, 0.1, 0.3, 0.6, 0.9, 1.3, 1.6, 1.9, 2, 2.1, 2, 1.8, 1.5, 1.2, 1, 0.9, 0.8, 0.7, 0.55, 0.45]
        let start = cal.date(byAdding: .day, value: -34, to: today)!
        var out: [Opening] = []
        for offset in 0...34 {
            let day = cal.date(byAdding: .day, value: offset, to: start)!
            let isWeekend = cal.isDateInWeekend(day)
            let weights = isWeekend ? weekend : weekday
            let count = Int(((isWeekend ? 13 : 8) + (rng.next() - 0.5) * (isWeekend ? 7 : 5)).rounded())
            var starts: [(Double, Double)] = (0..<count).map { _ in
                var r = rng.next() * weights.reduce(0, +)
                var hour = 23
                for (h, w) in weights.enumerated() { r -= w; if r <= 0 { hour = h; break } }
                let z = (-2 * Foundation.log(rng.next() + 1e-9)).squareRoot() * cos(2 * .pi * rng.next())
                return (Double(hour * 60) + rng.next() * 60, min(24, max(2, (7 * exp(0.42 * z)).rounded())))
            }
            starts.sort { $0.0 < $1.0 }
            var lastEnd = -10.0
            for (s, dur) in starts {
                let begin = max(s, lastEnd + 6)
                guard begin + dur < 1439 else { continue }
                let b = day.addingTimeInterval(begin * 60)
                let e = b.addingTimeInterval(dur * 60)
                if e < now.addingTimeInterval(-20 * 60) { out.append(Opening(start: b, end: e)) }
                lastEnd = begin + dur
            }
        }
        return (start, out)
    }

    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> Double {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
    }
}
