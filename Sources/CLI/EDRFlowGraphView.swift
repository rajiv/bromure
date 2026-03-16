import AppKit
import Grape
import SandboxEngine
import SwiftUI

// MARK: - Graph Data Model

/// Node identifier for the force graph. Pages and sub-resources are distinct types.
struct GraphNodeID: Hashable, CustomStringConvertible {
    let id: String
    let isPage: Bool
    var description: String { isPage ? "page:\(id)" : "res:\(id)" }
}

/// Pre-computed graph data from EDR events.
struct SessionGraph {
    struct Page: Identifiable {
        let id: String
        let url: String
        let hostname: String
        let displayLabel: String
        let timestamp: Double
        let navType: String?
        let statusCode: Int?
        let subResources: [EDREvent]
    }

    struct NavEdge: Identifiable {
        let id: String
        let from: String
        let to: String
        let label: String
    }

    let pages: [Page]
    let navEdges: [NavEdge]

    static func build(from events: [EDREvent], tabId: Int? = nil) -> SessionGraph {
        let tabEvents: [EDREvent]
        if let tabId {
            tabEvents = events.filter { $0.tabId == tabId }.sorted { $0.timestamp < $1.timestamp }
        } else {
            tabEvents = events.sorted { $0.timestamp < $1.timestamp }
        }

        let navTypes: Set<String> = [
            "main_frame", "redirect", "link", "typed",
            "form_submit", "reload", "back_forward",
        ]
        var navigations: [EDREvent] = []
        var subRequests: [EDREvent] = []

        for ev in tabEvents {
            let isNav = ev.method.uppercased() == "NAVIGATE"
                || navTypes.contains(ev.navType ?? "")
                || (ev.mimeType?.contains("html") == true
                    && (ev.documentUrl == nil || ev.documentUrl == ev.url))
            if isNav {
                navigations.append(ev)
            } else {
                subRequests.append(ev)
            }
        }

        if navigations.isEmpty && !subRequests.isEmpty {
            let first = subRequests.first!
            let host = first.hostname ?? URLComponents(string: first.url)?.host ?? ""
            let page = Page(
                id: "root", url: first.documentUrl ?? first.url,
                hostname: host, displayLabel: host,
                timestamp: first.timestamp, navType: nil, statusCode: nil,
                subResources: subRequests
            )
            return SessionGraph(pages: [page], navEdges: [])
        }

        var pages: [Page] = []
        for (i, nav) in navigations.enumerated() {
            let nextTs = (i + 1 < navigations.count) ? navigations[i + 1].timestamp : Double.greatestFiniteMagnitude
            let subs = subRequests.filter { $0.timestamp >= nav.timestamp && $0.timestamp < nextTs }
            let hostname = nav.hostname ?? URLComponents(string: nav.url)?.host ?? ""
            let path = URL(string: nav.url)?.path ?? nav.url
            var label = (path.isEmpty || path == "/") ? hostname : "\(hostname)\(path)"
            if label.count > 35 { label = String(label.prefix(32)) + "\u{2026}" }

            pages.append(Page(
                id: nav.id, url: nav.url, hostname: hostname,
                displayLabel: label, timestamp: nav.timestamp,
                navType: nav.navType, statusCode: nav.statusCode,
                subResources: subs
            ))
        }

        var edges: [NavEdge] = []
        for i in 1..<pages.count {
            let nt = pages[i].navType ?? ""
            let sc = pages[i].statusCode ?? 0
            let label: String
            if nt == "redirect" || (sc >= 300 && sc < 400) { label = "redirect" }
            else if nt == "form_submit" { label = "POST" }
            else if nt == "link" { label = "click" }
            else if nt == "back_forward" { label = "back" }
            else if nt == "typed" { label = "typed" }
            else { label = "\u{2192}" }
            edges.append(NavEdge(id: "\(i)", from: pages[i - 1].id, to: pages[i].id, label: label))
        }

        return SessionGraph(pages: pages, navEdges: edges)
    }
}

// MARK: - Flow Graph Window

func showFlowGraphWindow(events: [EDREvent], sessionName: String) {
    let tabIds = Set(events.compactMap(\.tabId)).sorted()

    let view = FlowGraphWindowView(
        events: events,
        sessionName: sessionName,
        tabIds: tabIds,
        initialTab: tabIds.first
    )

    let hostView = NSHostingView(rootView: view)
    hostView.setFrameSize(NSSize(width: 1000, height: 700))

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
        styleMask: [.titled, .closable, .resizable, .miniaturizable],
        backing: .buffered,
        defer: false
    )
    window.title = "Navigation Flow \u{2014} \(sessionName)"
    window.contentView = hostView
    window.contentMinSize = NSSize(width: 600, height: 400)
    window.center()
    window.makeKeyAndOrderFront(nil)
    window.isReleasedWhenClosed = false
}

// MARK: - Window View

private struct FlowGraphWindowView: View {
    let events: [EDREvent]
    let sessionName: String
    let tabIds: [Int]
    let initialTab: Int?

    @State private var selectedTab: Int?

