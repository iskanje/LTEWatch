import SwiftUI
import Charts

@main
struct LTEWatchApp: App {
    @StateObject private var monitor = Monitor()
    var body: some Scene {
        MenuBarExtra {
            MenuContent(monitor: monitor)
        } label: {
            Image(systemName: "antenna.radiowaves.left.and.right")
            Text(monitor.menuLabel).monospacedDigit()
        }.menuBarExtraStyle(.menu)
        Window("Connection History", id: "history") {
            HistoryView(monitor: monitor)
        }.defaultSize(width: 940, height: 830)
        Window("LTEWatch Settings", id: "settings") {
            SettingsView(monitor: monitor)
        }.defaultSize(width: 520, height: 465).windowResizability(.contentSize)
    }
}

func formatted(_ value: Double?, digits: Int = 0) -> String {
    value.map { String(format: "%.*f", digits, $0) } ?? "—"
}

func statusColor(_ level: ConnectionStatus.Level) -> NSColor {
    switch level {
    case .neutral: return .systemGray
    case .ok: return .systemGreen
    case .warning: return .systemOrange
    case .problem: return .systemRed
    }
}

extension Monitor {
    var connectionStatus: ConnectionStatus { ConnectionStatus(latest, routerEnabled: configuration.routerEnabled) }
}

/// Standard menu bar menu: one status line, one detail line, then actions.
struct MenuContent: View {
    @ObservedObject var monitor: Monitor
    @Environment(\.openWindow) private var openWindow
    private func open(_ id: String) { NSApplication.shared.activate(ignoringOtherApps: true); openWindow(id: id) }
    private var detail: String {
        if monitor.busy { return "Checking…" }
        guard let latest = monitor.latest else { return "The first check starts shortly" }
        let ping = latest.ping.map { "\(Int($0.rounded())) ms" } ?? "No ping replies"
        return "\(ping) · checked \(latest.date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))"
    }
    private var statusDot: Image {
        let color = statusColor(monitor.connectionStatus.level)
        let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .regular).applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = false
        return Image(nsImage: image)
    }
    var body: some View {
        Button { open("history") } label: { Label { Text(monitor.connectionStatus.title) } icon: { statusDot } }
        Text(detail)
        Divider()
        if monitor.busy {
            Button("Stop Check") { monitor.cancel() }
        } else {
            Button("Check Now") { monitor.startCheck() }
        }
        Divider()
        Button("Show History…") { open("history") }
        Button("Settings…") { open("settings") }
        Divider()
        Button("Quit LTEWatch") { monitor.quit() }
    }
}

struct Metric: View {
    let title: String
    let value: String
    let unit: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value).font(.system(size: 28, weight: .medium, design: .rounded)).monospacedDigit()
                if value != "—" { Text(unit).font(.caption).foregroundStyle(.secondary) }
            }
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ChartMeasurement: Identifiable {
    let sample: Sample
    let label: String
    let value: Double
    let unit: String
    var id: String { "\(sample.id)-\(label)" }
    var displayValue: String { label == "No reply" ? "100% packet loss" : "\(formatted(value, digits: 1)) \(unit)" }
    var tooltip: String { "\(label): \(displayValue)\n\(sample.date.formatted(date: .abbreviated, time: .standard))" }
}

private struct MeasurementTooltips: View {
    let proxy: ChartProxy
    let points: [ChartMeasurement]

    var body: some View {
        GeometryReader { geometry in
            if let anchor = proxy.plotFrame {
                let plot = geometry[anchor]
                ZStack(alignment: .topLeading) {
                    ForEach(points) { point in
                        if let position = position(of: point, plot: plot) {
                            // Only this point's 44 × 44 pt target provides a native tooltip.
                            Color.clear
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                                .help(point.tooltip)
                                .accessibilityLabel(point.tooltip)
                                .position(position)
                        }
                    }
                }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            }
        }
    }

    private func position(of point: ChartMeasurement, plot: CGRect) -> CGPoint? {
        guard let x = proxy.position(forX: point.sample.date), let y = proxy.position(forY: point.value),
              x.isFinite, y.isFinite, x >= 0, x <= plot.width, y >= 0, y <= plot.height else { return nil }
        return CGPoint(x: plot.minX + x, y: plot.minY + y)
    }
}

