import SwiftUI
import ChronoscopeCore

struct TimelineControl: View {
    @Bindable var model: AtlasModel
    var compact = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var yearText = "1969"
    @State private var month = 7
    @State private var day = 20
    @State private var bce = false
    @State private var jumpOpen = false
    @State private var dateError: String?
    @State private var scrubCenter: Double = 1969

    var body: some View {
        timelineSurface
        .sheet(isPresented: $jumpOpen) { jumpEditor }
        .onChange(of: model.cursor) { model.refresh() }
        .onChange(of: model.scale) { scrubCenter = model.cursor; model.refresh() }
        .onChange(of: model.selectedID) { scrubCenter = model.cursor }
        .onAppear { scrubCenter = model.cursor }
        .task(id: model.playing) {
            guard model.playing else { return }
            while !Task.isCancelled && model.playing {
                try? await Task.sleep(for: .milliseconds(350))
                if !Task.isCancelled { model.advance() }
            }
        }
    }

    @ViewBuilder
    private var timelineSurface: some View {
        if reduceTransparency {
            controls.background(AtlasTheme.panel, in: .rect(cornerRadius: 24))
        } else if #available(iOS 26, macOS 26, *) {
            controls.glassEffect(.regular, in: .rect(cornerRadius: 24))
        } else {
            controls.background(.regularMaterial, in: .rect(cornerRadius: 24))
        }
    }

    private var controls: some View {
        VStack(spacing: compact ? 4 : 8) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    dateControl
                    windowControl.frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                HStack(spacing: 8) {
                    dateControl
                    windowControl
                }
            }
            HStack(spacing: compact ? 4 : 8) {
                transportButton("backward.end", label: "Step backward one \(stepName)") { model.advance(-1) }
                transportButton(model.playing ? "pause.fill" : "play.fill", label: model.playing ? "Pause time" : "Play through time") {
                    model.playing.toggle()
                }
                Slider(value: $model.cursor, in: scrubRange, onEditingChanged: { editing in
                    if !editing && model.scale == .all { model.scale = .century }
                })
                    .tint(AtlasTheme.cyan)
                    .frame(minHeight: 44)
                    .accessibilityLabel("Timeline cursor")
                    .accessibilityValue(model.dateLabel)
                    .accessibilityHint("From \(rangeStart) to \(rangeEnd). Adjust by one \(stepName).")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: model.advance()
                        case .decrement: model.advance(-1)
                        @unknown default: break
                        }
                    }
                transportButton("forward.end", label: "Step forward one \(stepName)") { model.advance() }
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, compact ? 8 : 10)
    }

    private var dateControl: some View {
        Button(action: openDateEditor) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.dateLabel)
                        .font(compact ? .headline : .title3.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if !compact {
                        Text("\(model.windowCount.formatted()) events in window")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Image(systemName: "calendar")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Jump to an exact date")
        .accessibilityValue(AtlasDate.formatted(model.cursor, precision: "day"))
        .accessibilityHint("Opens a date editor with CE and BCE years.")
    }

    private var windowControl: some View {
        Menu {
            Picker("Time window", selection: $model.scale) {
                ForEach(TimeScale.allCases) { Text($0.rawValue).tag($0) }
            }
        } label: {
            HStack(spacing: 5) {
                Text(model.scale.rawValue).font(.subheadline.weight(.medium)).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.primary)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Time window")
        .accessibilityValue(model.scale.rawValue)
    }

    private func transportButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .accessibilityLabel(label)
    }

    private var stepName: String { model.scale == .all ? "century" : model.scale.granularity.rawValue }
    private var rangeStart: String { AtlasDate.formatted(scrubRange.lowerBound, precision: model.scale == .day ? "day" : "year") }
    private var rangeEnd: String { AtlasDate.formatted(scrubRange.upperBound, precision: model.scale == .day ? "day" : "year") }

    private var scrubRange: ClosedRange<Double> {
        guard model.scale != .all else { return model.minimum...model.maximum }
        let center = min(model.maximum, max(model.minimum, scrubCenter))
        let low = max(model.minimum, min(model.cursor, center - model.scale.span * 5))
        let high = min(model.maximum, max(model.cursor, center + model.scale.span * 5))
        return low...max(low + 0.000001, high)
    }

    private var jumpEditor: some View {
        NavigationStack {
            Form {
                Section("Date") {
                    TextField("Year", text: $yearText)
                        .keyboardType(.numberPad)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Year")
                    Picker("Era", selection: $bce) {
                        Text("CE").tag(false)
                        Text("BCE").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(minHeight: 44)
                    Picker("Month", selection: $month) {
                        ForEach(1...12, id: \.self) { value in
                            Text(Self.monthNames[value - 1]).tag(value)
                        }
                    }
                    Stepper("Day: \(day)", value: $day, in: 1...31)
                        .frame(minHeight: 44)
                }
                Section {
                    if let dateError {
                        Label(dateError, systemImage: "exclamationmark.circle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    LabeledContent("Earliest record", value: AtlasDate.formatted(model.minimum))
                    LabeledContent("Latest record", value: AtlasDate.formatted(model.maximum))
                } footer: {
                    Text("Day-level controls preserve source precision. A year-only record stays year-only.")
                }
            }
            .navigationTitle("Go to a date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { jumpOpen = false }
                        .frame(minHeight: 44)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Travel", action: travelToDate)
                        .frame(minHeight: 44)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear(perform: initializeEditorDate)
    }

    private func openDateEditor() {
        dateError = nil
        jumpOpen = true
    }

    private func initializeEditorDate() {
        if let date = AtlasDate.components(model.cursor) {
            yearText = String(date.year); month = date.month; day = date.day; bce = date.era == .bce
        }
    }

    private func travelToDate() {
        guard let year = Int(yearText), year > 0 else { dateError = "Use a positive year and choose CE or BCE."; return }
        guard let date = try? AtlasDate.civilDate(year: year, month: month, day: day, era: bce ? .bce : .ce) else { dateError = "That day does not exist in this month."; return }
        guard date >= model.minimum && date <= model.maximum else { dateError = "Date is outside the downloaded catalog’s range."; return }
        model.cursor = date; scrubCenter = date; model.scale = .day; model.refresh(); jumpOpen = false; dateError = nil
    }

    private static let monthNames = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
}
