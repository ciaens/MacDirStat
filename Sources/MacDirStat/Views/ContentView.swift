import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var coordinator: ScanCoordinator?
    @State private var window: NSWindow?
    @State private var resizer = PanelResizeAnimator()

    private static let sidebarWidth: CGFloat = 260
    private static let inspectorWidth: CGFloat = 300

    var body: some View {
        HStack(spacing: 0) {
            // Content stays a fixed width inside a clipped box; the visible width
            // = fullWidth × fraction, where `fraction` and the window frame are
            // advanced by the same timer (PanelResizeAnimator) so the center keeps
            // a constant width every frame.
            if appState.showSidebar || resizer.sidebarFraction > 0.001 {
                sidebarPanel
                    .frame(width: Self.sidebarWidth)
                    .frame(width: Self.sidebarWidth * resizer.sidebarFraction, alignment: .leading)
                    .clipped()
            }

            centerPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if appState.showInspector || resizer.inspectorFraction > 0.001 {
                inspectorPanel
                    .frame(width: Self.inspectorWidth)
                    .frame(width: Self.inspectorWidth * resizer.inspectorFraction, alignment: .trailing)
                    .clipped()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowAccessor { configureWindow($0) })
        .toolbar { toolbarContent }
        .onAppear {
            if coordinator == nil {
                coordinator = ScanCoordinator(appState: appState)
            }
        }
        .focusedSceneValue(\.scanAction, { selectAndScan() })
    }

    // MARK: - Side panels (frosted glass over the desktop)

    @ViewBuilder
    private var sidebarPanel: some View {
        @Bindable var state = appState
        Group {
            if let root = appState.rootNode {
                DirectoryTreeView(
                    root: root,
                    selectedNode: $state.selectedNode,
                    sizeMetric: appState.sizeMetric,
                    onDrill: { node in appState.drillDown(to: node) }
                )
            } else {
                Text("No data")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VisualEffectView(material: .sidebar))
    }

    @ViewBuilder
    private var inspectorPanel: some View {
        Group {
            if let selected = appState.selectedNode {
                DetailPanelView(node: selected)
            } else {
                ContentUnavailableView(
                    "No Selection",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Select a file or folder to view its details.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VisualEffectView(material: .sidebar))
    }

    // MARK: - Center pane (opaque; the map never reflows on panel toggle)

    @ViewBuilder
    private var centerPane: some View {
        ZStack {
            switch appState.scanStatus {
            case .idle:
                WelcomeView { path in
                    coordinator?.startScan(path: path)
                }
                .transition(.opacity)

            case let .scanning(fileCount, byteCount, currentPath):
                ScanProgressView(
                    fileCount: fileCount,
                    byteCount: byteCount,
                    currentPath: currentPath
                ) {
                    coordinator?.cancel()
                    appState.scanStatus = .idle
                }

            case .completed:
                if let treemapRoot = appState.treemapRoot {
                    VStack(spacing: 0) {
                        BreadcrumbBar(
                            breadcrumbs: appState.breadcrumbs,
                            onNavigate: { node in appState.navigateTo(breadcrumb: node) }
                        )
                        TreemapView(
                            root: treemapRoot,
                            onSelect: { node in appState.selectedNode = node },
                            onDrillDown: { node in appState.drillDown(to: node) },
                            sizeMetric: appState.sizeMetric
                        )
                    }
                }

            case let .error(message):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.red)
                    Text("Scan Error")
                        .font(.title2.bold())
                    Text(message)
                        .foregroundStyle(.secondary)
                    Button("Try Again") {
                        appState.reset()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                toggleSidebar()
            } label: {
                Label("Toggle Sidebar", systemImage: "sidebar.left")
            }
        }

        ToolbarItem(placement: .navigation) {
            if appState.treemapRoot?.parent != nil {
                Button {
                    appState.navigateUp()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                if let path = appState.rootNode?.path {
                    coordinator?.startScan(path: path)
                }
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(appState.rootNode == nil)

            Button {
                selectAndScan()
            } label: {
                Label("Scan Drive", systemImage: "internaldrive.fill")
            }

            SizeMetricPicker(sizeMetric: sizeMetricBinding) {
                if appState.scanStatus == .idle, appState.rootNode != nil {
                    appState.scanStatus = .completed
                }
            }

            Button {
                toggleInspector()
            } label: {
                Label("Toggle Inspector", systemImage: "sidebar.right")
            }
        }
    }

    private var sizeMetricBinding: Binding<SizeMetric> {
        Binding(get: { appState.sizeMetric }, set: { appState.sizeMetric = $0 })
    }

    // MARK: - Actions

    private func configureWindow(_ resolved: NSWindow) {
        guard window == nil else { return }
        DispatchQueue.main.async {
            guard window == nil else { return }
            window = resolved
            // Non-opaque so the behind-window panels reveal the desktop. We
            // deliberately leave the background color and titlebar untouched so
            // the toolbar/title stay normal (clearing the bg made them
            // transparent).
            resolved.isOpaque = false
        }
    }

    private func toggleSidebar() {
        togglePanel(side: .left, width: Self.sidebarWidth, showing: !appState.showSidebar)
    }

    private func toggleInspector() {
        togglePanel(side: .right, width: Self.inspectorWidth, showing: !appState.showInspector)
    }

    private func togglePanel(side: PanelSide, width: CGFloat, showing: Bool) {
        setPanel(side: side, showing: showing) // logical state (toolbar, persistence)
        if let window {
            resizer.animate(window: window, side: side, showing: showing, width: width)
        } else {
            resizer.setInstant(side: side, showing: showing)
        }
    }

    private func setPanel(side: PanelSide, showing: Bool) {
        switch side {
        case .left: appState.showSidebar = showing
        case .right: appState.showInspector = showing
        }
    }

    private func selectAndScan() {
        coordinator?.cancel()
        appState.scanStatus = .idle
    }
}

// MARK: - Size Metric Picker

struct SizeMetricPicker: View {
    @Binding var sizeMetric: SizeMetric
    var onTap: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(SizeMetric.allCases, id: \.self) { metric in
                Button {
                    sizeMetric = metric
                    onTap()
                } label: {
                    Text(metric.rawValue)
                        .font(.body)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .background(sizeMetric == metric ? Color.accentColor.opacity(0.2) : Color.clear)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
    }
}

// MARK: - Breadcrumb Bar

struct BreadcrumbBar: View {
    let breadcrumbs: [FileNode]
    let onNavigate: (FileNode) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(breadcrumbs.enumerated()), id: \.element.id) { index, node in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Button {
                        onNavigate(node)
                    } label: {
                        Text(node.name)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(index == breadcrumbs.count - 1 ? .primary : .secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }
}

// MARK: - Focused Value for Menu Commands

struct ScanActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct ZoomInActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct ZoomOutActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct ResetZoomActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var scanAction: (() -> Void)? {
        get { self[ScanActionKey.self] }
        set { self[ScanActionKey.self] = newValue }
    }

    var zoomInAction: (() -> Void)? {
        get { self[ZoomInActionKey.self] }
        set { self[ZoomInActionKey.self] = newValue }
    }

    var zoomOutAction: (() -> Void)? {
        get { self[ZoomOutActionKey.self] }
        set { self[ZoomOutActionKey.self] = newValue }
    }

    var resetZoomAction: (() -> Void)? {
        get { self[ResetZoomActionKey.self] }
        set { self[ResetZoomActionKey.self] = newValue }
    }
}