struct HistoryView: View {
    @ObservedObject var monitor: Monitor
    @State private var rangeHours = 6
    @AppStorage("showSignalThresholds") private var showThresholds = true
    @State private var signalMetric = "RSRP"
    private var cutoff: Date { Date().addingTimeInterval(-Double(rangeHours) * 3600) }
    private var samples: [Sample] { monitor.samples.filter { $0.date >= cutoff } }
    private var idle: [Sample] { samples.filter { $0.kind != "live" } }
    private var latencyPoints: [ChartMeasurement] {
        idle.flatMap { sample -> [ChartMeasurement] in
            var points: [ChartMeasurement] = []
            if let value = sample.ping { points.append(ChartMeasurement(sample: sample, label: "Internet ping", value: value, unit: "ms")) }
            if let value = sample.gatewayPing { points.append(ChartMeasurement(sample: sample, label: "Router ping", value: value, unit: "ms")) }
            if sample.loss == 100 { points.append(ChartMeasurement(sample: sample, label: "No reply", value: 0, unit: "%")) }
            return points
        }
    }
    private var signalPoints: [ChartMeasurement] {
        idle.compactMap { sample in
            guard let value = signal(sample) else { return nil }
            return ChartMeasurement(sample: sample, label: signalMetric, value: value, unit: signalMetric == "RSRP" ? "dBm" : "dB")
        }
    }
    private var radio: Radio? { monitor.latest?.radio }
    private func signal(_ sample: Sample) -> Double? {
        switch signalMetric { case "RSRQ": return sample.radio?.rsrq; case "SNR": return sample.radio?.snr; default: return sample.radio?.rsrp }
    }
    private var signalScale: SignalScale { SignalScale.of(signalMetric) }
    private var signalDomain: ClosedRange<Double> { signalScale.domain(including: idle.compactMap { signal($0) }) }
    private func thresholdLabel(_ value: Double) -> String {
        let number = value.formatted(.number.precision(.fractionLength(0...1)))
        return value == signalScale.excellent ? "Excellent ≥ \(number)" : "Good ≥ \(number)"
    }
    private func segments(_ key: (Sample) -> Double?) -> [(Sample, Int)] {
        var series = 0
        var previous: Date?
        return idle.map { s in
            if key(s) == nil || (previous.map { s.date.timeIntervalSince($0) > Double(monitor.configuration.intervalMinutes * 120) } ?? false) { series += 1 }
            previous = s.date
            return (s, series)
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                HStack(spacing: 24) {
                    Metric(title: "Ping", value: formatted(monitor.latest?.ping), unit: "ms", detail: "\(monitor.configuration.pingHost) · 4 pings")
                    Metric(title: "LTE Signal", value: formatted(radio?.rsrp), unit: "dBm", detail: radio == nil ? "No current reading" : "Strength · higher is better")
                }.padding(.vertical, 6)
                Divider()
                if monitor.busy {
                    HStack { ProgressView().controlSize(.small); Text(monitor.status); Spacer() }
                }
                if let error = monitor.saveError { banner(error, icon: "xmark.octagon.fill", tint: .red) { monitor.saveError = nil } }
                if let notice = monitor.exportNotice { banner(notice, icon: "checkmark.circle.fill", tint: .green) { monitor.exportNotice = nil } }
                if let message = monitor.message { banner(message, icon: "exclamationmark.triangle.fill", tint: .orange) { monitor.message = nil } }
                HStack {
                    Text("History").font(.headline)
                    Spacer()
                    Picker("Time range", selection: $rangeHours) { Text("6 hours").tag(6); Text("24 hours").tag(24); Text("7 days").tag(168); Text("30 days").tag(720) }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 340)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text("Ping").font(.subheadline.bold()); Text("ms · lower is better").font(.caption).foregroundStyle(.secondary); Spacer(); legend("Internet", .teal); legend("Router", .gray) }
                    Chart {
                        ForEach(segments { $0.ping }, id: \.0.id) { s, segment in
                            if let value = s.ping {
                                LineMark(x: .value("Time", s.date), y: .value("Internet ping", value), series: .value("Segment", "internet\(segment)"))
                                    .foregroundStyle(.teal).lineStyle(StrokeStyle(lineWidth: 1.5))
                                PointMark(x: .value("Time", s.date), y: .value("Internet ping", value)).foregroundStyle(.teal).symbolSize(32)
                            }
                        }
                        ForEach(segments { $0.gatewayPing }, id: \.0.id) { s, segment in
                            if let value = s.gatewayPing {
                                LineMark(x: .value("Time", s.date), y: .value("Router ping", value), series: .value("Segment", "router\(segment)"))
                                    .foregroundStyle(.gray).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                PointMark(x: .value("Time", s.date), y: .value("Router ping", value)).foregroundStyle(.gray).symbolSize(26)
                            }
                        }
                        ForEach(idle.filter { $0.loss == 100 }) { s in
                            PointMark(x: .value("Time", s.date), y: .value("No reply", 0)).symbol(.cross).foregroundStyle(.red).symbolSize(35)
                        }
                    }.chartXScale(domain: cutoff...Date()).chartXAxis { timeAxis }
                        .chartOverlay { proxy in MeasurementTooltips(proxy: proxy, points: latencyPoints) }
                        .overlay { if !idle.contains(where: { $0.ping != nil }) { empty("No ping measurements in this time range.") } }
                        .frame(height: 125)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("LTE Signal").font(.subheadline.bold()).fixedSize()
                        Text("\(signalScale.name) · \(signalScale.unit) · higher is better")
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help("Bands show approximate TP-Link guidance: green is excellent, light green is good, orange is poor. Signal readings alone do not predict bandwidth.")
                        Spacer()
                        Toggle("Thresholds", isOn: $showThresholds).toggleStyle(.checkbox)
                            .help("Show the excellent, good and poor ranges on the chart")
                        Picker("LTE measurement", selection: $signalMetric) { Text("Strength").tag("RSRP"); Text("Quality").tag("RSRQ"); Text("Signal-to-Noise").tag("SNR") }
                            .labelsHidden().pickerStyle(.segmented).frame(width: 300)
                    }
                    Chart {
                        // Threshold bands sit behind the readings: excellent, good, poor.
                        let scale = signalScale, domain = signalDomain, start = cutoff, end = Date()
                        if showThresholds {
                            RectangleMark(xStart: .value("Time", start), xEnd: .value("Time", end),
                                          yStart: .value("Band", scale.excellent), yEnd: .value("Band", domain.upperBound))
                                .foregroundStyle(.green.opacity(0.16))
                            RectangleMark(xStart: .value("Time", start), xEnd: .value("Time", end),
                                          yStart: .value("Band", scale.good), yEnd: .value("Band", scale.excellent))
                                .foregroundStyle(.green.opacity(0.07))
                            RectangleMark(xStart: .value("Time", start), xEnd: .value("Time", end),
                                          yStart: .value("Band", domain.lowerBound), yEnd: .value("Band", scale.good))
                                .foregroundStyle(.orange.opacity(0.08))
                        }
                        ForEach(segments(signal), id: \.0.id) { s, segment in
                            if let value = signal(s) {
                                LineMark(x: .value("Time", s.date), y: .value(signalMetric, value), series: .value("Segment", segment))
                                    .foregroundStyle(.indigo).lineStyle(StrokeStyle(lineWidth: 1.5))
                                PointMark(x: .value("Time", s.date), y: .value(signalMetric, value)).foregroundStyle(.indigo).symbolSize(32)
                            }
                        }
                    }.chartXScale(domain: cutoff...Date()).chartYScale(domain: signalDomain).chartXAxis { timeAxis }
                        .chartYAxis {
                            if showThresholds {
                                AxisMarks(position: .trailing, values: [signalScale.excellent, signalScale.good]) { value in
                                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.75, dash: [3, 3]))
                                    AxisValueLabel { if let v = value.as(Double.self) { Text(thresholdLabel(v)) } }
                                }
                            } else {
                                AxisMarks(position: .trailing)
                            }
                        }
                        .chartOverlay { proxy in MeasurementTooltips(proxy: proxy, points: signalPoints) }
                        .overlay {
                            if !idle.contains(where: { signal($0) != nil }) {
                                empty(monitor.configuration.routerEnabled ? "No LTE readings in this time range."
                                      : "Turn on LTE readings in Settings to collect signal measurements.")
                            }
                        }
                        .frame(height: 150)
                }
                Divider()
                footer
            }.padding(28)
        }.frame(minWidth: 940, minHeight: 680)
            .background(Color(nsColor: .windowBackgroundColor))
    }
    // Always the same two buttons: Check Now turns into Stop Check in place, so nothing shifts.
    private var actions: some View {
        HStack(spacing: 8) {
            if monitor.busy {
                Button { monitor.cancel() } label: { Label("Stop Check", systemImage: "stop.fill") }
            } else {
                Button { monitor.startCheck() } label: { Label("Check Now", systemImage: "arrow.clockwise") }
                    .help("Ping the internet and router, and read the LTE signal")
            }
            Button { monitor.exportCSV() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .disabled(monitor.samples.isEmpty)
                .help("Export all connection history as CSV")
        }.labelStyle(.titleAndIcon)
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 8) {
                Circle().fill(Color(nsColor: statusColor(monitor.connectionStatus.level))).frame(width: 10, height: 10)
                Text(monitor.connectionStatus.title).font(.title2.weight(.semibold))
                Spacer()
                actions
            }
            HStack(spacing: 4) {
                Text("Automatic ping and LTE checks · \(monitor.configuration.scheduleSummary)")
                if monitor.isPreview { Text("· Preview with synthetic example data") }
            }.font(.callout).foregroundStyle(.secondary)
                .help("Checks run while LTEWatch is running and this Mac is awake.")
        }
    }
    private var footer: some View {
        Text("\(samples.count) \(samples.count == 1 ? "observation" : "observations") in this view · Hover over a point for its value and time · Red × means no ping replies. Ping and signal show connection quality, not bandwidth.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private var timeAxis: some AxisContent {
        AxisMarks(preset: .aligned, values: .automatic(desiredCount: 5)) { _ in
            AxisGridLine()
            AxisValueLabel(format: rangeHours <= 24 ? .dateTime.hour().minute() : .dateTime.day().month(.abbreviated))
        }
    }
    private func banner(_ text: String, icon: String, tint: Color, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Dismiss")
        }.font(.callout).padding(10)
            .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
    private func legend(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) { Circle().fill(color).frame(width: 6, height: 6); Text(label).font(.caption).foregroundStyle(.secondary) }
    }
    private func empty(_ text: String) -> some View { Text(text).font(.caption).foregroundStyle(.secondary) }
}

