import SwiftUI
import ChronoscopeCore

struct BridgeView: View {
    @Bindable var model: AtlasModel
    let onWalk: (String) -> Void
    @State private var wikipedia = false
    @State private var fromTopic = "Apollo 11"
    @State private var toTopic = "Kevin Bacon"
    @State private var wikiResult: WikiBridgeResult?
    @State private var wikiError: String?
    @State private var wikiBusy = false
    @State private var selector: EndpointSelection?
    @State private var wikiService = WikipediaBridgeService()
    @State private var wikiTask: Task<Void, Never>?
    @State private var localTask: Task<Void, Never>?
    @FocusState private var focusedTopic: TopicField?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Follow a thread through history.")
                        .font(.title2.weight(.semibold))
                    Text("Choose two topics, discover a trail, and inspect why each connection exists.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section {
                Picker("Search in", selection: $wikipedia) {
                    Text("Events").tag(false)
                    Text("Wikipedia").tag(true)
                }
                .pickerStyle(.segmented)
                .disabled(searching)
                .accessibilityLabel("Connection source")
            } header: {
                Text("Search in")
            } footer: {
                Text(wikipedia ? "Explore live Wikipedia article links. Requires internet." : "Explore the events in your installed collection.")
            }

            if wikipedia { topicInputs } else { eventInputs }
            searchOptions
            if wikipedia { wikiPath } else { localPath }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background(AtlasTheme.ink)
        .navigationTitle("7 Degrees")
        .navigationBarTitleDisplayMode(.large)
        .safeAreaInset(edge: .bottom, spacing: 0) { actionDock }
        .onChange(of: fromTopic) { _, _ in invalidateWikipediaResult() }
        .onChange(of: toTopic) { _, _ in invalidateWikipediaResult() }
        .onDisappear { wikiTask?.cancel(); localTask?.cancel() }
        .sheet(item: $selector) { endpoint in
            NavigationStack {
                EndpointPicker(model: model, source: endpoint.source) { id in
                    if endpoint.source { model.sourceID = id } else { model.targetID = id }
                    selector = nil
                    model.path = nil
                    model.pathMessage = nil
                }
            }
        }
    }

    private var searching: Bool { model.findingPath || wikiBusy }

    private var canSearch: Bool {
        guard !searching else { return false }
        if wikipedia {
            return !fromTopic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !toTopic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !model.sourceID.isEmpty && !model.targetID.isEmpty
    }

    private var eventInputs: some View {
        Section("Endpoints") {
            endpointButton(label: "From", id: model.sourceID, source: true)
            endpointButton(label: "To", id: model.targetID, source: false)
        }
        .disabled(searching)
    }

    private func endpointButton(label: String, id: String, source: Bool) -> some View {
        let title = model.event(id)?.title ?? "Choose an event"
        return Button { selector = EndpointSelection(source: source) } label: {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(label).font(.subheadline).foregroundStyle(.secondary)
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("\(label) event, \(title)")
        .accessibilityHint(source ? "Choose the starting event." : "Choose the destination event.")
    }

    private var topicInputs: some View {
        Section("Wikipedia topics") {
            VStack(alignment: .leading, spacing: 5) {
                Text("From").font(.subheadline).foregroundStyle(.secondary)
                TextField("First Wikipedia topic", text: $fromTopic, axis: .vertical)
                    .lineLimit(1...3)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .focused($focusedTopic, equals: .from)
                    .submitLabel(.next)
                    .onSubmit { focusedTopic = .to }
                    .accessibilityLabel("Starting Wikipedia topic")
            }
            .frame(minHeight: 44)
            VStack(alignment: .leading, spacing: 5) {
                Text("To").font(.subheadline).foregroundStyle(.secondary)
                TextField("Second Wikipedia topic", text: $toTopic, axis: .vertical)
                    .lineLimit(1...3)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .focused($focusedTopic, equals: .to)
                    .submitLabel(.search)
                    .onSubmit { startSearch() }
                    .accessibilityLabel("Destination Wikipedia topic")
            }
            .frame(minHeight: 44)
            Menu {
                Button("Apollo 11 to Kevin Bacon") { useExample(from: "Apollo 11", to: "Kevin Bacon") }
                Button("Printing press to Internet") { useExample(from: "Printing press", to: "Internet") }
            } label: {
                Label("Try an example", systemImage: "lightbulb")
                    .frame(minHeight: 44)
            }
            .accessibilityHint("Choose a pair of Wikipedia topics.")
        }
        .disabled(searching)
    }

    private var searchOptions: some View {
        Section {
            Stepper(value: $model.maxHops, in: 1...7) {
                LabeledContent("Maximum hops", value: model.maxHops.formatted())
            }
            if !wikipedia {
                Toggle("Allow similarity suggestions", isOn: $model.semanticLinks)
                    .accessibilityHint("Includes connections based on summary embeddings, marked separately from documented links.")
            }
        } header: {
            Text("Search options")
        } footer: {
            Text(wikipedia
                 ? "Article links can be followed in either direction. A bounded search can stop before finding an existing route."
                 : model.semanticLinks
                    ? "Similarity can bridge related ideas. Each suggestion is marked and makes no claim of historical cause."
                    : "Only documented relationships and recorded article links are eligible.")
        }
        .disabled(searching)
    }

    @ViewBuilder private var actionDock: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 12) { dockActions }
        } else {
            dockActions
        }
    }

    private var dockActions: some View {
        VStack(spacing: 10) {
            if !wikipedia, !searching, let firstID = model.path?.eventIDs.first {
                Button { onWalk(firstID) } label: {
                    Label("Start walking", systemImage: "figure.walk")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .modifier(BridgeActionStyle(prominent: true))
                .accessibilityHint("Open the first event in this trail on the atlas.")
                searchButton(prominent: false)
            } else {
                searchButton(prominent: true)
            }
            if searching {
                Button("Cancel search", role: .cancel) {
                    wikiTask?.cancel()
                    localTask?.cancel()
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .modifier(BridgeActionStyle(prominent: false))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func searchButton(prominent: Bool) -> some View {
        Button(action: startSearch) {
            HStack(spacing: 10) {
                if searching {
                    ProgressView().tint(prominent ? AtlasTheme.ink : AtlasTheme.lime)
                } else {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                }
                Text(searching ? "Searching…" : "Find connection")
            }
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .modifier(BridgeActionStyle(prominent: prominent))
        .disabled(!canSearch)
        .accessibilityLabel(searching ? "Searching for a connection" : "Find a connection")
        .accessibilityHint("Search up to \(model.maxHops) hops between your chosen topics.")
    }

    private func startSearch() {
        guard canSearch else { return }
        focusedTopic = nil
        if wikipedia {
            wikiBusy = true
            wikiTask = Task { await findWikiPath() }
        } else {
            localTask = Task { await model.findPath() }
        }
    }

    private func useExample(from: String, to: String) {
        fromTopic = from
        toTopic = to
        invalidateWikipediaResult()
    }

    private func invalidateWikipediaResult() {
        guard !wikiBusy else { return }
        wikiResult = nil
        wikiError = nil
    }

    @ViewBuilder private var localPath: some View {
        if let path = model.path {
            Section("Discovered trail") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(path.hopCount) \(path.hopCount == 1 ? "degree" : "degrees") apart")
                        .font(.title2.weight(.semibold))
                    Label(path.containsSemanticSteps ? "Includes similarity suggestions" : "Documented connections",
                          systemImage: path.containsSemanticSteps ? "sparkles" : "link")
                        .font(.subheadline)
                        .foregroundStyle(path.containsSemanticSteps ? AtlasTheme.violet : AtlasTheme.cyan)
                    Text("Search spans the catalog, independently of your current time window.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if path.steps.isEmpty {
                        Text("Both endpoints are the same event.").font(.subheadline)
                    }
                }
                .padding(.vertical, 4)
            }
            if !path.steps.isEmpty {
                Section("Inspect each connection") {
                    ForEach(Array(path.steps.enumerated()), id: \.offset) { index, step in
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Step \(index + 1)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                            walkButton(id: step.fromID, color: .primary)
                            Label(step.edge.label, systemImage: step.edge.kind == .semantic ? "sparkles" : "link")
                                .font(.subheadline)
                                .foregroundStyle(step.edge.kind == .semantic ? AtlasTheme.violet : AtlasTheme.cyan)
                            walkButton(id: step.toID, color: AtlasTheme.lime)
                            Text(pathExplanation(step))
                                .font(.footnote).foregroundStyle(.secondary)
                            if let url = step.edge.evidenceURL {
                                Link(destination: url) {
                                    Label("Open evidence", systemImage: "arrow.up.right.square")
                                        .frame(minHeight: 44)
                                }
                                .font(.subheadline)
                                .accessibilityHint("Open the source for this connection.")
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        if let message = model.pathMessage {
            Section("Search result") {
                Text(message).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func walkButton(id: String, color: Color) -> some View {
        let title = model.event(id)?.title ?? id
        return Button { onWalk(id) } label: {
            HStack(alignment: .center, spacing: 12) {
                Text(title).font(.body.weight(.medium)).multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Image(systemName: "figure.walk").accessibilityHidden(true)
            }
            .foregroundStyle(color)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Walk to \(title)")
        .accessibilityHint("Open this event on the atlas.")
    }

    private func pathExplanation(_ step: AtlasPathStep) -> String {
        let source = model.event(step.edge.source)?.title ?? "the source topic"
        let target = model.event(step.edge.target)?.title ?? "the linked topic"
        let reverse = step.isReversed ? " You are following this connection in reverse." : ""
        switch step.edge.kind {
        case .wikiLink:
            return "The recorded article for “\(source)” contains a link to “\(target)”." + reverse
        case .wikidata:
            return "Wikidata records “\(step.edge.label)” from “\(source)” to “\(target)”." + reverse
        case .semantic:
            return step.explanation
        }
    }

    @ViewBuilder private var wikiPath: some View {
        if let result = wikiResult {
            Section("Discovered trail") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(result.hops.count) \(result.hops.count == 1 ? "degree" : "degrees") apart")
                        .font(.title2.weight(.semibold))
                    Text("\(result.from) → \(result.to)")
                        .font(.subheadline).foregroundStyle(AtlasTheme.cyan)
                    Text("\(result.visited.formatted()) topics examined\(result.truncated ? " · bounded search" : "")")
                        .font(.footnote).foregroundStyle(.secondary)
                    if result.hops.isEmpty {
                        Text("Both topics resolve to the same article.").font(.subheadline)
                    }
                }
                .padding(.vertical, 4)
            }
            if !result.hops.isEmpty {
                Section("Article links") {
                    ForEach(result.hops) { hop in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(hop.from).font(.headline)
                            Label(hop.explanation, systemImage: hop.isReversed ? "arrow.uturn.left" : "link")
                                .font(.subheadline).foregroundStyle(AtlasTheme.cyan)
                            Text(hop.to).font(.headline).foregroundStyle(AtlasTheme.lime)
                            Link(destination: hop.evidenceURL) {
                                Label("Verify this article link", systemImage: "arrow.up.right.square")
                                    .frame(minHeight: 44)
                            }
                            .font(.subheadline)
                            .accessibilityHint("Open the Wikipedia article containing this link.")
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        if let wikiError {
            Section("Search result") {
                Text(wikiError).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func findWikiPath() async {
        wikiBusy = true; wikiError = nil; wikiResult = nil
        do {
            wikiResult = try await wikiService.findPath(from: fromTopic, to: toTopic, maxHops: model.maxHops)
            if wikiResult == nil {
                wikiError = "No route found within this bounded \(model.maxHops)-hop search. This does not prove the topics are disconnected."
            }
        } catch is CancellationError { wikiError = "Search cancelled." }
        catch { wikiError = error.localizedDescription }
        wikiBusy = false
    }
}

private enum TopicField: Hashable { case from, to }

private struct EndpointSelection: Identifiable {
    let source: Bool
    var id: Bool { source }
}

private struct EndpointPicker: View {
    @Bindable var model: AtlasModel
    let source: Bool
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [AtlasEvent] = []
    @State private var searching = true

    var body: some View {
        List(results) { event in
            Button { onPick(event.id) } label: {
                EventRow(event: event).frame(minHeight: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("\(event.title), \(event.dateLabel), \(event.category)")
            .accessibilityHint(source ? "Choose this starting event." : "Choose this destination event.")
        }
        .listStyle(.insetGrouped)
        .navigationTitle(source ? "Starting event" : "Destination event")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search installed events")
        .overlay {
            if results.isEmpty {
                if searching {
                    ProgressView("Searching events…")
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }.frame(minHeight: 44)
            }
        }
        .task(id: query) {
            searching = true
            do { try await Task.sleep(for: .milliseconds(150)) }
            catch { return }
            guard !Task.isCancelled else { return }
            let found = await model.searchEvents(query)
            guard !Task.isCancelled else { return }
            results = found
            searching = false
        }
    }
}

private struct BridgeActionStyle: ViewModifier {
    let prominent: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent)
                    .tint(AtlasTheme.lime).foregroundStyle(AtlasTheme.ink)
                    .controlSize(.large).buttonBorderShape(.capsule)
            } else {
                content.buttonStyle(.glass)
                    .controlSize(.large).buttonBorderShape(.capsule)
            }
        } else if prominent {
            content.buttonStyle(.borderedProminent)
                .tint(AtlasTheme.lime).foregroundStyle(AtlasTheme.ink)
                .controlSize(.large).buttonBorderShape(.capsule)
        } else {
            content.buttonStyle(.bordered)
                .controlSize(.large).buttonBorderShape(.capsule)
        }
    }
}