    var body: some View {
        VStack(spacing: 0) {
            if tabIds.count > 1 {
                HStack(spacing: 8) {
                    Text("Tab:")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    ForEach(tabIds, id: \.self) { tabId in
                        Button { selectedTab = tabId } label: {
                            Text("Tab \(tabId)")
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    (selectedTab ?? initialTab) == tabId
                                        ? Color.accentColor.opacity(0.15)
                                        : Color.primary.opacity(0.05)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    Text("Drag nodes \u{2022} Click page to expand sub-resources")
                        .font(.system(size: 10))
                        .foregroundStyle(.quaternary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(nsColor: .windowBackgroundColor))
                Divider()
            }

            let graph = SessionGraph.build(from: events, tabId: selectedTab ?? initialTab)
            if graph.pages.isEmpty {
                Text("No navigation events captured")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ForceGraphContent(graph: graph)
            }
        }
        .onAppear { selectedTab = initialTab }
    }
}

// MARK: - Grape Force-Directed Graph

private struct ForceGraphContent: View {
    let graph: SessionGraph

    @State private var graphState = ForceDirectedGraphState(
        initialIsRunning: true,
        initialModelTransform: .identity.scale(by: 0.7)
    )
    // All pages start expanded — sub-resources always visible as stars
    @State private var collapsedPages: Set<String> = []

    var body: some View {
        ForceDirectedGraph(states: graphState) {
            // Page nodes
            Series(graph.pages) { page in
                NodeMark(id: GraphNodeID(id: page.id, isPage: true))
                    .symbol(.circle)
                    .symbolSize(radius: !collapsedPages.contains(page.id) ? 22 : 16)
                    .foregroundStyle(pageColor(page))
                    .stroke()
                    .annotation(
                        page.id,
                        alignment: .bottom,
                        offset: CGVector(dx: 0, dy: 24)
                    ) {
                        pageLabel(page)
                    }
            }

            // Sub-resource nodes (starburst around expanded pages)
            Series(expandedSubResources) { sub in
                NodeMark(id: sub.nodeID)
                    .symbol(.circle)
                    .symbolSize(radius: 3)
                    .foregroundStyle(mimeColor(sub.event.mimeType))
            }

            // Navigation edges (page chain)
            Series(graph.navEdges) { edge in
                LinkMark(
                    from: GraphNodeID(id: edge.from, isPage: true),
                    to: GraphNodeID(id: edge.to, isPage: true)
                )
                .stroke(edgeColor(edge.label).opacity(0.5), StrokeStyle(lineWidth: 2, dash: edge.label == "redirect" ? [5, 4] : []))
            }

            // Sub-resource edges (page → resource)
            Series(expandedSubResources) { sub in
                LinkMark(
                    from: GraphNodeID(id: sub.pageID, isPage: true),
                    to: sub.nodeID
                )
                .stroke(Color.secondary.opacity(0.15), StrokeStyle(lineWidth: 0.4))
            }

        } force: {
            // Different link lengths: long for page chain, short for sub-resources
            .link(
                originalLength: .varied { edge, _ in
                    // Both pages → long edge (vertical chain)
                    // Sub-resource → short edge (starburst around parent)
                    (edge.source.isPage && edge.target.isPage) ? 150 : 30
                },
                stiffness: .weightedByDegree { edge, _ in
                    (edge.source.isPage && edge.target.isPage) ? 0.3 : 0.8
                }
            )
            // Repulsion fans sub-resources out radially
            .manyBody(strength: -30)
            .center()
        }
        .graphOverlay { proxy in
            Color.clear.contentShape(Rectangle())
                .withGraphDragGesture(proxy, of: GraphNodeID.self) { state in
                    // On tap (drag ended at start), toggle expansion
                    if case .node(let nodeID) = state, nodeID.isPage {
                        if collapsedPages.contains(nodeID.id) {
                            collapsedPages.remove(nodeID.id)
                        } else {
                            collapsedPages.insert(nodeID.id)
                        }
                    }
                }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Expanded sub-resources

    private struct SubRes: Identifiable {
        let id: String
        let nodeID: GraphNodeID
        let pageID: String
        let event: EDREvent
    }

    private var expandedSubResources: [SubRes] {
        graph.pages.flatMap { page -> [SubRes] in
            guard !collapsedPages.contains(page.id) else { return [] }
            return page.subResources.map { ev in
                SubRes(id: ev.id, nodeID: GraphNodeID(id: ev.id, isPage: false), pageID: page.id, event: ev)
            }
        }
    }

    // MARK: - Page Label

    private func pageLabel(_ page: SessionGraph.Page) -> some View {
        VStack(spacing: 1) {
            Text(page.displayLabel)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)

            HStack(spacing: 3) {
                if !page.subResources.isEmpty {
                    Text("\(page.subResources.count) req")
                        .font(.system(size: 7))
                        .foregroundStyle(.secondary)
                }
                if let sc = page.statusCode, sc > 0 {
                    Text("\(sc)")
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundStyle(statusColor(sc))
                }
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.85))
        )
    }

    // MARK: - Colors

    private func pageColor(_ page: SessionGraph.Page) -> Color {
        let sc = page.statusCode ?? 0
        if page.navType == "redirect" || (sc >= 300 && sc < 400) { return .orange }
        if sc >= 400 { return .red }
        return .blue
    }

    private func mimeColor(_ mime: String?) -> Color {
        let m = mime ?? ""
        if m.contains("javascript") { return .yellow }
        if m.contains("css") { return .purple }
        if m.contains("image") { return .green }
        if m.contains("font") { return .gray }
        if m.contains("json") || m.contains("xml") { return .cyan }
        return .secondary
    }

    private func edgeColor(_ label: String) -> Color {
        switch label {
        case "redirect": return .orange
        case "POST": return .green
        case "click": return .blue
        case "back": return .purple
        case "typed": return .cyan
        default: return .secondary
        }
    }

    private func statusColor(_ code: Int) -> Color {
        switch code {
        case 200..<300: return .green
        case 300..<400: return .orange
        case 400..<500: return .red
        case 500..<600: return .red
        default: return .gray
        }
    }
}