struct SettingsView: View {
    @ObservedObject var monitor: Monitor
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var pingHost = ""
    @State private var intervalText = "30"
    @State private var routerEnabled = false
    @State private var password = ""
    @State private var error: String?
    private var interval: Int? { Configuration.parseInterval(intervalText) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Monitoring settings").font(.title2.bold())
            Form {
                TextField("Router address", text: $host).textFieldStyle(.roundedBorder)
                TextField("Internet ping target", text: $pingHost).textFieldStyle(.roundedBorder)
                LabeledContent("Check every") {
                    HStack(spacing: 8) {
                        TextField("Minutes", text: $intervalText)
                            .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 70)
                            .accessibilityLabel("Check interval in minutes")
                        Text("min (1–60)").foregroundStyle(.secondary)
                    }
                }
                if interval == nil {
                    Text("Enter a whole number from 1 to 60 minutes.").font(.caption).foregroundStyle(.red)
                }
                Toggle("Read LTE signal from router", isOn: $routerEnabled)
                SecureField("Router admin password", text: $password, prompt: Text("Leave blank to keep saved password"))
                    .textFieldStyle(.roundedBorder)
            }.disabled(monitor.busy)
            Text("The password is saved in macOS Keychain. Use the local administrator password for the router webpage.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Label("Scheduled: four pings + one LTE snapshot", systemImage: "clock")
                Label("Sleep: skip checks and leave a gap in history", systemImage: "moon")
            }.font(.callout)
            Text("Your router's compatibility will be checked on the first connection.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Text("MR600 V3 · firmware 1.3.0 / 250915").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do {
                        guard let interval else { throw AppFailure("Enter a whole number from 1 to 60 minutes.") }
                        try monitor.saveSettings(host: host, pingHost: pingHost, interval: interval, routerEnabled: routerEnabled, password: password)
                        password = ""; dismiss()
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(monitor.busy || interval == nil)
            }
        }.padding(26).frame(width: 515)
            .onAppear {
                host = monitor.configuration.routerHost; pingHost = monitor.configuration.pingHost
                intervalText = String(monitor.configuration.intervalMinutes); routerEnabled = monitor.configuration.routerEnabled
                password = ""; error = nil
            }
    }
}
